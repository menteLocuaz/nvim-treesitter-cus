local fs = vim.fs

local a = require('nvim-treesitter.async')
local install_fs = require('nvim-treesitter.install.fs')
local system = require('nvim-treesitter.install.system')

local M = {}

local uv_unlink = a.awrap(2, vim.uv.fs_unlink)
local uv_rename = a.awrap(3, vim.uv.fs_rename)
local uv_copyfile = a.awrap(4, vim.uv.fs_copyfile)

--- Downloads and extracts a parser tarball from GitHub.
--- Steps: download -> create tmp dir -> extract -> remove tarball -> move to output.
---@async
---@param logger Logger
---@param url string
---@param project_name string
---@param cache_dir string
---@param revision string
---@param output_dir string
---@return string? err
function M.do_download(logger, url, project_name, cache_dir, revision, output_dir)
  local tmp = output_dir .. '-tmp'

  local cerr = install_fs.rmpath(tmp, logger)
  if cerr then
    logger:debug('Could not clean up tmp dir: %s', cerr)
  end
  a.schedule()

  url = url:gsub('.git$', '')
  local target = string.format('%s/archive/%s.tar.gz', url, revision)
  local tarball_path = fs.joinpath(cache_dir, project_name .. '.tar.gz')

  logger:info('Downloading %s...', project_name)
  local r = system.system({
    'curl',
    '--silent',
    '--fail',
    '--show-error',
    '--retry',
    '7',
    '-L',
    target,
    '--output',
    tarball_path,
  }, nil, logger)
  if r.code > 0 then
    return logger:error('Error during download: %s', r.stderr)
  end

  logger:debug('Creating temporary directory: %s', tmp)
  local err = install_fs.mkpath(tmp, logger)
  a.schedule()
  if err then
    return logger:error('Could not create %s-tmp: %s', project_name, err)
  end

  logger:debug('Extracting %s into %s...', tarball_path, project_name)
  r = system.system(
    { 'tar', '-xzf', project_name .. '.tar.gz', '-C', project_name .. '-tmp' },
    { cwd = cache_dir },
    logger
  )
  if r.code > 0 then
    return logger:error('Error during tarball extraction: %s', r.stderr)
  end

  logger:debug('Removing %s...', tarball_path)
  err = uv_unlink(tarball_path)
  a.schedule()
  if err then
    return logger:error('Could not remove tarball: %s', err)
  end

  local dir_rev = revision:find('^v%d') and revision:sub(2) or revision
  local repo_project_name = url:match('[^/]+$')
  local extracted = fs.joinpath(tmp, repo_project_name .. '-' .. dir_rev)
  logger:debug('Moving %s to %s/...', extracted, output_dir)
  err = uv_rename(extracted, output_dir)
  a.schedule()
  if err then
    return logger:error('Could not rename temp: %s', err)
  end

  install_fs.rmpath(tmp, logger)
  a.schedule()
end

return M
