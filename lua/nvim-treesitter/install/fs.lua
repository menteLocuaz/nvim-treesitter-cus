local fs = vim.fs
local uv = vim.uv

local a = require('nvim-treesitter.async')

local M = {}

---@type fun(path: string, new_path: string, flags?: table): string?
local uv_copyfile = a.awrap(4, uv.fs_copyfile)

---@type fun(path: string, mode: integer): string?
local uv_mkdir = a.awrap(3, uv.fs_mkdir)

---@type fun(path: string): string?
local uv_rmdir = a.awrap(2, uv.fs_rmdir)

---@type fun(path: string, new_path: string): string?
local uv_rename = a.awrap(3, uv.fs_rename)

---@type fun(path: string, new_path: string, flags?: table): string?
local uv_symlink = a.awrap(4, uv.fs_symlink)

---@type fun(path: string): string?
local uv_unlink = a.awrap(2, uv.fs_unlink)

--- Iteratively create directory path, ensuring all parent directories exist.
--- Uses a stack-based approach to avoid recursion depth issues.
---@async
---@param path string
---@param logger Logger
---@return string? err
function M.mkpath(path, logger)
  local dirs = {}
  repeat
    table.insert(dirs, 1, path)
    path = fs.dirname(path)
  until path == '.' or path == '/' or path:match('^[./]$') or uv.fs_stat(path)

  for _, dir in ipairs(dirs) do
    local err = uv_mkdir(dir, 493)
    if err then
      logger:debug('mkdir failed for %s: %s', dir, err)
      return err
    end
  end
end

--- Recursively remove a directory or file.
---@async
---@param path string
---@param logger Logger
---@return string? err
function M.rmpath(path, logger)
  local stat = uv.fs_lstat(path)
  if not stat then
    return
  end

  if stat.type == 'directory' then
    for file in fs.dir(path) do
      M.rmpath(fs.joinpath(path, file), logger)
    end
    return uv_rmdir(path)
  else
    return uv_unlink(path)
  end
end

return M