local fs = vim.fs
local uv = vim.uv

local a = require('nvim-treesitter.async')
local compile = require('nvim-treesitter.install.compile')
local download = require('nvim-treesitter.install.download')
local concurrency = require('nvim-treesitter.install.concurrency')
local info = require('nvim-treesitter.install.info')
local install_fs = require('nvim-treesitter.install.fs')
local errors = require('nvim-treesitter.install.errors')
local validate = require('nvim-treesitter.install.validate')

local config = require('nvim-treesitter.config')
local log = require('nvim-treesitter.log')
local util = require('nvim-treesitter.util')

local M = {}

local INSTALL_TIMEOUT = 60000

local fn = vim.fn

---@async
---@param logger Logger
---@param lang string
---@param parser string
---@param queries string
---@return InstallError? err
function M.uninstall_lang(logger, lang, parser, queries)
  logger:debug('Uninstalling ' .. lang)

  if fn.filereadable(parser) == 1 then
    logger:debug('Unlinking ' .. parser)
    local perr = install_fs.uv_unlink(parser)
    a.schedule()
    if perr then
      return errors.error(logger, 'install', lang, 'could not unlink parser at ' .. parser, perr)
    end
  end

  local stat = uv.fs_lstat(queries)
  if stat then
    logger:debug('Unlinking ' .. queries)
    local qerr ---@type string?
    if stat.type == 'link' then
      qerr = install_fs.uv_unlink(queries)
    else
      qerr = install_fs.rmpath(queries, logger)
    end
    a.schedule()
    if qerr then
      return errors.error(logger, 'queries', lang, 'could not remove queries at ' .. queries, qerr)
    end
  end

  logger:info('Language uninstalled')
end

--- Best-effort cleanup of a temporary directory: failures are logged at
--- debug level instead of failing the install.
---@async
---@param path string
---@param logger Logger
local function cleanup_dir(path, logger)
  local err = install_fs.rmpath(path, logger)
  if err then
    logger:debug('Could not clean up %s: %s', path, err)
  end
end

--- Validates that the parser info exists and required tools are available.
---@async
---@param lang string
---@param repo InstallInfo?
---@param logger Logger
---@return InstallError? err
local function validate_install(lang, repo, logger)
  if not repo then
    return errors.error(
      logger,
      'validate',
      lang,
      'no parser configuration registered for this language'
    )
  end

  if repo.url ~= nil and not repo.url:match('^.+%://') then
    return errors.error(
      logger,
      'validate',
      lang,
      'invalid or missing URL in parser configuration: ' .. tostring(repo.url)
    )
  end

  local tools = validate.required_tools(repo)
  local missing = {}
  for _, tool in ipairs(tools) do
    local err = validate.check_executable(tool)
    if err then
      missing[#missing + 1] = tool
      logger:debug('Tool check: %s', err)
    end
  end
  if #missing > 0 then
    return errors.error(
      logger,
      'validate',
      lang,
      'missing required tools: ' .. table.concat(missing, ', ')
    )
  end
end

--- Selects how the queries of a language should be installed.
---@param repo InstallInfo?
---@param lang string
---@param cache_dir string
---@param project_name string
---@return function? task query task with signature (logger, lang, query_src, query_dir)
---@return string? query_src
local function select_query_task(repo, lang, cache_dir, project_name)
  if repo and repo.queries and repo.path then
    -- Local parser checkout: link its bundled queries
    return compile.do_link_queries, fs.joinpath(fs.normalize(repo.path), repo.queries)
  elseif repo and repo.queries then
    -- Downloaded tarball: copy its bundled queries
    return compile.do_copy_queries, fs.joinpath(cache_dir, project_name, repo.queries)
  end
  -- Default: link the queries shipped with this plugin, if any
  local query_src = install_fs.get_package_path('runtime', 'queries', lang)
  if uv.fs_stat(query_src) then
    return compile.do_link_queries, query_src
  end
end

--- Coordinates language installation: download/compile/install parser and queries.
--- Each stage can return an InstallError with the stage and language context.
---@async
---@param lang string
---@param cache_dir string
---@param install_dir string
---@param generate? boolean
---@param logger Logger
---@return InstallError? err
function M.try_install_lang(lang, cache_dir, install_dir, generate, logger)
  local repo = info.get_parser_install_info(lang)
  local project_name = 'tree-sitter-' .. lang

  local verr = validate_install(lang, repo, logger)
  if verr then
    return verr
  end

  -- repo is guaranteed non-nil after validation
  assert(repo, 'validate_install should have caught nil repo')

  local revision = repo.revision

  local compile_location ---@type string
  if repo.path then
    compile_location = fs.normalize(repo.path)
  else
    local project_dir = fs.joinpath(cache_dir, project_name)
    cleanup_dir(project_dir, logger)

    revision = revision or repo.branch or 'main'

    local err =
      download.do_download(logger, lang, repo.url, project_name, cache_dir, revision, project_dir)
    if err then
      return err
    end
    compile_location = fs.joinpath(cache_dir, project_name)
  end

  if repo.location then
    compile_location = fs.joinpath(compile_location, repo.location)
  end

  if repo.generate or generate then
    local err = compile.do_generate(logger, lang, repo, compile_location)
    if err then
      return err
    end
  end

  local err = compile.do_compile(logger, lang, compile_location)
  if err then
    return err
  end

  local parser_lib_name = fs.joinpath(compile_location, 'parser.so')
  local install_location = fs.joinpath(install_dir, lang) .. '.so'
  err = compile.do_install(logger, lang, parser_lib_name, install_location)
  if err then
    return err
  end

  local revfile = fs.joinpath(config.get_install_dir('parser-info'), lang .. '.revision')
  local werr = util.write_file(revfile, revision or '')
  if werr then
    return errors.error(logger, 'install', lang, 'could not write revision file', werr)
  end

  local query_task, query_src = select_query_task(repo, lang, cache_dir, project_name)
  if query_task then
    local query_dir = fs.joinpath(config.get_install_dir('queries'), lang)
    err = query_task(logger, lang, query_src, query_dir)
    if err then
      return err
    end
  end

  if repo and not repo.path then
    cleanup_dir(fs.joinpath(cache_dir, project_name), logger)
    a.schedule()
  end

  logger:info('Language installed')
end

--- Installs a single language parser, handling validation/download/generate/compile/install.
--- Thread-safe via 'installing' lock; waits for existing install if concurrent request.
---@async
---@param lang string
---@param cache_dir string
---@param install_dir string
---@param force? boolean
---@param generate? boolean
---@return boolean success
---@return InstallError? err
function M.install_lang(lang, cache_dir, install_dir, force, generate)
  local logger = log.new('install/' .. lang)

  if not force and vim.list_contains(config.get_installed(), lang) then
    return true, nil
  elseif concurrency.is_installing(lang) then
    -- Another task is installing this language: wait (asynchronously) until
    -- it finishes. Returns false if the lock outlives INSTALL_TIMEOUT.
    local success = concurrency.wait_unlock(lang, INSTALL_TIMEOUT)
    return success, nil
  else
    concurrency.lock(lang)
    -- pcall frame persists across coroutine yields in LuaJIT, so synchronous
    -- errors (nil deref, assertion, etc.) and errors re-raised by await are
    -- both caught here.
    local ok, err = pcall(M.try_install_lang, lang, cache_dir, install_dir, generate, logger)
    concurrency.unlock(lang)
    if not ok then
      -- Unexpected Lua error (nil deref, assertion, etc.)
      local ierr =
        errors.error(logger, 'install', lang, 'unexpected error during installation', tostring(err))
      return false, ierr
    end
    return not err, err
  end
end

return M
