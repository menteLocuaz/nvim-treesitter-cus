local M = {}

---@param filter 'queries'|'parsers'?
---@return string[]
function M.get_installed(filter)
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
    local parsers_dir = config.get_install_dir('parsers')
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

  return result
end

return M
