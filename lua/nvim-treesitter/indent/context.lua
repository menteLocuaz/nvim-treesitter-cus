local M = {}

--- Creates a new IndentContext for a single get_indent() invocation.
function M.new(bufnr, row, indent_size, queries, root, line_cache, any_capture)
  local self = setmetatable({}, { __index = M })
  self.bufnr = bufnr
  self.row = row
  self.indent = require('nvim-treesitter.indent.parser').resolve_initial_indent(root)
  self.indent_size = indent_size
  self.queries = queries
  self.any_capture = any_capture or {}
  self.line_cache = line_cache
  self.processed_rows = {}
  self._root = root
  return self
end

function M:add_processed(srow, processed)
  self.processed_rows[srow] = processed
end

return M
