-- nvim-treesitter.indent.node
-- Utilities for resolving which Treesitter node should be used as the starting
-- point for indent calculation, and for querying node-level indent captures.
--
-- The key challenge this module addresses is that the "target node" for
-- indentation is not always the node at the cursor position:
--   - Blank lines have no node of their own; the previous non-blank line's
--     node is used instead, with special handling for trailing comments and
--     @indent.end nodes.
--   - Trailing comments on a line should be stripped before resolving the
--     node, so the comment itself doesn't influence indentation.

local utils = require('nvim-treesitter.indent.utils')

local M = {}

local CAPTURE = utils.CAPTURE

-- Sentinel value to represent "cached but not found".
-- Lua cannot store explicit nil as a value (it deletes the key), so we use a unique marker.
local CACHE_MISS = {}

-- Weak-keyed cache mapping parent TSNode -> align capture result.
-- Weak keys allow entries to be GC'd automatically when the node is no longer
-- referenced by the syntax tree, preventing stale data after re-parses.
---@type table<TSNode, table|typeof(CACHE_MISS)>
local align_cache = setmetatable({}, { __mode = 'k' })

--- Returns the most specific (deepest) Treesitter node that covers the
--- single character at position (row, col) in the syntax tree.
--- Clamps col to 0 if negative to avoid out-of-range errors.
---
--- @param root TSNode?  Root of the syntax tree to search within.
--- @param row  integer  0-based row number.
--- @param col  integer  0-based column number (clamped to >= 0).
--- @return TSNode?      The deepest node at that position, or nil if root is nil.
local function get_node(root, row, col)
  if not root then
    return nil
  end
  col = math.max(col, 0)
  -- Query a 1-character wide range so we get the most specific node at (row, col).
  return root:descendant_for_range(row, col, row, col + 1)
end

--- Returns true if `node` has the given query capture applied to it.
--- Looks up the node by its unique ID in the pre-built capture index.
---
--- @param q       table   Indent query table (maps capture name -> {node_id -> value}).
--- @param capture string  Capture name constant from utils.CAPTURE.
--- @param node    TSNode  The node to check.
--- @return boolean
local function has_capture(q, capture, node)
  local captures = q[capture]
  if not captures then
    return false
  end
  return captures[node:id()] ~= nil
end

--- Checks whether the last token on a line is a comment node, and if so,
--- returns the node immediately before the comment (i.e., the last "real" token).
--- Returns nil if the line does not end with a comment, or if the comment is
--- the only token on the line (no meaningful node precedes it).
---
--- This prevents trailing comments like `end -- close block` from being
--- mistakenly used as the anchor node for indentation.
---
--- @param root      TSNode  Root of the syntax tree.
--- @param prevlnum  integer 1-based line number of the previous non-blank line.
--- @param indentcols integer Number of leading whitespace columns on that line.
--- @param prevline  string  Trimmed text content of that line (no leading whitespace).
--- @return TSNode?  The node just before the trailing comment, or nil.
local function strip_trailing_comment(root, prevlnum, indentcols, prevline)
  -- Check the node at the very end of the line's content.
  local node = get_node(root, prevlnum - 1, indentcols + #prevline - 1)

  -- If the last token is not a comment, nothing to strip.
  if not node or not node:type():match('comment') then
    return nil
  end

  -- Get the node at the start of the line's content (first non-whitespace token).
  local first_node = get_node(root, prevlnum - 1, indentcols)
  local _, scol, _, _ = node:range() -- scol: 0-based start column of the comment.

  -- If the first node IS the comment, the entire line is a comment — don't strip.
  if not first_node or first_node:id() == node:id() then
    return nil
  end

  -- Trim the line up to the comment's start column to find the last real token.
  -- scol is absolute; subtract indentcols to get a position within `prevline`.
  local rel_col = math.max(scol - indentcols, 0)
  local trimmed = vim.trim(prevline:sub(1, rel_col))
  local col = indentcols + #trimmed - 1

  return get_node(root, prevlnum - 1, col)
end

--- Resolves the anchor node for a blank line.
--- Since blank lines contain no tokens, we use the previous non-blank line's
--- last meaningful node as the anchor, with two special cases:
---
---   1. If the previous line ends with a trailing comment, strip it first
---      (see strip_trailing_comment) to avoid comment nodes influencing indent.
---   2. If the resolved node has an @indent.end capture, the blank line is
---      considered to be "after a block close", so we fall back to the node
---      at column 0 of the blank line's own row (which will typically be the
---      enclosing block's node).
---
--- @param root       TSNode   Root of the syntax tree.
--- @param line_cache table    LineCache for efficient line text lookups.
--- @param row        integer  0-based row of the blank line itself.
--- @param prevlnum   integer  1-based line number of the previous non-blank line
---                            (0 if there is no previous non-blank line).
--- @param q          table    Indent query table.
--- @return TSNode?
local function resolve_blank_line_node(root, line_cache, row, prevlnum, q)
  if prevlnum == 0 then
    -- No previous non-blank line exists (blank line at top of file).
    -- Fall back to the node at the start of the current row.
    return get_node(root, row, 0)
  end

  local raw_prevline = line_cache:get(prevlnum)
  local indent = line_cache:get_indent(prevlnum)
  local trimmed = vim.trim(raw_prevline)

  if #trimmed == 0 then
    return get_node(root, row, 0)
  end

  -- Position of the last character of the trimmed content (absolute column).
  local endcol = indent + #trimmed - 1

  local node = get_node(root, prevlnum - 1, endcol)

  -- If the line ends with a comment, use the node before the comment instead.
  local stripped = strip_trailing_comment(root, prevlnum, indent, trimmed)
  if stripped then
    node = stripped
  end

  -- If the anchor node is an @indent.end node (e.g., `end`, `}`, `)`),
  -- the blank line follows a block close. Use the node at the blank line's
  -- own row so the enclosing scope's indentation is used instead.
  if node and has_capture(q, CAPTURE.END, node) then
    return get_node(root, row, 0)
  end

  return node
end

--- Resolves the Treesitter node that should serve as the starting point for
--- indent calculation for line `lnum`. This is the node that the pipeline
--- rules will begin walking ancestors from.
---
--- Two cases:
---   - Non-blank line: use the node at column 0 of that line (the first token).
---   - Blank line: delegate to resolve_blank_line_node, which uses the previous
---     non-blank line's last meaningful node as a proxy.
---
--- @param root       TSNode  Root of the syntax tree.
--- @param line_cache table   LineCache instance.
--- @param lnum       integer 1-based target line number (as from indentexpr).
--- @param q          table   Indent query table.
--- @return TSNode?           The anchor node, or nil if none can be found.
function M.resolve_target_node(root, line_cache, lnum, q)
  local line = line_cache:get(lnum)

  if not line then
    return nil
  end

  if line:find('^%s*$') then
    -- Blank line: find the previous non-blank line and use its node as proxy.
    local prevlnum = vim.fn.prevnonblank(lnum)
    return resolve_blank_line_node(root, line_cache, lnum - 1, prevlnum, q)
  end

  -- Non-blank line: use the node at the very start of the line (col 0).
  -- Column 0 is used because we want the outermost node that starts on this
  -- line, not a deeply nested node in the middle of the content.
  return get_node(root, lnum - 1, 0)
end

--- Returns true if `node` is marked with the @indent.zero capture in the
--- indent queries, meaning this node should always be indented at column 0
--- regardless of its nesting depth (e.g., top-level declarations in some languages).
---
--- @param node TSNode  The node to check.
--- @param q    table   Indent query table.
--- @return boolean
function M.has_zero_indent(node, q)
  return has_capture(q, CAPTURE.ZERO, node)
end

--- Searches the direct children of `node` for one marked with the @indent.align
--- capture, and returns its associated alignment data if found.
--- Results are memoized in align_cache (weak-keyed on the parent node) to avoid
--- redundant child iteration on repeated calls for the same node.
---
--- @param node TSNode  The parent node whose children to search.
--- @param q    table   Indent query table.
--- @return table|nil   The alignment capture data, or nil if no child has it.
---
--- Boundary: Only direct children are checked (not deeper descendants).
--- If no child has @indent.align, CACHE_MISS is stored to prevent re-scanning.
function M.resolve_align_from_children(node, q)
  local captures = q[CAPTURE.ALIGN]
  -- Fast path: no align captures in this language at all (global condition).
  -- Skip cache entirely to avoid polluting it with CACHE_MISS for every node.
  if not captures or not next(captures) then
    return nil
  end

  -- Now safe to check cache, since we know the language has align captures.
  local cached = align_cache[node]
  if cached ~= nil then
    return cached ~= CACHE_MISS and cached or nil
  end

  for child in node:iter_children() do
    if has_capture(q, CAPTURE.ALIGN, child) then
      local result = captures[child:id()]
      align_cache[node] = result
      return result
    end
  end

  align_cache[node] = CACHE_MISS
  return nil
end

---Clears the align_cache by reallocating the table.
---Should be called after a buffer re-parse to ensure stale alignment data
---from the previous tree is not used with nodes from the new tree.
function M.clear_cache()
  align_cache = setmetatable({}, { __mode = 'k' })
end

return M
