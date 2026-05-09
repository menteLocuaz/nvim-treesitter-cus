local utils = require('nvim-treesitter.indent.utils')
local constants = require('nvim-treesitter.indent.constants')

local node_mod = require('nvim-treesitter.indent.node')

local KIND = constants.KIND

local function process(ctx)
  local srow = ctx.srow
  local erow = ctx.erow
  local row = ctx.row
  local indent = ctx.indent
  local indent_size = ctx.indent_size
  local queries = ctx.queries
  local node_id = ctx.node_id
  local node = ctx.node
  local line_cache = ctx.line_cache

  if ctx.processed_rows[srow] then
    return { indent = indent, kind = KIND.SKIP }
  end

  local align_meta = queries[utils.CAPTURE.ALIGN][node_id]
  local is_err = utils.has_error_ancestor(node)

  if not align_meta and is_err then
    align_meta = node_mod.resolve_align_from_children(node, queries)
    if align_meta then
      queries[utils.CAPTURE.ALIGN][node_id] = align_meta
    end
  end

  if not align_meta then
    return { indent = indent, kind = KIND.SKIP }
  end

  local is_multiline = srow ~= erow
  local is_target_line = srow == row

  if (not is_multiline and not is_err) or is_target_line then
    return { indent = indent, kind = KIND.SKIP }
  end

  local open_delim = align_meta['indent.open_delimiter']
  local close_delim = align_meta['indent.close_delimiter']

  local line = line_cache:get(srow + 1)

  local o_delim_node = node
  local o_is_last = false
  if open_delim then
    local found, found_is_last = utils.find_delimiter(line, open_delim, node)
    if found then
      o_delim_node = found
      o_is_last = found_is_last
    end
  end
  if not o_delim_node then
    return { indent = indent, kind = KIND.SKIP }
  end

  local c_delim_node = node
  local c_is_last = false
  if close_delim then
    local found, found_is_last = utils.find_delimiter(line, close_delim, node)
    if found then
      c_delim_node = found
      c_is_last = found_is_last
    end
  end

  local open_srow, open_scol = o_delim_node:start()
  local close_srow = c_delim_node and select(1, c_delim_node:start())

  local indent_kind = KIND.RELATIVE

  if o_is_last then
    indent = indent + indent_size
    if c_is_last and close_srow and close_srow < row then
      indent = math.max(indent - indent_size, 0)
    end
  else
    if c_is_last and close_srow and open_srow ~= close_srow and close_srow < row then
      indent = math.max(indent - indent_size, 0)
    else
      indent = open_scol + (align_meta['indent.increment'] or 1)
      indent_kind = KIND.ABSOLUTE
    end
  end

  local avoid_last = false
  if close_srow and close_srow ~= open_srow and close_srow == row then
    avoid_last = align_meta['indent.avoid_last_matching_next'] or false
  end

  if avoid_last then
    if indent <= vim.fn.indent(open_srow + 1) + indent_size then
      indent = indent + indent_size
    end
  end

  return { indent = indent, kind = indent_kind }
end

return {
  apply = process,
}
