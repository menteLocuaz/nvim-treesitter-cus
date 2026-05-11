-- nvim-treesitter.indent.node
-- Utilities for resolving which Treesitter node should be used as the starting
-- point for indent calculation, and for querying node-level indent captures.

local utils = require('nvim-treesitter.indent.utils')

local M = {}

local CAPTURE = utils.CAPTURE

-- Sentinel value to represent "cached but not found".
local CACHE_MISS = {}

-- Weak-keyed cache mapping parent TSNode -> align capture result.
---@type table<TSNode, table|typeof(CACHE_MISS)>
local align_cache = setmetatable({}, { __mode = 'k' })

---@param type_name string
---@return boolean
local function is_comment_type(type_name)
  return type_name:find('comment', 1, true) ~= nil
end

--- Returns the most specific (deepest) Treesitter node that covers the
--- single character at position (row, col) in the syntax tree.
---
--- @param root TSNode?  Root of the syntax tree to search within.
--- @param row  integer  0-based row number.
--- @param col  integer  0-based column number.
--- @return TSNode?      The deepest node at that position, or nil if root is nil.
local function get_node(root, row, col)
  if not root then
    return nil
  end
  if col < 0 then
    col = 0
  end
  -- Query a 1-character wide range so we get the most specific node at (row, col).
  return root:descendant_for_range(row, col, row, col + 1)
end

--- Returns true if `node_id` is present in the given capture bucket.
---
--- @param bucket  table?  Capture bucket (node_id -> metadata).
--- @param node_id integer Unique node ID.
--- @return boolean
local function has_capture(bucket, node_id)
  return bucket ~= nil and bucket[node_id] ~= nil
end

--- Checks whether the last token on a line is a comment node, and if so,
--- returns the node immediately before the comment (i.e., the last "real" token).
---
--- @param root      TSNode  Root of the syntax tree.
--- @param row       integer 0-based row number.
--- @param line      string  Raw text of the line.
--- @param last_pos  integer 1-based index of the last non-blank character.
--- @param indent    integer Number of leading whitespace characters.
--- @return TSNode?  The node just before the trailing comment, or nil.
local function strip_trailing_comment(root, row, line, last_pos, indent)
  -- Check the node at the very end of the line's content.
  local node = get_node(root, row, last_pos - 1)

  -- If the last token is not a comment, nothing to strip.
  if not node or not is_comment_type(node:type()) then
    return nil
  end

  -- Get the node at the start of the line's content (first non-whitespace token).
  local first_node = get_node(root, row, indent)
  if not first_node then
    return nil
  end

  local node_id = node:id()
  local first_node_id = first_node:id()

  -- If the first node IS the comment, the entire line is a comment — don't strip.
  if first_node_id == node_id then
    return nil
  end

  -- Find the column before the comment.
  local _, scol = node:range()
  local col = scol - 1

  -- Skip trailing whitespace before the comment.
  while col >= indent and line:byte(col + 1) <= 32 do
    col = col - 1
  end

  if col < indent then
    return nil
  end

  return get_node(root, row, col)
end

--- Resolves the anchor node for a blank line.
---
--- @param root       TSNode   Root of the syntax tree.
--- @param line_cache table    LineCache for efficient line text lookups.
--- @param row        integer  0-based row of the blank line itself.
--- @param prevlnum   integer  1-based line number of the previous non-blank line.
--- @param q          table    Indent query table.
--- @return TSNode?
local function resolve_blank_line_node(root, line_cache, row, prevlnum, q)
  if prevlnum == 0 then
    return get_node(root, row, 0)
  end

  local line = line_cache:get(prevlnum)
  if not line then
    return get_node(root, row, 0)
  end

  local first_pos = line:find('%S')
  if not first_pos then
    return get_node(root, row, 0)
  end

  local indent = first_pos - 1
  -- Find last non-blank character position.
  local last_pos = line:match('^.*%S%s*()') - 1
  local prev_row = prevlnum - 1

  local node = get_node(root, prev_row, last_pos - 1)

  -- Strip trailing comment if present.
  if node and is_comment_type(node:type()) then
    local stripped = strip_trailing_comment(root, prev_row, line, last_pos, indent)
    if stripped then
      node = stripped
    end
  end

  if node and has_capture(q[CAPTURE.END], node:id()) then
    return get_node(root, row, 0)
  end

  return node
end

--- Resolves the Treesitter node that should serve as the starting point for
--- indent calculation for line `lnum`.
---
--- @param root       TSNode  Root of the syntax tree.
--- @param line_cache table   LineCache instance.
--- @param lnum       integer 1-based target line number.
--- @param q          table   Indent query table.
--- @return TSNode?           The anchor node, or nil if none can be found.
function M.resolve_target_node(root, line_cache, lnum, q)
  local line = line_cache:get(lnum)

  if not line then
    return nil
  end

  if not line:find('%S') then
    -- Blank line: find the previous non-blank line and use its node as proxy.
    local prevlnum = vim.fn.prevnonblank(lnum)
    return resolve_blank_line_node(root, line_cache, lnum - 1, prevlnum, q)
  end

  -- Non-blank line: use the node at the very start of the line (col 0).
  return get_node(root, lnum - 1, 0)
end

--- Returns true if `node` is marked with the @indent.zero capture.
---
--- @param node TSNode  The node to check.
--- @param q    table   Indent query table.
--- @return boolean
function M.has_zero_indent(node, q)
  return has_capture(q[CAPTURE.ZERO], node:id())
end

--- Searches the direct children of `node` for one marked with the @indent.align.
---
--- @param node TSNode  The parent node whose children to search.
--- @param q    table   Indent query table.
--- @return table|nil   The alignment capture data, or nil if no child has it.
function M.resolve_align_from_children(node, q)
  local captures = q[CAPTURE.ALIGN]
  if not captures or not next(captures) then
    return nil
  end

  local cached = align_cache[node]
  if cached ~= nil then
    return cached ~= CACHE_MISS and cached or nil
  end

  for child in node:iter_children() do
    local result = captures[child:id()]
    if result then
      align_cache[node] = result
      return result
    end
  end

  align_cache[node] = CACHE_MISS
  return nil
end

---Clears the align_cache by removing all keys in-place.
function M.clear_cache()
  for k in pairs(align_cache) do
    align_cache[k] = nil
  end
end

return M
