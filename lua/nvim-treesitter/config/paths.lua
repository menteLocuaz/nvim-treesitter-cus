local M = {}

local function get_install_dir(dir_name)
  local config = require('nvim-treesitter.config')
  local dir = vim.fs.joinpath(config._config_dir(), dir_name)

  if not vim.uv.fs_stat(dir) then
    local result = vim.fn.mkdir(dir, 'p', '0755')
    if result == 0 then
      require('nvim-treesitter.log').error('Failed to create directory: ' .. dir)
    end
  end
  return dir
end

---@param filter 'queries'|'parsers'?
---@return string[]
function M.get_installed(filter)
  local result = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>

  if not (filter and filter == 'parsers') then
    local queries_dir = get_install_dir('queries')
    for f in vim.fs.dir(queries_dir) do
      if not seen[f] then
        seen[f] = true
        result[#result + 1] = f
      end
    end
  end

  if not (filter and filter == 'queries') then
    local parsers_dir = get_install_dir('parsers')
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
