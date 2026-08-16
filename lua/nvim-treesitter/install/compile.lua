local a = require('nvim-treesitter.async')
local system = require('nvim-treesitter.install.system')

local M = {}

local install_fs = require('nvim-treesitter.install.fs')
local errors = require('nvim-treesitter.install.errors')

local uv = vim.uv
local fs = vim.fs

---@async
---@param logger Logger
---@param lang string
---@param repo InstallInfo
---@param compile_location string
---@return InstallError? err
function M.do_generate(logger, lang, repo, compile_location)
  local from_json = repo.generate_from_json ~= false

  logger:info('Generating parser.c from %s...', from_json and 'grammar.json' or 'grammar.js')

  local r = system.system({
    'tree-sitter',
    'generate',
    '--abi',
    tostring(vim.treesitter.language_version),
    from_json and 'src/grammar.json' or nil,
  }, { cwd = compile_location, env = { TREE_SITTER_JS_RUNTIME = 'native' } }, logger)
  if r.code > 0 then
    return errors.error(logger, 'generate', lang, 'tree-sitter generate failed', r.stderr)
  end
end

---@async
---@param logger Logger
---@param lang string
---@param compile_location string
---@return InstallError? err
function M.do_compile(logger, lang, compile_location)
  logger:info('Compiling parser')

  local r = system.system({
    'tree-sitter',
    'build',
    '-o',
    'parser.so',
  }, { cwd = compile_location }, logger)
  if r.code > 0 then
    return errors.error(logger, 'compile', lang, 'tree-sitter build failed', r.stderr)
  end
end

--- Copies the compiled parser.so to the install location, using a rename-then-unlink
--- strategy to handle cases where the existing parser may be in use.
---@async
---@param logger Logger
---@param lang string
---@param compile_location string
---@param target_location string
---@return InstallError? err
function M.do_install(logger, lang, compile_location, target_location)
  logger:info('Installing parser')

  local tempfile = target_location .. tostring(uv.hrtime())
  local rerr = install_fs.uv_rename(target_location, tempfile)
  if rerr then
    logger:debug('Could not rename existing parser: %s', rerr)
  end
  install_fs.uv_unlink(tempfile)

  local err = install_fs.uv_copyfile(compile_location, target_location)
  a.schedule()
  if err then
    return errors.error(
      logger,
      'install',
      lang,
      'failed to copy parser to ' .. target_location,
      err
    )
  end
end

---@async
---@param logger Logger
---@param lang string
---@param query_src string
---@param query_dir string
---@return InstallError? err
function M.do_link_queries(logger, lang, query_src, query_dir)
  install_fs.uv_unlink(query_dir)
  local err = install_fs.uv_symlink(query_src, query_dir, { dir = true, junction = true })
  a.schedule()
  if err then
    return errors.error(
      logger,
      'queries',
      lang,
      'failed to symlink queries from ' .. query_src,
      err
    )
  end
end

---@async
---@param logger Logger
---@param lang string
---@param query_src string
---@param query_dir string
---@return InstallError? err
function M.do_copy_queries(logger, lang, query_src, query_dir)
  if not uv.fs_stat(query_src) then
    return errors.error(
      logger,
      'queries',
      lang,
      'query source directory does not exist: ' .. query_src
    )
  end

  local rerr = install_fs.rmpath(query_dir, logger)
  if rerr then
    logger:debug('Could not remove old query dir: %s', rerr)
  end

  local err = install_fs.uv_mkdir(query_dir, 493 --[[0o755]])
  if err then
    return errors.error(logger, 'queries', lang, 'could not create query directory', err)
  end

  for f in fs.dir(query_src) do
    local cerr = install_fs.uv_copyfile(fs.joinpath(query_src, f), fs.joinpath(query_dir, f))
    if cerr then
      return errors.error(logger, 'queries', lang, 'could not copy ' .. f, cerr)
    end
  end
  a.schedule()
end

return M
