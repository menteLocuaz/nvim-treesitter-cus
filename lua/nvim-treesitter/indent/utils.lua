-- nvim-treesitter.indent.utils
-- Shared constants and utility functions used across all indent pipeline rules.
--
-- Exports:
--   CAPTURE                  – Canonical capture name constants for indent queries.
--   COMMENT_PARSERS          – Set of language names treated as comment parsers.
--   escape_pattern           – Escapes a string for use in Lua patterns.
--   is_last_in_line          – Checks if a position is followed only by whitespace.
--   find_delimiter           – Finds a delimiter child node and checks if it ends the line.
--   find_direct_child_by_type – Finds the first direct child of a given node type.
--   get_node_range           – Returns the start/end rows of a node.
--   has_error_ancestor       – Checks if a node has a parse-error ancestor (cached).
--   register_comment_parser  – Registers an additional language as a comment parser.
--   clear_error_cache        – Invalidates the has_error_ancestor cache after re-parse.

-- Canonical names for all Treesitter indent query captures.
-- These correspond to @-prefixed capture names in .scm query files, e.g.:
--   (function_definition) @indent.begin
--   (end) @indent.end
-- Rules reference these constants instead of raw strings to avoid typos and
-- to make capture name changes a single-point update.
local CAPTURE = {
  AUTO = 'indent.auto', -- Node whose indentation is inferred automatically.
  BEGIN = 'indent.begin', -- Node that opens an indented block (e.g. `if`, `{`).
  END = 'indent.end', -- Node that closes an indented block (e.g. `end`, `}`).
  DEDENT = 'indent.dedent', -- Node that reduces indent relative to its parent.
  BRANCH = 'indent.branch', -- Node that is a branch of a block (e.g. `else`, `elif`).
  IGNORE = 'indent.ignore', -- Node whose subtree should not affect indentation.
  ALIGN = 'indent.align', -- Node that triggers column-alignment indentation.
  ZERO = 'indent.zero', -- Node that forces indentation to column 0.
}

-- Set of Treesitter language names that represent comment/documentation parsers.
-- These are injected languages (e.g., luadoc inside a Lua comment) that should
-- be skipped or treated specially during indent calculation, since their internal
-- structure should not influence the indentation of surrounding code.
--
-- Extended at runtime via register_comment_parser() for languages not listed here.
local COMMENT_PARSERS = {
  comment = true, -- Generic tree-sitter-comment parser.
  luadoc = true, -- LuaDoc annotations inside Lua comments.
  javadoc = true, -- Javadoc inside Java block comments.
  jsdoc = true, -- JSDoc inside JavaScript/TypeScript comments.
  phpdoc = true, -- PHPDoc inside PHP block comments.
}

--- Snapshot of the initial COMMENT_PARSERS table, used by _reset() to restore defaults.
--- _reset() restores the module-load baseline — any registrations made via
--- register_comment_parser() during setup() WILL be lost.
local COMMENT_PARSERS_DEFAULT = vim.deepcopy(COMMENT_PARSERS)

local NodeWalker = {}

--- Returns an iterator over the ancestors of a node, starting with the node itself.
--- @param start_node TSNode  The node to start walking from.
--- @return fun(): TSNode?    An iterator function.
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

--- Registers an additional language as a comment parser.
--- Call this from a language-specific config if the language uses an injected
--- comment parser not in the default COMMENT_PARSERS set.
---
--- @param lang string  Treesitter language name to mark as a comment parser.
---
--- Example:
---   utils.register_comment_parser('rustdoc')
local function register_comment_parser(lang)
  COMMENT_PARSERS[lang] = true
end

-- Module-level cache mapping node ID (integer) -> boolean.
-- Stores whether a given node has a parse-error ancestor, to avoid
-- re-walking the ancestor chain on every rule invocation for the same node.
-- Invalidated by clear_error_cache() after each buffer re-parse.
local error_ancestor_cache = {}

---Returns true if `node` or any of its ancestors contains a Treesitter parse error.
---Used by rules to skip unreliable indent calculations in syntactically broken
---regions of the buffer.
---
---Results are memoized by node ID. Note: node IDs are reused across re-parses,
---so clear_error_cache() must be called after each parse to avoid stale hits.
---@param node TSNode The node to check.
---@return boolean True if node or any ancestor has_error(), false otherwise.
local function has_error_ancestor(node)
  local node_id = node:id()
  local cached = error_ancestor_cache[node_id]
  if cached ~= nil then
    return cached
  end

  if node:has_error() then
    error_ancestor_cache[node_id] = true
    return true
  end

  local parent = node:parent()
  while parent do
    if parent:has_error() then
      error_ancestor_cache[node_id] = true
      return true
    end
    parent = parent:parent()
  end

  error_ancestor_cache[node_id] = false
  return false
end

--- Escapes all Lua pattern special characters in `str` so it can be used
--- as a literal string match inside string.find / string.match.
---
--- Special characters escaped: ( ) . % + - * ? [ ] ^ $
---
--- @param str string  The raw string to escape.
--- @return string     The escaped string safe for use in a Lua pattern.
---
--- Example:
---   escape_pattern('foo.bar()')  -->  'foo%.bar%(%)'
local function escape_pattern(str)
  return (str:gsub('[%(%)%.%%%+%-%*%?%[%]%^%$]', '%%%1'))
end

--- Returns true if everything after position `start_pos` in `text` is
--- whitespace (or the string ends). Used to determine whether a delimiter
--- or token is the last meaningful character on a line.
---
--- @param text      string   The full line text.
--- @param start_pos integer  0-based byte offset; checks text[start_pos+1 ..].
--- @return boolean
---
--- Example:
---   is_last_in_line('foo(  ', 3)   --> true   (only spaces after col 3)
---   is_last_in_line('foo(bar', 3)  --> false  ('bar' follows)
local function is_last_in_line(text, start_pos)
  return text:sub(start_pos + 1):match('^%s*$') ~= nil
end

--- Finds the first direct child of `node` whose type exactly matches `delimiter`.
--- Only immediate children are searched (not deeper descendants).
---
--- @param node      TSNode  The parent node to search.
--- @param delimiter string  The node type to look for (e.g. '(', 'end', ',').
--- @return TSNode?          The first matching child, or nil if none found.
local function find_direct_child_by_type(node, delimiter)
  for child in node:iter_children() do
    if child:type() == delimiter then
      return child
    end
  end
  return nil
end

--- Finds a delimiter child node within `node` and checks whether it is the
--- last meaningful token on `line`. Combines find_direct_child_by_type with
--- is_last_in_line for the common pattern used by the align rule.
---
--- @param line      string  The full text of the line containing the node.
--- @param delimiter string  The child node type to search for.
--- @param node      TSNode  The parent node to search within.
--- @return TSNode?, boolean
---   - First return: the delimiter node, or nil if not found.
---   - Second return: true if the delimiter is the last token on the line.
---                    Always false if the delimiter node was not found.
---
--- Example — checking if `(` ends the line (triggers align indentation):
---   local delim, is_last = find_delimiter(line, '(', call_node)
---   if delim and is_last then ... end
local function find_delimiter(line, delimiter, node)
  local delim_node = find_direct_child_by_type(node, delimiter)
  if not delim_node then
    return nil, false
  end

  local _, end_col = delim_node:end_()
  return delim_node, is_last_in_line(line, end_col)
end

--- Returns the 0-based start and end row numbers of `node`.
--- A convenience wrapper around node:range() that discards column information,
--- since most indent rules only care about which rows a node spans.
---
--- @param node TSNode  The node to query.
--- @return integer, integer  srow (inclusive), erow (inclusive).
local function get_node_range(node)
  local srow, _, erow, _ = node:range()
  return srow, erow
end

--- Invalidates the has_error_ancestor cache.
--- Must be called after each Treesitter re-parse, because node IDs are
--- recycled between parse generations and stale cache entries would cause
--- incorrect results for new nodes that happen to share an old ID.
local function clear_error_cache()
  error_ancestor_cache = {}
end

local function reset()
  COMMENT_PARSERS = vim.deepcopy(COMMENT_PARSERS_DEFAULT)
  error_ancestor_cache = {}
end

return {
  CAPTURE = CAPTURE,
  COMMENT_PARSERS = COMMENT_PARSERS,
  NodeWalker = NodeWalker,
  escape_pattern = escape_pattern,
  is_last_in_line = is_last_in_line,
  find_delimiter = find_delimiter,
  find_direct_child_by_type = find_direct_child_by_type,
  get_node_range = get_node_range,
  has_error_ancestor = has_error_ancestor,
  register_comment_parser = register_comment_parser,
  clear_error_cache = clear_error_cache,
  _reset = reset,
}
