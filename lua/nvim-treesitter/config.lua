local M = {}

M.tiers = { 'stable', 'unstable', 'unmaintained', 'unsupported' }

---@class TSConfig
---@field install_dir string

---@type TSConfig
local config = {
  install_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site'),
}

---Setup call for users to override configuration configurations.
---@param user_data TSConfig? user configuration table
function M.setup(user_data)
  if not user_data then
    return
  end

  if user_data.install_dir then
    user_data.install_dir = vim.fs.normalize(user_data.install_dir)
    vim.o.rtp = user_data.install_dir .. ',' .. vim.o.rtp
  end

  config = vim.tbl_deep_extend('force', config, user_data)
end

-- Returns the install path for parsers, parser info, and queries.
-- If the specified directory does not exist, it is created.
---@param dir_name string
---@return string
function M.get_install_dir(dir_name)
  local dir = vim.fs.joinpath(config.install_dir, dir_name)

  if not vim.uv.fs_stat(dir) then
    local ok, err = pcall(vim.fn.mkdir, dir, 'p', '0755')
    if not ok then
      require('nvim-treesitter.log').error(err --[[@as string]])
    end
  end

  return dir
end

---@param type 'queries'|'parsers'?
---@return string[]
function M.get_installed(type)
  local installed = {} --- @type table<string, boolean>

  if type ~= 'parsers' then
    for f in vim.fs.dir(M.get_install_dir('queries')) do
      installed[f] = true
    end
  end

  if type ~= 'queries' then
    for f in vim.fs.dir(M.get_install_dir('parser')) do
      installed[vim.fn.fnamemodify(f, ':r')] = true
    end
  end

  return vim.tbl_keys(installed)
end

-- Get a list of all available parsers
---@param tier integer? only get parsers of specified tier
---@return string[]
function M.get_available(tier)
  vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
  local parsers = require('nvim-treesitter.parsers')

  --- @type string[]
  local languages = vim.tbl_keys(parsers)

  if tier then
    languages = vim.tbl_filter(function(p)
      return parsers[p].tier == tier
    end, languages)
  end

  table.sort(languages)
  return languages
end

local function expand_tiers(list)
  -- Creamos un Set (Hash Map) para búsquedas O(1) de los tiers
  local tier_map = {}
  for i, tier in ipairs(M.tiers) do
    tier_map[tier] = i
  end

  local expanded = {}
  for _, item in ipairs(list) do
    local tier_idx = tier_map[item]
    if tier_idx then
      vim.list_extend(expanded, M.get_available(tier_idx))
    else
      table.insert(expanded, item)
    end
  end

  return expanded
end

---Normalize languages
---@param languages? string[]|string
---@param skip? { missing: boolean?, unsupported: boolean?, installed: boolean?, dependencies: boolean? }
---@return string[]
function M.norm_languages(languages, skip)
  if not languages then
    return {}
  end
  languages = type(languages) == 'string' and { languages } or languages
  skip = skip or {}

  if vim.list_contains(languages, 'all') then
    if skip.missing then
      return M.get_installed()
    end
    languages = M.get_available()
  end

  languages = expand_tiers(languages)

  -- Convertimos la lista a un Set (Hash Map) para evitar iteraciones anidadas O(N^2)
  local installed_set
  if skip.installed or skip.missing then
    installed_set = {}
    for _, lang in ipairs(M.get_installed()) do
      installed_set[lang] = true
    end
  end

  local parsers = require('nvim-treesitter.parsers')
  local log = require('nvim-treesitter.log')

  -- Consolidamos las 4 pasadas de filtrado en un Single-Pass O(N)
  languages = vim.tbl_filter(function(lang)
    if skip.installed and installed_set[lang] then
      return false
    end
    if skip.missing and not installed_set[lang] then
      return false
    end

    local parser = parsers[lang]
    if not parser then
      log.warn('skipping unsupported language: ' .. lang)
      return false
    end

    if skip.unsupported and parser.tier == 4 then
      return false
    end

    return true
  end, languages)

  if not skip.dependencies then
    local seen = {} ---@type table<string, boolean>
    for _, lang in ipairs(languages) do
      seen[lang] = true
    end

    local i = 1
    while i <= #languages do
      local parser = parsers[languages[i]]
      if parser and parser.requires then
        for _, dependency in ipairs(parser.requires) do
          if not seen[dependency] then
            seen[dependency] = true
            languages[#languages + 1] = dependency
          end
        end
      end
      i = i + 1
    end
  end

  return vim.list.unique(languages)
end

return M
