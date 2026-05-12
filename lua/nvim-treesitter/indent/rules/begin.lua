local utils = require('nvim-treesitter.indent.utils')
local constants = require('nvim-treesitter.indent.constants')

local KIND = constants.KIND

local function process(ctx)
  local node_id = ctx.node_id
  local queries = ctx.queries
  local row = ctx.row
  local indent = ctx.indent
  local indent_size = ctx.indent_size

  local begin_meta = queries[utils.CAPTURE.BEGIN][node_id]
  if not begin_meta then
    return { indent = indent, kind = KIND.SKIP }
  end

  if ctx.processed_rows[ctx.srow] then
    return { indent = indent, kind = KIND.SKIP }
  end

  local srow, erow = ctx.srow, ctx.erow
  local is_multiline = srow ~= erow
  local is_target_line = srow == row
  local is_end_line = erow == row

  local immediate = begin_meta['indent.immediate']
  local same_line = begin_meta['indent.start_at_same_line']
  local should_indent = (is_multiline or immediate)
    and (not is_target_line or same_line)
    and not is_end_line

  if should_indent then
    return { indent = indent + indent_size, kind = KIND.RELATIVE }
  end

  return { indent = indent, kind = KIND.SKIP }
end

return {
  apply = process,
}
