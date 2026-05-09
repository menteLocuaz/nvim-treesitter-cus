local M = {}

local function proxy(mod, fn)
  return function(...)
    return require(mod)[fn](...)
  end
end

M.setup = proxy('nvim-treesitter.config', 'setup')
M.get_available = proxy('nvim-treesitter.config', 'get_available')
M.get_installed = proxy('nvim-treesitter.config', 'get_installed')

M.install = proxy('nvim-treesitter.install', 'install')
M.uninstall = proxy('nvim-treesitter.install', 'uninstall')
M.update = proxy('nvim-treesitter.install', 'update')

function M.indentexpr()
  local ok, indent = pcall(require, 'nvim-treesitter.indent')
  if not ok then
    return -1
  end
  return indent.get_indent(vim.v.lnum)
end

return M
