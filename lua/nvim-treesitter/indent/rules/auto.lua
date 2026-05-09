-- nvim-treesitter.indent.rules.auto
-- Pipeline rule that handles @indent.auto nodes.
--
-- @indent.auto marks nodes whose indentation should be delegated back to
-- Neovim's built-in indentation engine rather than computed by the Treesitter
-- pipeline. When the target row falls *inside* such a node (but not on its
-- opening line), this rule signals an early stop with indent = -1.
--
-- Returning indent = -1 from get_indent() tells Neovim to fall back to its
-- default indentexpr / autoindent behaviour for that line, which is the
-- correct outcome for node types whose internal layout Treesitter queries
-- do not (or cannot) fully describe (e.g., multi-line strings, heredocs,
-- embedded languages).

local utils = require('nvim-treesitter.indent.utils')
local constants = require('nvim-treesitter.indent.constants')

local KIND = constants.KIND

local function process(ctx)
  local node_id = ctx.node_id
  local queries = ctx.queries
  local node = ctx.node
  local row = ctx.row

  if
    not queries[utils.CAPTURE.BEGIN][node_id] -- Not a block-opener.
    and not queries[utils.CAPTURE.ALIGN][node_id] -- Not an alignment node.
    and queries[utils.CAPTURE.AUTO][node_id] -- Explicitly marked @indent.auto.
  then
    local start_row = select(1, node:start())
    local end_row = select(1, node:end_())

    -- Target row is a continuation line inside this node (not the opening line).
    if start_row < row and row <= end_row then
      return { indent = -1, kind = KIND.STOP }
    end
  end

  -- Node does not qualify for auto-delegation; leave indent unchanged and
  -- continue to the next rule in the pipeline.
  return { indent = ctx.indent, kind = 'skip' }
end

-- Pipeline interface: the rule exposes a single `apply` function.
-- Called as rule:apply(ctx) by the main pipeline loop in indent/init.lua.
return {
  apply = process,
}
