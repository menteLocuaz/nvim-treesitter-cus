local M = {}

local function_map = {
  setup = 'nvim-treesitter.config',
  get_available = 'nvim-treesitter.config',
  get_installed = 'nvim-treesitter.config',
  install = 'nvim-treesitter.install',
  uninstall = 'nvim-treesitter.install',
  update = 'nvim-treesitter.install',
}

local module_cache = {}

setmetatable(M, {
  __index = function(t, key)
    local mod_path = function_map[key]
    if not mod_path then
      return
    end

    local mod = module_cache[mod_path]
    if not mod then
      mod = require(mod_path)
      module_cache[mod_path] = mod
    end

    local fn = mod[key]
    if fn ~= nil then
      rawset(t, key, fn)
    end

    return fn
  end,
})

local indent_mod
local indent_load_failed = false

function M.indentexpr()
  if indent_load_failed then
    return -1
  end

  if not indent_mod then
    local ok, res = pcall(require, 'nvim-treesitter.indent')
    if ok and type(res.get_indent) == 'function' then
      indent_mod = res
    else
      indent_load_failed = true
      return -1
    end
  end

  return indent_mod.get_indent(vim.v.lnum)
end

return M
