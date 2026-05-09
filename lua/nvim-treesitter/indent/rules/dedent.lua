local utils = require('nvim-treesitter.indent.utils')
local constants = require('nvim-treesitter.indent.constants')

local KIND = constants.KIND

local function process(ctx)
  local srow = ctx.srow
  local row = ctx.row
  local indent = ctx.indent
  local indent_size = ctx.indent_size
  local queries = ctx.queries
  local node_id = ctx.node_id

  if ctx.processed_rows[srow] then
    return { indent = indent, kind = KIND.SKIP }
  end

  local branch_meta = queries[utils.CAPTURE.BRANCH][node_id]
  local dedent_meta = queries[utils.CAPTURE.DEDENT][node_id]

  local is_start_row = srow == row

  local should_dedent = (branch_meta and is_start_row) or (dedent_meta and not is_start_row)

  if should_dedent then
    return {
      indent = math.max(indent - indent_size, 0),
      kind = KIND.RELATIVE,
    }
  end

  return { indent = indent, kind = KIND.SKIP }
end

return {
  apply = process,
}
