local M = {}

---@type string[]
M.tiers = { 'stable', 'unstable', 'unmaintained', 'unsupported' }

---@class TSConfig
---@field install_dir string

---@type TSConfig
local config = {
  install_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site'),
}

---Returns the raw install directory path without creating subdirectories.
---Used internally by submodules.
---@return string
function M._config_dir()
  return config.install_dir
end

---Setup call for users to override configuration configurations.
---
---NOTE: setup() modifies vim.o.rtp when install_dir is provided.
---get_install_dir() creates subdirectories but does NOT modify rtp.
---@param user_data TSConfig? user configuration table
function M.setup(user_data)
  if user_data then
    if user_data.install_dir then
      user_data.install_dir = vim.fs.normalize(user_data.install_dir)
      vim.o.rtp = user_data.install_dir .. ',' .. vim.o.rtp
    end
    config = vim.tbl_deep_extend('force', config, user_data)
  end
end

---Returns the install path for parsers, parser info, and queries.
---If the specified directory does not exist, it is created.
---Note: This creates subdirectories but does NOT add them to the runtime path.
---@param dir_name string
---@return string
function M.get_install_dir(dir_name)
  local dir = vim.fs.joinpath(config.install_dir, dir_name)

  if not vim.uv.fs_stat(dir) then
    local result = vim.fn.mkdir(dir, 'p', '0755')
    if result == 0 then
      local log = require('nvim-treesitter.log')
      log.error('Failed to create directory: ' .. dir)
    end
  end
  return dir
end

local paths = require('nvim-treesitter.config.paths')
local parsers = require('nvim-treesitter.config.parsers')
local languages = require('nvim-treesitter.config.languages')

M.get_installed = paths.get_installed
M.get_available = parsers.get_available
M.norm_languages = languages.norm_languages

return M
