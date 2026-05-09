local a = require('nvim-treesitter.async')
local system = require('nvim-treesitter.install.system')

local M = {}

local uv_copyfile = a.awrap(4, vim.uv.fs_copyfile)
local uv_unlink = a.awrap(2, vim.uv.fs_unlink)
local uv_rename = a.awrap(3, vim.uv.fs_rename)
local uv_symlink = a.awrap(4, vim.uv.fs_symlink)
local uv_mkdir = a.awrap(3, vim.uv.fs_mkdir)
local install_fs = require('nvim-treesitter.install.fs')

local uv = vim.uv
local fs = vim.fs

---@async
---@param logger Logger
---@param repo InstallInfo
---@param compile_location string
---@return string? err
function M.do_generate(logger, repo, compile_location)
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
    return logger:error('Error during "tree-sitter generate": %s', r.stderr)
  end
end

---@async
---@param logger Logger
---@param compile_location string
---@return string? err
function M.do_compile(logger, compile_location)
  logger:info('Compiling parser')

  local r = system.system({
    'tree-sitter',
    'build',
    '-o',
    'parser.so',
  }, { cwd = compile_location }, logger)
  if r.code > 0 then
    return logger:error('Error during "tree-sitter build": %s', r.stderr)
  end
end

--- Copies the compiled parser.so to the install location, using a rename-then-unlink
--- strategy to handle cases where the existing parser may be in use.
---@async
---@param logger Logger
---@param compile_location string
---@param target_location string
---@return string? err
function M.do_install(logger, compile_location, target_location)
  logger:info('Installing parser')

  local tempfile = target_location .. tostring(uv.hrtime())
  local rerr = uv_rename(target_location, tempfile)
  if rerr then
    logger:debug('Could not rename existing parser: %s', rerr)
  end
  uv_unlink(tempfile)

  local err = uv_copyfile(compile_location, target_location)
  a.schedule()
  if err then
    return logger:error('Error during parser installation: %s', err)
  end
end

---@async
---@param logger Logger
---@param query_src string
---@param query_dir string
---@return string? err
function M.do_link_queries(logger, query_src, query_dir)
  uv_unlink(query_dir)
  local err = uv_symlink(query_src, query_dir, { dir = true, junction = true })
  a.schedule()
  if err then
    return logger:error(err)
  end
end

---@async
---@param logger Logger
---@param query_src string
---@param query_dir string
---@return string? err
function M.do_copy_queries(logger, query_src, query_dir)
  install_fs.rmpath(query_dir, logger)
  local err = uv_mkdir(query_dir, 493)
  if err then
    return logger:error('Could not create query dir: %s', err)
  end

  for f in fs.dir(query_src) do
    local cerr = uv_copyfile(fs.joinpath(query_src, f), fs.joinpath(query_dir, f))
    if cerr then
      return logger:error('Could not copy %s: %s', f, cerr)
    end
  end
  a.schedule()
  if err then
    return logger:error(err)
  end
end

return M
