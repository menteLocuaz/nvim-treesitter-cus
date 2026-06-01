local M = {}

local paths = require('nvim-treesitter.config.paths')
local parsers = require('nvim-treesitter.config.parsers')
local parsers_mod = require('nvim-treesitter.parsers')

---Normalize languages
---@param languages? string[]|string
---@param skip? { missing: boolean?, unsupported: boolean?, installed: boolean?, dependencies: boolean? }
---@return string[]
function M.norm_languages(languages, skip)
  if not languages then
    return {}
  elseif type(languages) == 'string' then
    languages = { languages }
  end

  if vim.list_contains(languages, 'all') then
    if skip and skip.missing then
      return paths.get_installed()
    end
    languages = parsers.get_available()
  end

  languages = parsers.expand_tiers(languages)

  local installed_set = nil ---@type table<string, true>?
  if skip and (skip.installed or skip.missing) then
    if skip.installed and skip.missing then
      return {}
    end
    local installed_list = paths.get_installed()
    installed_set = {}
    for _, v in ipairs(installed_list) do
      installed_set[v] = true
    end
  end

  local result = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>
  for _, v in ipairs(languages) do
    if not seen[v] then
      seen[v] = true

      if skip and skip.installed then
        if installed_set[v] then
          goto continue
        end
      elseif skip and skip.missing then
        if not installed_set[v] then
          goto continue
        end
      end

      if skip and skip.unsupported and parsers_mod[v] and parsers_mod[v].tier == 4 then
        goto continue
      end

      if parsers_mod[v] == nil then
        require('nvim-treesitter.log').warn('skipping unsupported language: ' .. v)
        goto continue
      end

      result[#result + 1] = v
    end
    ::continue::
  end
  languages = result

  if not (skip and skip.dependencies) then
    local seen_deps = {}
    local extra = {}
    for _, lang in ipairs(languages) do
      local p = parsers_mod[lang]
      if p and p.requires then
        for _, dep in ipairs(p.requires) do
          if not seen_deps[dep] then
            seen_deps[dep] = true
            extra[#extra + 1] = dep
          end
        end
      end
    end
    vim.list_extend(languages, extra)
  end

  local final_seen = {}
  local final_result = {}
  for _, v in ipairs(languages) do
    if not final_seen[v] then
      final_seen[v] = true
      final_result[#final_result + 1] = v
    end
  end
  return final_result
end

return M
