local ts = vim.treesitter

local M = {}

local CAPTURE = {
  AUTO = 'indent.auto',
  BEGIN = 'indent.begin',
  END = 'indent.end',
  DEDENT = 'indent.dedent',
  BRANCH = 'indent.branch',
  IGNORE = 'indent.ignore',
  ALIGN = 'indent.align',
  ZERO = 'indent.zero',
}

local COMMENT_PARSERS = {
  comment = true,
  luadoc = true,
  javadoc = true,
  jsdoc = true,
  phpdoc = true,
}

M.comment_parsers = COMMENT_PARSERS

local LineCache = {}

function LineCache.new(bufnr)
  local self = setmetatable({}, { __index = LineCache })
  self.bufnr = bufnr
  self.cache = {}
  return self
end

function LineCache:get(lnum)
  if not self.cache[lnum] then
    self.cache[lnum] = vim.api.nvim_buf_get_lines(self.bufnr, lnum - 1, lnum, false)[1] or ''
  end
  return self.cache[lnum]
end

function LineCache:getline(lnum)
  return self:get(lnum)
end

function LineCache:get_indent(lnum)
  local _, indentcols = self:get(lnum):find('^%s*')
  return indentcols or 0
end

local function escape_pattern(str)
  return str:gsub('[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1')
end

local function is_last_in_line(text, start_pos)
  local remaining = text:sub(start_pos + 1)
  return remaining:gsub('[%s' .. ']*', '') == ''
end

local function find_delimiter_node(node, delimiter)
  for child, _ in node:iter_children() do
    if child:type() == delimiter then
      return child
    end
  end
  return nil
end

local function find_delimiter(line, delimiter, node)
  local delim_node = find_delimiter_node(node, delimiter)
  if not delim_node then
    return nil, false
  end

  local end_col = delim_node:end_()
  local escaped_delimiter = escape_pattern(delimiter)
  line:sub(end_col + 1):gsub('[%s' .. escaped_delimiter .. ']*', '')
  local is_last = is_last_in_line(line, end_col)

  return delim_node, is_last
end

local function memoize(fn)
  local cache = {}

  return function(...)
    local key = string.format('%s:%s:%s', ...)
    if cache[key] == nil then
      local v = fn(...)
      cache[key] = v ~= nil and v or vim.NIL
    end

    local v = cache[key]
    return v ~= vim.NIL and v or nil
  end
end

local get_indents = memoize(function(bufnr, root, lang)
  local map = {
    [CAPTURE.AUTO] = {},
    [CAPTURE.BEGIN] = {},
    [CAPTURE.END] = {},
    [CAPTURE.DEDENT] = {},
    [CAPTURE.BRANCH] = {},
    [CAPTURE.IGNORE] = {},
    [CAPTURE.ALIGN] = {},
    [CAPTURE.ZERO] = {},
  }

  local query = ts.query.get(lang, 'indents')
  if not query then
    return map
  end
  for id, node, metadata in query:iter_captures(root, bufnr) do
    if assert(query.captures[id]):sub(1, 1) ~= '_' then
      map[query.captures[id]][node:id()] = metadata or {}
    end
  end

  return map
end)

local function resolve_root(parser)
  local root, lang_tree
  parser:for_each_tree(function(tstree, tree)
    if not tstree or COMMENT_PARSERS[tree:lang()] then
      return
    end
    local local_root = tstree:root()
    if ts.is_in_node_range(local_root, 0, 0) then
      if not root or root:byte_length() >= local_root:byte_length() then
        root = local_root
        lang_tree = tree
      end
    end
  end)
  return root, lang_tree
end

local function resolve_target_node(root, line_cache, lnum, q)
  local is_blank = line_cache:get(lnum):find('^%s*$')

  if is_blank then
    local prevlnum = vim.fn.prevnonblank(lnum)
    local indentcols = line_cache:get_indent(prevlnum)
    local prevline = vim.trim(line_cache:get(prevlnum))

    local node = root:descendant_for_range(
      prevlnum - 1,
      indentcols + #prevline - 1,
      prevlnum - 1,
      indentcols + #prevline
    )

    if node and node:type():match('comment') then
      local first_node =
        root:descendant_for_range(prevlnum - 1, indentcols, prevlnum - 1, indentcols + 1)
      local _, scol, _, _ = node:range()
      if first_node and first_node:id() ~= node:id() then
        prevline = vim.trim(prevline:sub(1, scol - indentcols))
        local col = indentcols + #prevline - 1
        node = root:descendant_for_range(prevlnum - 1, col, prevlnum - 1, col + 1)
      end
    end

    if node and q[CAPTURE.END][node:id()] then
      return root:descendant_for_range(lnum - 1, 0, lnum - 1, 1)
    end

    return node
  end

  return root:descendant_for_range(lnum - 1, 0, lnum - 1, 1)
end

local function compute_base_indent(root)
  local _, _, root_start = root:start()
  if root_start ~= 0 then
    return vim.fn.indent(root:start() + 1)
  end
  return 0
end

local function resolve_zero_indent(node, q)
  local node_id = node:id()
  if q[CAPTURE.ZERO][node_id] then
    return 0
  end
  return nil
end

local function process_autoindent(node_id, q, node, row)
  if
    not q[CAPTURE.BEGIN][node_id]
    and not q[CAPTURE.ALIGN][node_id]
    and q[CAPTURE.AUTO][node_id]
  then
    if node:start() < row and row <= node:end_() then
      return -1
    end
  end
  return nil
end

local function process_ignore(node_id, q, node, row)
  if not q[CAPTURE.BEGIN][node_id] and q[CAPTURE.IGNORE][node_id] then
    if node:start() < row and row <= node:end_() then
      return 0
    end
  end
  return nil
end

local function apply_branch_indent(is_processed_by_row, q, node, node_id, row, indent, indent_size)
  local srow = node:start()
  local is_branch = q[CAPTURE.BRANCH][node_id]
  local is_dedent = q[CAPTURE.DEDENT][node_id]

  if not is_processed_by_row[srow] then
    if (is_branch and srow == row) or (is_dedent and srow ~= row) then
      return indent - indent_size, true
    end
  end
  return indent, false
end

local function get_node_range(node)
  local srow, _, erow, _ = node:range()
  return srow, erow
end

local function has_error_ancestor(node)
  local parent = node:parent()
  return parent and parent:has_error() or false
end

local function resolve_align_from_children(node, q)
  for child in node:iter_children() do
    local child_id = child:id()
    if q[CAPTURE.ALIGN][child_id] then
      return q[CAPTURE.ALIGN][child_id]
    end
  end
  return nil
end

local function apply_begin_indent(
  is_processed_by_row,
  q,
  _node,
  node_id,
  srow,
  erow,
  row,
  indent,
  indent_size
)
  if is_processed_by_row[srow] then
    return indent, false
  end

  local begin_meta = q[CAPTURE.BEGIN][node_id]
  if not begin_meta then
    return indent, false
  end

  local is_multiline = srow ~= erow
  local is_target_line = srow == row

  if is_multiline or begin_meta['indent.immediate'] then
    if not is_target_line or begin_meta['indent.start_at_same_line'] then
      return indent + indent_size, true
    end
  end

  return indent, false
end

local function apply_align_indent(
  line_cache,
  is_processed_by_row,
  q,
  node,
  node_id,
  srow,
  erow,
  row,
  indent,
  indent_size
)
  if is_processed_by_row[srow] then
    return indent, false
  end

  local align_meta = q[CAPTURE.ALIGN][node_id]
  if not align_meta then
    return indent, false
  end

  local is_multiline = srow ~= erow
  local is_target_line = srow == row
  local is_err = has_error_ancestor(node)

  if is_err and not align_meta then
    align_meta = resolve_align_from_children(node, q)
    if align_meta then
      q[CAPTURE.ALIGN][node_id] = align_meta
    end
  end

  if not (is_multiline or is_err) or is_target_line then
    return indent, false
  end

  local open_delim = align_meta['indent.open_delimiter']
  local close_delim = align_meta['indent.close_delimiter']

  local line = line_cache:get(srow + 1)

  local o_delim_node, o_is_last = nil, false
  if open_delim then
    o_delim_node, o_is_last = find_delimiter(line, open_delim, node)
  end
  o_delim_node = o_delim_node or node

  local c_delim_node, c_is_last = nil, false
  if close_delim then
    c_delim_node, c_is_last = find_delimiter(line, close_delim, node)
  end
  c_delim_node = c_delim_node or node

  if not o_delim_node then
    return indent, false
  end

  local o_srow, o_scol = o_delim_node:start()
  local c_srow = c_delim_node and c_delim_node:start()

  local indent_is_absolute = false

  if o_is_last then
    if not is_processed_by_row[srow] then
      indent = indent + indent_size
      if c_is_last and c_srow and c_srow < row then
        indent = math.max(indent - indent_size, 0)
      end
    end
  else
    if c_is_last and c_srow and o_srow ~= c_srow and c_srow < row then
      indent = math.max(indent - indent_size, 0)
    else
      indent = o_scol + (align_meta['indent.increment'] or 1)
      indent_is_absolute = true
    end
  end

  local avoid_last = false
  if c_srow and c_srow ~= o_srow and c_srow == row then
    avoid_last = align_meta['indent.avoid_last_matching_next'] or false
  end

  if avoid_last then
    if indent <= vim.fn.indent(o_srow + 1) + indent_size then
      indent = indent + indent_size
    end
  end

  if indent_is_absolute then
    return indent, true
  end

  return indent, true
end

function M.get_indent(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = ts.get_parser(bufnr)
  if not parser or not lnum then
    return -1
  end

  parser:parse({ vim.fn.line('w0') - 1, vim.fn.line('w$') })

  local root, lang_tree = resolve_root(parser)
  if not root or not lang_tree then
    return 0
  end

  local line_cache = LineCache.new(bufnr)
  local q = get_indents(bufnr, root, lang_tree:lang())

  local node = resolve_target_node(root, line_cache, lnum, q)

  local indent_size = vim.fn.shiftwidth()
  local indent = compute_base_indent(root)

  local is_processed_by_row = {}

  if node then
    local zero = resolve_zero_indent(node, q)
    if zero then
      return zero
    end
  end

  local row = lnum - 1

  while node do
    local node_id = node:id()
    local srow, erow = get_node_range(node)

    local result = process_autoindent(node_id, q, node, row)
    if result then
      return result
    end

    result = process_ignore(node_id, q, node, row)
    if result then
      return result
    end

    indent, is_processed_by_row[srow] =
      apply_branch_indent(is_processed_by_row, q, node, node_id, row, indent, indent_size)

    indent, is_processed_by_row[srow] = apply_begin_indent(
      is_processed_by_row,
      q,
      node,
      node_id,
      srow,
      erow,
      row,
      indent,
      indent_size
    )

    indent, is_processed_by_row[srow] = apply_align_indent(
      line_cache,
      is_processed_by_row,
      q,
      node,
      node_id,
      srow,
      erow,
      row,
      indent,
      indent_size
    )

    is_processed_by_row[srow] = is_processed_by_row[srow] or false

    node = node:parent()
  end

  return indent
end

return M
