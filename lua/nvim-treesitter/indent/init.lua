-- nvim-treesitter.indent
-- Main entry point for Treesitter-based indentation. Implements the
-- indentexpr-compatible M.get_indent(lnum) function that Neovim calls
-- whenever it needs to know the correct indentation level for a given line.
--
-- Architecture overview:
--   1. A Treesitter parser is used to resolve the syntax node at the target line.
--   2. The node's ancestor chain (parent → grandparent → ... → root) is walked.
--   3. Each ancestor is passed through a pipeline of indent rules in order.
--   4. Rules can adjust the running indent, mark rows as processed, or stop
--      the pipeline early by returning { stop = true }.
--   5. The final accumulated indent value is returned to Neovim.
--
-- Pipeline rules (applied in order for each ancestor node):
--   auto   – Applies default indentation based on node type.
--   ignore – Skips nodes that should not affect indentation.
--   dedent – Reduces indentation for closing delimiters and similar constructs.
--   begin  – Increases indentation for block-opening nodes.
--   align  – Handles alignment-based indentation (e.g., multi-line arguments).

local ts = vim.treesitter

local M = {}

local utils = require('nvim-treesitter.indent.utils')
local cache = require('nvim-treesitter.indent.cache')
local parser = require('nvim-treesitter.indent.parser')
local node_mod = require('nvim-treesitter.indent.node')
local constants = require('nvim-treesitter.indent.constants')

-- Parsers that should be treated as comments (e.g., injected comment languages).
-- Used by rules to skip comment nodes during indent calculation.
local COMMENT_PARSERS = utils.COMMENT_PARSERS

-- Ordered list of indent rule modules. Each rule exposes an `apply(rule, ctx)`
-- method that receives the current IndentContext and returns an IndentResult or nil.
-- Rules are tried in order for every node in the ancestor chain; the first rule
-- that returns { stop = true } terminates the entire walk immediately.
local pipeline = {
  require('nvim-treesitter.indent.rules.auto'),
  require('nvim-treesitter.indent.rules.ignore'),
  require('nvim-treesitter.indent.rules.dedent'),
  require('nvim-treesitter.indent.rules.begin'),
  require('nvim-treesitter.indent.rules.align'),
}

-- Re-export COMMENT_PARSERS so external modules can extend or inspect the list.
M.comment_parsers = COMMENT_PARSERS

--- @class IndentResult
--- Returned by each pipeline rule's apply() method.
--- @field indent    integer   The new indent level to apply (in spaces).
--- @field processed boolean?  If true, marks the node's start row as processed
---                            so subsequent rules or ancestor passes can skip it.
--- @field stop      boolean?  If true, immediately returns `indent` as the final
---                            result, bypassing all remaining rules and ancestors.

--- @class IndentContext
--- Mutable state object threaded through the entire pipeline for a single
--- get_indent() call. Rules read from and write to this object as they process
--- each ancestor node.
---
--- @field bufnr          integer                   Buffer being indented.
--- @field row            integer                   0-based target row (lnum - 1).
--- @field indent         integer|nil               Running indent accumulator. nil until first rule sets it.
--- @field indent_size    integer                   Value of 'shiftwidth' for this buffer.
--- @field queries        table                     Parsed Treesitter indent queries for the language.
--- @field processed_rows table<integer, boolean>   Rows already handled by a rule (keyed by 0-based row).
--- @field line_cache     table                     LineCache for efficient repeated line text lookups.
--- @field _root          TSNode                    Root node of the syntax tree.
--- @field node           TSNode                    The ancestor node currently being evaluated.
--- @field node_id        integer                   Unique ID of the current node (for fast equality checks).
--- @field srow           integer                   0-based start row of the current node.
--- @field erow           integer                   0-based end row of the current node.

local IndentContext = {}

--- Creates a new IndentContext for a single get_indent() invocation.
---
--- @param bufnr       integer  Buffer number.
--- @param row         integer  0-based target row.
--- @param indent_size integer  Shiftwidth value.
--- @param queries     table    Indent queries (must have a `_root` TSNode field).
--- @param line_cache  table    LineCache instance for this buffer.
--- @return IndentContext
function IndentContext.new(bufnr, row, indent_size, queries, line_cache)
  local self = setmetatable({}, { __index = IndentContext })
  self.bufnr = bufnr
  self.row = row
  -- Resolve the initial indent from the root node (e.g., for embedded languages
  -- that start indented within a host document).
  self.indent = parser.resolve_initial_indent(queries._root)
  self.indent_size = indent_size
  self.queries = queries
  self.line_cache = line_cache
  self.processed_rows = {}
  self._root = queries._root
  return self
end

--- Marks a row as processed (or unprocessed) in this context.
--- Rules use this to signal that a particular row's indentation contribution
--- has already been accounted for, preventing double-counting by later rules.
---
--- @param srow      integer  0-based row number to mark.
--- @param processed boolean  True to mark as processed, false/nil to clear.
function IndentContext:add_processed(srow, processed)
  self.processed_rows[srow] = processed
end

-- NodeWalker: Stateless iterator utilities for traversing the syntax tree.
local NodeWalker = {}

--- Returns an iterator that walks from `start_node` up to the root,
--- yielding each ancestor node (including start_node itself) one at a time.
--- Stops when a node has no parent (i.e., the root has been reached).
---
--- @param start_node TSNode  The node to begin walking from.
--- @return fun(): TSNode?    Iterator function; returns nil when exhausted.
---
--- Example:
---   for node in NodeWalker.parents(leaf_node) do
---     print(node:type())  -- prints each ancestor type up to root
---   end
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

--- Computes the correct indentation level for line `lnum` using Treesitter.
--- This function is intended to be set as Neovim's `indentexpr`:
---   vim.bo.indentexpr = 'v:lua.require("nvim-treesitter.indent").get_indent(v:lnum)'
---
--- Algorithm:
---   1. Parse the visible range of the buffer.
---   2. Resolve the root node and language for the target line.
---   3. Find the most specific syntax node at the target line.
---   4. Walk ancestors from that node to the root.
---   5. For each ancestor, run all pipeline rules in order.
---   6. Return the final accumulated indent, or stop early if a rule says so.
---
--- @param lnum integer  1-based line number (as passed by Neovim's indentexpr).
--- @return integer      Indentation level in spaces, or:
---                        -1 if no parser is available (Neovim falls back to default).
---                         0 if the line has forced zero indent.
---
--- Boundary cases:
---   - Returns -1 if no Treesitter parser exists for the buffer or lnum is nil.
---   - Returns 0 if the root/language cannot be resolved (parse failure).
---   - Returns 0 immediately if the target node is marked @indent.zero in queries.
---   - If a pipeline rule raises an error, the error is reported via vim.notify
---     and the current (partial) indent is returned rather than crashing.
function M.get_indent(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local parser_obj = ts.get_parser(bufnr)
  if not parser_obj or not lnum then
    return -1 -- Signal Neovim to use its built-in fallback indentation.
  end

  -- Parse only the visible window range for performance; avoids re-parsing
  -- the entire file on every keystroke.
  parser_obj:parse({ vim.fn.line('w0') - 1, vim.fn.line('w$') })

  local row = lnum - 1
  local root, lang_tree = parser.resolve_root(parser_obj, row)
  if not root or not lang_tree then
    return 0
  end

  local line_cache = cache.LineCache.new(bufnr)
  local q = parser.get_indents(bufnr, root, lang_tree:lang(), row)
  q._root = root

  local target_node = node_mod.resolve_target_node(root, line_cache, lnum, q)

  local indent_size = vim.fn.shiftwidth()

  -- Fast path: if the target node is explicitly marked as zero-indent in the
  -- query (e.g., top-level module declarations), skip the pipeline entirely.
  if target_node and node_mod.has_zero_indent(target_node, q) then
    return 0
  end

  local ctx = IndentContext.new(bufnr, row, indent_size, q, line_cache)

  -- Walk from the target node up to the root, running the full rule pipeline
  -- at each level. This allows rules at different levels of the tree to each
  -- contribute to (or override) the final indent.
  for node in NodeWalker.parents(target_node) do
    ctx.node = node
    ctx.node_id = node:id()
    ctx.srow = node:start()
    ctx.erow = node:end_()

    for _, rule in ipairs(pipeline) do
      local ok, result = pcall(rule.apply, rule, ctx)
      if not ok then
        -- A rule threw an error. Report it asynchronously (vim.schedule avoids
        -- calling vim.notify from inside indentexpr, which can cause issues),
        -- then return the best indent computed so far rather than crashing.
        vim.schedule(function()
          vim.notify('[treesitter-indent] Rule error: ' .. tostring(result), vim.log.WARN)
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
