-- nvim-treesitter.indent
-- Main entry point for Treesitter-based indentation. Implements the
-- indentexpr-compatible M.get_indent(lnum) function that Neovim calls
-- whenever it needs to know the correct indentation level for a given line.

local ts = vim.treesitter

local M = {}

local utils = require('nvim-treesitter.indent.utils')
local cache = require('nvim-treesitter.indent.cache')
local parser = require('nvim-treesitter.indent.parser')
local node_mod = require('nvim-treesitter.indent.node')
local constants = require('nvim-treesitter.indent.constants')

local COMMENT_PARSERS = utils.COMMENT_PARSERS

local pipeline = {
  require('nvim-treesitter.indent.rules.auto'),
  require('nvim-treesitter.indent.rules.ignore'),
  require('nvim-treesitter.indent.rules.dedent'),
  require('nvim-treesitter.indent.rules.begin'),
  require('nvim-treesitter.indent.rules.align'),
}

M.comment_parsers = COMMENT_PARSERS

vim.api.nvim_create_autocmd({ 'BufUnload', 'BufDelete', 'BufWipeout' }, {
  callback = function(args)
    cache.LineCache.invalidate(args.buf)
    require('nvim-treesitter.indent.parser').clear_cache(args.buf)
    require('nvim-treesitter.indent.utils').clear_error_cache()
    require('nvim-treesitter.indent.node').clear_cache()
  end,
})

local IndentContext = {}

--- Creates a new IndentContext for a single get_indent() invocation.
function IndentContext.new(bufnr, row, indent_size, queries, root, line_cache)
  local self = setmetatable({}, { __index = IndentContext })
  self.bufnr = bufnr
  self.row = row
  self.indent = parser.resolve_initial_indent(root)
  self.indent_size = indent_size
  self.queries = queries
  self.line_cache = line_cache
  self.processed_rows = {}
  self._root = root
  return self
end

function IndentContext:add_processed(srow, processed)
  self.processed_rows[srow] = processed
end

local NodeWalker = {}

function NodeWalker.parents(start_node)
  local current = start_node
  return function()
    if not current then
      return nil
    end
    local node = current
    current = current:parent()
    return node
  end
end

function M.get_indent(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local parser_obj = ts.get_parser(bufnr)
  if not parser_obj or not lnum then
    return -1
  end

  parser_obj:parse({ vim.fn.line('w0') - 1, vim.fn.line('w$') })

  local row = lnum - 1
  local root, lang_tree = parser.resolve_root(parser_obj, row)
  if not root or not lang_tree then
    return 0
  end

  local line_cache = cache.LineCache.get_global(bufnr)
  local q = parser.get_indents(bufnr, root, lang_tree:lang(), row)

  local target_node = node_mod.resolve_target_node(root, line_cache, lnum, q)

  local indent_size = vim.fn.shiftwidth()

  if target_node and node_mod.has_zero_indent(target_node, q) then
    return 0
  end

  local ctx = IndentContext.new(bufnr, row, indent_size, q, root, line_cache)

  for node in NodeWalker.parents(target_node) do
    ctx.node = node
    ctx.node_id = node:id()
    ctx.srow = select(1, node:start())
    ctx.erow = select(1, node:end_())

    for _, rule in ipairs(pipeline) do
      local ok, result = pcall(rule.apply, ctx)
      if not ok then
        vim.schedule(function()
          vim.notify('[treesitter-indent] Rule error: ' .. tostring(result), vim.log.levels.WARN)
        end)
        return ctx.indent
      end
      if result then
        local kind = result.kind or 'relative'
        if kind == constants.KIND.STOP then
          return result.indent or ctx.indent
        end
        ctx.indent = result.indent
        if kind == constants.KIND.RELATIVE or kind == constants.KIND.ABSOLUTE then
          ctx:add_processed(ctx.srow, true)
        end
      end
    end
  end

  return ctx.indent
end

return M
