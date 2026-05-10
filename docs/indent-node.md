# nvim-treesitter.indent.node Reference

This module provides utilities for resolving which Treesitter node should be used as the starting point for indent calculation.

## Overview

The key challenge this module addresses is that the "target node" for indentation is not always the node at the cursor position:
- Blank lines have no node of their own; the previous non-blank line's node is used instead
- Trailing comments on a line should be stripped before resolving the node
- The node at column 0 is used for non-blank lines (outermost node on the line)

## API

### `M.resolve_target_node(root, line_cache, lnum, q)`

Resolves the Treesitter node that should serve as the starting point for indent calculation for line `lnum`.

**Parameters:**
- `root` (TSNode): Root of the syntax tree
- `line_cache` (table): LineCache instance for efficient line text lookups
- `lnum` (integer): 1-based target line number (as from indentexpr)
- `q` (table): Indent query table mapping capture names to node indices

**Returns:** TSNode? - The anchor node, or nil if none can be found

**Behavior:**
- **Non-blank line**: Returns the node at column 0 of that line (the first token)
- **Blank line**: Delegates to `resolve_blank_line_node`, using the previous non-blank line's last meaningful node

**Edge Cases:**
- Returns nil if `line_cache:get(lnum)` returns nil (line outside buffer)
- For blank lines at the top of file (no previous non-blank), falls back to node at column 0 of current row

**Example:**
```lua
local node = Node.resolve_target_node(parser:root(), line_cache, 42, indent_queries)
```

---

### `M.has_zero_indent(node, q)`

Returns true if `node` is marked with the `@indent.zero` capture, meaning this node should always be indented at column 0 regardless of nesting depth.

**Parameters:**
- `node` (TSNode): The node to check
- `q` (table): Indent query table

**Returns:** boolean

**Use Case:** Top-level declarations in some languages that should never be indented

**Example:**
```lua
if Node.has_zero_indent(node, q) then
  return 0
end
```

---

### `M.resolve_align_from_children(node, q)`

Searches direct children of `node` for one marked with `@indent.align` capture and returns its alignment data.

**Parameters:**
- `node` (TSNode): The parent node whose children to search
- `q` (table): Indent query table

**Returns:** table|nil - The alignment capture data, or nil if no child has it

**Behavior:**
- Only direct children are checked (not deeper descendants)
- Results are memoized in a weak-keyed cache to avoid redundant iteration

**Edge Cases:**
- Returns nil immediately if the language has no `@indent.align` captures at all (avoids cache pollution)
- Uses CACHE_MISS sentinel to avoid re-scanning nodes that were checked and had no align capture

**Example:**
```lua
local align_data = Node.resolve_align_from_children(parent_node, q)
if align_data then
  -- Use align_data.indent (number) or align_data.align (number)
end
```

---

### `M.clear_cache()`

Clears the align cache by reallocating the table. Should be called after a buffer re-parse to prevent stale alignment data from the previous tree being used with nodes from the new tree.

**Parameters:** None

**Returns:** Nothing

**Example:**
```lua
-- Called automatically by indent module after re-parsing
vim.api.nvim_buf_attach(bufnr, false, {
  on_detach = function() Node.clear_cache() end
})
```

---

## Internal Functions

### `get_node(root, row, col)`

Returns the most specific (deepest) Treesitter node covering position (row, col).

**Parameters:**
- `root` (TSNode?): Root of the syntax tree
- `row` (integer): 0-based row number
- `col` (integer): 0-based column number (clamped to >= 0)

**Returns:** TSNode? - The deepest node at that position, or nil if root is nil

### `has_capture(q, capture, node)`

Checks if `node` has a given query capture applied.

**Parameters:**
- `q` (table): Indent query table
- `capture` (string): Capture name constant from utils.CAPTURE
- `node` (TSNode): The node to check

**Returns:** boolean

### `strip_trailing_comment(root, prevlnum, indentcols, prevline)`

If the last token on a line is a comment, returns the node immediately before it (the last "real" token).

**Parameters:**
- `root` (TSNode): Root of the syntax tree
- `prevlnum` (integer): 1-based line number of the previous non-blank line
- `indentcols` (integer): Number of leading whitespace columns on that line
- `prevline` (string): Trimmed text content of that line (no leading whitespace)

**Returns:** TSNode? - The node just before the trailing comment, or nil

**Edge Cases:**
- Returns nil if the line does not end with a comment
- Returns nil if the comment is the only token on the line
- Handles `scol - indentcols < 0` by clamping to 0 (prevents negative column)

### `resolve_blank_line_node(root, line_cache, row, prevlnum, q)`

Resolves the anchor node for a blank line using the previous non-blank line's last meaningful node.

**Parameters:**
- `root` (TSNode): Root of the syntax tree
- `line_cache` (table): LineCache instance
- `row` (integer): 0-based row of the blank line itself
- `prevlnum` (integer): 1-based line number of the previous non-blank line (0 if none)
- `q` (table): Indent query table

**Returns:** TSNode?

**Edge Cases:**
- If previous line's content is empty after trim, falls back to node at column 0 of current row
- If resolved node has `@indent.end` capture, falls back to node at column 0 (blank line after block close)

---

## Query Capture Types

The module uses these capture types (from `utils.CAPTURE`):

| Capture | Purpose |
|---------|---------|
| `@indent.begin` | Node that starts an indent block |
| `@indent.end` | Node that ends an indent block (e.g., `end`, `}`, `)`) |
| `@indent.align` | Node that defines alignment target for children |
| `@indent.zero` | Node that should always have indent = 0 |
| `@indent.auto` | Auto-indent based on syntax |
| `@indent.branch` | Branch indicator (e.g., `else`, `catch`) |
| `@indent.dedent` | Force dedent |
| `@indent.ignore` | Skip indent calculation for this node |

---

## Performance Notes

- **align_cache** uses weak keys (`__mode = 'k'`) so entries are GC'd when the node is no longer referenced
- Fast path in `resolve_align_from_children` skips cache entirely when language has no align captures
- `CACHE_MISS` sentinel prevents re-scanning nodes that were already checked