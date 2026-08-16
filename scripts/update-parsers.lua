#!/usr/bin/env -S nvim -l
-- Update parsers to latest version (tier 1, stable) or commit (tier 2, unstable)
--
-- Usage:
-- nvim -l update-parsers.lua            # update all (stable and unstable) parsers
-- nvim -l update-parsers.lua --tier=1   # update stable parsers to latest version
-- nvim -l update-parsers.lua --tier=2   # update unstable parsers to latest commit

local tier = nil ---@type number?
for i = 1, #_G.arg do
  if _G.arg[i]:find('^%-%-tier=') then
    tier = tonumber(_G.arg[i]:match('=(%d+)'))
  end
end

vim.o.rtp = vim.o.rtp .. ',.'
local util = require('nvim-treesitter.util')
local parsers = require('nvim-treesitter.parsers')

local jobs = {} ---@type table<string,vim.SystemObj>
local updates = {} ---@type string[]

-- check for new revisions
for k, p in pairs(parsers) do
  if p.tier and p.tier <= 2 and (tier == nil or p.tier == tier) and p.install_info then
    print('Updating ' .. k)
    local cmd = p.tier == 1
        and {
          'git',
          '-c',
          'versionsort.suffix=-',
          'ls-remote',
          '--tags',
          '--refs',
          '--sort=v:refname',
          p.install_info.url,
        }
      or { 'git', 'ls-remote', p.install_info.url }
    jobs[k] = vim.system(cmd)
  end

  if #vim.tbl_keys(jobs) % 100 == 0 or next(parsers, k) == nil then
    for name, job in pairs(jobs) do
      local stdout = vim.split(job:wait().stdout or '', '\n')
      jobs[name] = nil

      assert(parsers[name])
      local info = assert(parsers[name].install_info)

      local sha ---@type string?
      if parsers[name].tier == 1 then
        sha = stdout[#stdout - 1] and stdout[#stdout - 1]:match('v[%d%.]+$')
      else
        local branch = info.branch
        local line = 1
        if branch then
          for j, l in ipairs(stdout) do
            if l:find(vim.pesc(branch)) then
              line = j
              break
            end
          end
        end
        sha = stdout[line] and vim.split(stdout[line], '\t')[1]
      end

      if sha and sha ~= '' and info.revision ~= sha then
        info.revision = sha
        updates[#updates + 1] = name
      end
    end
  end
end

assert(#vim.tbl_keys(jobs) == 0)

if #updates > 0 then
  for _, name in ipairs(updates) do
    local parser_file = 'lua/nvim-treesitter/parsers/list/' .. name:gsub('/', '_') .. '.lua'
    local data = vim.deepcopy(parsers[name])
    setmetatable(data, nil)
    local content = 'return ' .. vim.inspect(data)
    if vim.fn.executable('stylua') == 1 then
      content = vim.system({ 'stylua', '-' }, { stdin = content }):wait().stdout --[[@as string]]
    end
    local werr = util.write_file(
      'lua/nvim-treesitter/parsers/list/' .. name:gsub('/', '_') .. '.lua',
      parser_file
    )
    if werr then
      error(werr)
    end
  end

  table.sort(updates)
  local update_list = table.concat(updates, ', ')
  print(string.format('\nUpdated parsers: %s', update_list))

  -- Regenerate manifest
  local manifest = {}
  for k, p in pairs(require('nvim-treesitter.parsers')) do
    manifest[k] = {
      tier = p.tier,
      maintainers = p.maintainers,
      requires = p.requires,
    }
  end
  local manifest_file = 'return ' .. vim.inspect(manifest)
  if vim.fn.executable('stylua') == 1 then
    manifest_file = vim.system({ 'stylua', '-' }, { stdin = manifest_file }):wait().stdout --[[@as string]]
  end
  local merr = util.write_file('lua/nvim-treesitter/parsers/manifest.lua', manifest_file)
  if merr then
    error(merr)
  end

  -- pass list to workflow
  local gh_env = os.getenv('GITHUB_ENV')
  if gh_env then
    local env = assert(io.open(gh_env, 'a'))
    env:write(string.format('UPDATED_PARSERS=%s\n', update_list))
    env:close()
  end
else
  print('\nAll parsers up to date!')
end
