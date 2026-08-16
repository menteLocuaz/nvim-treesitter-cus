local M = {}

local cache = {
  all = nil,
  parsers = nil,
  queries = nil,
}

function M.invalidate_cache()
  cache.all = nil
  cache.parsers = nil
  cache.queries = nil
end

---@param filter 'queries'|'parsers'?
---@return string[]
function M.get_installed(filter)
  local cache_key = filter or 'all'
  if cache[cache_key] then
    -- Return a copy so callers can't corrupt the cached table
    return vim.list_extend({}, cache[cache_key])
  end

  local config = require('nvim-treesitter.config')
  local result = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>

  if not (filter and filter == 'parsers') then
    local queries_dir = config.get_install_dir('queries')
    for f in vim.fs.dir(queries_dir) do
      if not seen[f] then
        seen[f] = true
        result[#result + 1] = f
      end
    end
  end

  if not (filter and filter == 'queries') then
    local parsers_dir = config.get_install_dir('parser')
    for f in vim.fs.dir(parsers_dir) do
      local ext = f:match('%.%w+$')
      if ext == '.so' or ext == '.dll' or ext == '.dylib' then
        local name = vim.fn.fnamemodify(f, ':r')
        if not seen[name] then
          seen[name] = true
          result[#result + 1] = name
        end
      end
    end
  end

  cache[cache_key] = result
  return vim.list_extend({}, result)
end

return M
