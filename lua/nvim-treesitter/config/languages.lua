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

  local installed = nil
  if skip and (skip.installed or skip.missing) then
    if skip.installed and skip.missing then
      return {}
    end
    installed = paths.get_installed()
  end

  if skip and skip.installed then
    languages = vim.tbl_filter(
      --- @param v string
      function(v)
        return not vim.list_contains(installed, v)
      end,
      languages
    )
  elseif skip and skip.missing then
    languages = vim.tbl_filter(
      --- @param v string
      function(v)
        return vim.list_contains(installed, v)
      end,
      languages
    )
  end

  languages = vim.tbl_filter(
    --- @param v string
    function(v)
      if parsers_mod[v] ~= nil then
        return true
      else
        require('nvim-treesitter.log').warn('skipping unsupported language: ' .. v)
        return false
      end
    end,
    languages
  )

  if skip and skip.unsupported then
    languages = vim.tbl_filter(
      --- @param v string
      function(v)
        return not (parsers_mod[v] and parsers_mod[v].tier and parsers_mod[v].tier == 4)
      end,
      languages
    )
  end

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

  local seen = {}
  local result = {}
  for _, v in ipairs(languages) do
    if not seen[v] then
      seen[v] = true
      result[#result + 1] = v
    end
  end
  return result
end

return M
