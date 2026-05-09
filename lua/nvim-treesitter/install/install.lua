local fs = vim.fs
local uv = vim.uv

local a = require('nvim-treesitter.async')
local compile = require('nvim-treesitter.install.compile')
local download = require('nvim-treesitter.install.download')
local concurrency = require('nvim-treesitter.install.concurrency')
local info = require('nvim-treesitter.install.info')
local install_fs = require('nvim-treesitter.install.fs')
local system = require('nvim-treesitter.install.system')

local config = require('nvim-treesitter.config')
local log = require('nvim-treesitter.log')
local parsers = require('nvim-treesitter.parsers')
local util = require('nvim-treesitter.util')

local M = {}

local uv_copyfile = a.awrap(4, uv.fs_copyfile)
local uv_unlink = a.awrap(2, uv.fs_unlink)
local uv_rename = a.awrap(3, uv.fs_rename)
local uv_symlink = a.awrap(4, uv.fs_symlink)
local uv_mkdir = a.awrap(3, uv.fs_mkdir)

local INSTALL_TIMEOUT = 60000

local installing = {} ---@type table<string,boolean?>

local fn = vim.fn

---@param ... string
---@return string
local function get_package_path(...)
  local dbg = assert(debug.getinfo(1, 'S'))
  return fs.joinpath(fn.fnamemodify(dbg.source:sub(2), ':p:h:h:h'), ...)
end

---@async
---@param logger Logger
---@param lang string
---@param parser string
---@param queries string
---@return string? err
function M.uninstall_lang(logger, lang, parser, queries)
  logger:debug('Uninstalling ' .. lang)

  if fn.filereadable(parser) == 1 then
    logger:debug('Unlinking ' .. parser)
    local perr = uv_unlink(parser)
    a.schedule()
    if perr then
      return logger:error(perr)
    end
  end

  local stat = uv.fs_lstat(queries)
  if stat then
    logger:debug('Unlinking ' .. queries)
    local qerr ---@type string?
    if stat.type == 'link' then
      qerr = uv_unlink(queries)
    else
      qerr = install_fs.rmpath(queries, logger)
    end
    a.schedule()
    if qerr then
      return logger:error(qerr)
    end
  end

  logger:info('Language uninstalled')
end

--- Coordinates language installation: download/compile/install parser and queries.
---@async
---@param lang string
---@param cache_dir string
---@param install_dir string
---@param generate? boolean
---@param logger Logger
---@return string? err
function M.try_install_lang(lang, cache_dir, install_dir, generate, logger)
  local repo = info.get_parser_install_info(lang)
  local project_name = 'tree-sitter-' .. lang
  if repo then
    local revision = repo.revision

    local compile_location ---@type string
    if repo.path then
      compile_location = fs.normalize(repo.path)
    else
      local project_dir = fs.joinpath(cache_dir, project_name)
      install_fs.rmpath(project_dir, logger)

      revision = revision or repo.branch or 'main'

      local err =
        download.do_download(logger, repo.url, project_name, cache_dir, revision, project_dir)
      if err then
        return err
      end
      compile_location = fs.joinpath(cache_dir, project_name)
    end

    if repo.location then
      compile_location = fs.joinpath(compile_location, repo.location)
    end

    if repo.generate or generate then
      local err = compile.do_generate(logger, repo, compile_location)
      if err then
        return err
      end
    end

    local err = compile.do_compile(logger, compile_location)
    if err then
      return err
    end

    local parser_lib_name = fs.joinpath(compile_location, 'parser.so')
    local install_location = fs.joinpath(install_dir, lang) .. '.so'
    err = compile.do_install(logger, parser_lib_name, install_location)
    if err then
      return err
    end

    local revfile = fs.joinpath(config.get_install_dir('parser-info') or '', lang .. '.revision')
    util.write_file(revfile, revision or '')
  end

  local query_src = get_package_path('runtime', 'queries', lang)
  local query_dir = fs.joinpath(config.get_install_dir('queries'), lang)
  local task ---@type function

  if repo and repo.queries and repo.path then
    query_src = fs.joinpath(fs.normalize(repo.path), repo.queries)
    task = compile.do_link_queries
  elseif repo and repo.queries then
    query_src = fs.joinpath(cache_dir, project_name, repo.queries)
    task = compile.do_copy_queries
  elseif uv.fs_stat(query_src) then
    task = compile.do_link_queries
  end

  if task then
    local err = task(logger, query_src, query_dir)
    if err then
      return err
    end
  end

  if repo and not repo.path then
    local project_dir = fs.joinpath(cache_dir, project_name)
    install_fs.rmpath(project_dir, logger)
    a.schedule()
  end

  logger:info('Language installed')
end

--- Installs a single language parser, handling download/generation/compile/install.
--- Thread-safe via 'installing' lock; waits for existing install if concurrent request.
---@async
---@param lang string
---@param cache_dir string
---@param install_dir string
---@param force? boolean
---@param generate? boolean
---@return boolean success
function M.install_lang(lang, cache_dir, install_dir, force, generate)
  local logger = log.new('install/' .. lang)

  if not force and vim.list_contains(config.get_installed(), lang) then
    return true
  elseif concurrency.is_installing(lang) then
    local success = vim.wait(INSTALL_TIMEOUT, function()
      return not concurrency.is_installing(lang)
    end)
    return success
  else
    concurrency.lock(lang)
    local err = M.try_install_lang(lang, cache_dir, install_dir, generate, logger)
    concurrency.unlock(lang)
    return not err
  end
end

return M
