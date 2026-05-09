local fs = vim.fs
local uv = vim.uv

local parsers = require('nvim-treesitter.parsers')
local config = require('nvim-treesitter.config')

local M = {}
local util = require('nvim-treesitter.util')

---@param lang string
---@return InstallInfo?
function M.get_parser_install_info(lang)
  local parser_config = parsers[lang]

  if not parser_config then
    return
  end

  return parser_config.install_info
end

---@param lang string
---@return string?
function M.get_installed_revision(lang)
  local lang_file = fs.joinpath(config.get_install_dir('parser-info'), lang .. '.revision')
  return util.read_file(lang_file)
end

---@param lang string
---@param query_src string
---@return boolean
function M.needs_update(lang, query_src)
  local info = M.get_parser_install_info(lang)
  if info and info.revision then
    return info.revision ~= M.get_installed_revision(lang)
  end

  local queries = fs.joinpath(config.get_install_dir('queries'), lang)
  local queries_src = query_src

  return uv.fs_realpath(queries) ~= uv.fs_realpath(queries_src)
end

return M