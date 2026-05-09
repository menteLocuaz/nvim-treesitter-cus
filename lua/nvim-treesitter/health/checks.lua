local M = {}

---@class ExecutableInfo
---@field path string
---@field version table|nil
---@field out string

local NVIM_TREESITTER_MINIMUM_ABI = 13
M.NVIM_TREESITTER_MINIMUM_ABI = NVIM_TREESITTER_MINIMUM_ABI
M.TREE_SITTER_MIN_VER = { 0, 26, 1 }

function M.check_exe(name)
  if vim.fn.executable(name) == 1 then
    local path = vim.fn.exepath(name)
    local out = vim.trim(vim.fn.system({ name, '--version' }))
    local ok, version = pcall(vim.version.parse, out)
    return { path = path, version = ok and version or nil, out = out }
  end
  return nil
end

function M.install_health()
  local health = vim.health

  health.start('Requirements')

  do
    if vim.fn.has('nvim-0.12') ~= 1 then
      health.error('Nvim-treesitter requires Neovim 0.12.0 or later.')
    end

    if vim.treesitter.language_version >= NVIM_TREESITTER_MINIMUM_ABI then
      health.ok(
        'Neovim was compiled with tree-sitter runtime ABI version '
          .. vim.treesitter.language_version
          .. ' (required >='
          .. NVIM_TREESITTER_MINIMUM_ABI
          .. ').'
      )
    else
      health.error(
        'Neovim was compiled with tree-sitter runtime ABI version '
          .. vim.treesitter.language_version
          .. '.\n'
          .. 'nvim-treesitter expects at least ABI version '
          .. NVIM_TREESITTER_MINIMUM_ABI
          .. '\n'
          .. 'Please make sure that Neovim is linked against a recent tree-sitter library when building'
          .. ' or raise an issue at your Neovim packager. Parsers must be compatible with runtime ABI.'
      )
    end
  end

  do
    local ts = M.check_exe('tree-sitter')
    if ts and ts.version then
      if vim.version.ge(ts.version, M.TREE_SITTER_MIN_VER) then
        health.ok(string.format('tree-sitter-cli %s (%s)', ts.version, ts.path))
      else
        health.error(
          string.format('tree-sitter-cli v%d.%d.%d is required', unpack(M.TREE_SITTER_MIN_VER))
        )
      end
    else
      health.error('tree-sitter-cli not found or invalid version')
    end
  end

  do
    local tar = M.check_exe('tar')
    if tar then
      health.ok(string.format('tar %s (%s)', tar.version or 'unknown', tar.path))
    else
      health.error('tar not found')
    end

    local curl = M.check_exe('curl')
    if curl then
      health.ok(string.format('curl %s (%s)', curl.version or 'unknown', curl.path))
    else
      health.error('curl not found')
    end
  end

  health.start('OS Info')
  local osinfo = vim.uv.os_uname()
  for k, v in pairs(osinfo) do
    health.info(k .. ': ' .. v)
  end
end

function M.check_install_dir()
  local health = vim.health
  local config = require('nvim-treesitter.config')

  local installdir = config.get_install_dir('')
  health.start('Install directory for parsers and queries')
  health.info(installdir)

  if vim.uv.fs_access(installdir, 'w') then
    health.ok('is writable.')
  else
    health.error('is not writable.')
  end

  if
    vim.list_contains(vim.tbl_map(vim.fs.normalize, vim.api.nvim_list_runtime_paths()), installdir)
  then
    health.ok('is in runtimepath.')
  else
    health.error('is not in runtimepath.')
  end
end

return M
