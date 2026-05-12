-- nvim-treesitter.indent.rules.ignore
-- Pipeline rule that handles @indent.ignore nodes.
--
-- @indent.ignore marks nodes whose internal content should be completely
-- excluded from Treesitter indent calculation. When the target row falls
-- *strictly inside* such a node (not on its opening or closing line),
-- this rule stops the pipeline and returns no indent value, signalling
-- that the line should be left exactly as-is.
--
-- Typical use cases:
--   - Multi-line string literals (the content between delimiters should
--     not be re-indented by Treesitter).
--   - Heredocs and raw string blocks.
--   - Embedded language regions that manage their own indentation.
--
-- Difference from @indent.auto:
--   @indent.auto returns indent = -1 (delegate to Neovim's fallback engine).
--   @indent.ignore returns no indent at all (KIND.STOP with no indent field),
--   meaning "do not touch this line's indentation".

local utils = require('nvim-treesitter.indent.utils')
local constants = require('nvim-treesitter.indent.constants')

local KIND = constants.KIND

--- Applies the @indent.ignore rule to the current pipeline node.
---
--- Logic:
---   A node qualifies for ignore if ALL of the following are true:
---     1. It does NOT have @indent.begin — begin nodes handle their own indent.
---     2. It DOES have @indent.ignore   — explicitly opted in to ignore.
---
---   If the node qualifies AND the target row is strictly inside the node
---   (start_row < row < end_row), stop the pipeline immediately with no
---   indent value, preserving the line's current indentation unchanged.
---
---   The "strictly inside" condition excludes both the opening line
---   (start_row) and the closing line (end_row), which are still handled
---   normally by the rest of the pipeline.
---
--- @param _ table           The rule object itself (unused; present for pipeline interface).
--- @param ctx IndentContext  Current pipeline context.
--- @return IndentResult
---   { kind = KIND.STOP }                    – inside an ignored node; preserve indent.
---   { indent = ctx.indent, kind = KIND.SKIP } – node does not qualify; pass through.
---
--- Boundary cases:
---   - row == start_row: condition is false (opening line handled by pipeline).
---   - row == end_row:   condition is false (closing line handled by pipeline).
---     This is stricter than @indent.auto, which includes the closing line.
---   - @indent.begin and @indent.ignore both set: @indent.begin takes precedence
---     (the begin check short-circuits before ignore is evaluated).
---   - No indent field in the STOP result: unlike @indent.auto (indent = -1),
---     returning KIND.STOP without an indent field tells the caller to leave
---     the line's indentation completely untouched.
local function process(ctx)
  local node_id = ctx.node_id
  local queries = ctx.queries
  local row = ctx.row

  local begin_meta = queries[utils.CAPTURE.BEGIN][node_id]
  local ignore_meta = queries[utils.CAPTURE.IGNORE][node_id]

  if not begin_meta and ignore_meta then
    local start_row = ctx.srow
    local end_row = ctx.erow

    -- Strictly inside: both opening and closing lines are excluded.
    -- Compare with @indent.auto which uses row <= end_row (includes closing line).
    if start_row < row and row < end_row then
      return { kind = KIND.STOP }
    end
  end

  -- Node does not qualify; leave indent unchanged and continue pipeline.
  return { indent = ctx.indent, kind = KIND.SKIP }
end

return {
  apply = process,
}
