local ts = vim.treesitter

local M = {}

M.comment_parsers = {
  comment = true,
  luadoc = true,
  javadoc = true,
  jsdoc = true,
  phpdoc = true,
}

--- Default side-effect provider (allows for injection during testing without changing the public API)
local default_ctx = {
  get_current_buf = function()
    return vim.api.nvim_get_current_buf()
  end,
  get_parser = function(bufnr)
    return ts.get_parser(bufnr)
  end,
  get_lines = function(bufnr, start_row, end_row, strict)
    return vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, strict)
  end,
  get_query = function(lang, name)
    return ts.query.get(lang, name)
  end,
  is_in_node_range = function(node, line, col)
    return ts.is_in_node_range(node, line, col)
  end,
  line = function(expr)
    return vim.fn.line(expr)
  end,
  prevnonblank = function(lnum)
    return vim.fn.prevnonblank(lnum)
  end,
  shiftwidth = function()
    return vim.fn.shiftwidth()
  end,
  indent = function(lnum)
    return vim.fn.indent(lnum)
  end,
  trim = function(s)
    return vim.trim(s)
  end,
}

---@param lnum integer
---@param ctx? table
---@return string
local function getline(lnum, ctx)
  ctx = ctx or default_ctx
  return ctx.get_lines(0, lnum - 1, lnum, false)[1] or ''
end

---@param lnum integer
---@param ctx? table
---@return integer
local function get_indentcols_at_line(lnum, ctx)
  local _, indentcols = getline(lnum, ctx):find('^%s*')
  return indentcols or 0
end

---@param root TSNode
---@param lnum integer
---@param col? integer
---@param ctx? table
---@return TSNode?
local function get_first_node_at_line(root, lnum, col, ctx)
  col = col or get_indentcols_at_line(lnum, ctx)
  return root:descendant_for_range(lnum - 1, col, lnum - 1, col + 1)
end

---@param root TSNode
---@param lnum integer
---@param col? integer
---@param ctx? table
---@return TSNode?
local function get_last_node_at_line(root, lnum, col, ctx)
  col = col or (#getline(lnum, ctx) - 1)
  return root:descendant_for_range(lnum - 1, col, lnum - 1, col + 1)
end

---@param s string
---@return string
local function escape_lua_pattern(s)
  return (s:gsub('[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1'))
end

---@param bufnr integer
---@param node TSNode
---@param delimiter string
---@param ctx? table
---@return TSNode? child
---@return boolean? is_end
local function find_delimiter(bufnr, node, delimiter, ctx)
  ctx = ctx or default_ctx
  for child, _ in node:iter_children() do
    if child:type() == delimiter then
      local linenr = child:start()
      local line = ctx.get_lines(bufnr, linenr, linenr + 1, false)[1]
      local end_char = { child:end_() }
      local escaped_delimiter = escape_lua_pattern(delimiter)
      local trimmed_after_delim =
        assert(line):sub(end_char[2] + 1):gsub('[%s' .. escaped_delimiter .. ']*', '')
      return child, #trimmed_after_delim == 0
    end
  end
end

---Memoize a function using hash_fn to hash the arguments.
---@generic F: function
---@param fn F
---@param hash_fn fun(...): any
---@return F
local function memoize(fn, hash_fn)
  local cache = setmetatable({}, { __mode = 'kv' }) ---@type table<any,any>

  return function(...)
    local key = hash_fn(...)
    if cache[key] == nil then
      local v = fn(...) ---@type any
      cache[key] = v ~= nil and v or vim.NIL
    end

    local v = cache[key]
    return v ~= vim.NIL and v or nil
  end
end

local get_indents = memoize(function(bufnr, root, lang, ctx)
  ctx = ctx or default_ctx
  ---@type table<string,table<any,table>>
  local map = {
    ['indent.auto'] = {},
    ['indent.begin'] = {},
    ['indent.end'] = {},
    ['indent.dedent'] = {},
    ['indent.branch'] = {},
    ['indent.ignore'] = {},
    ['indent.align'] = {},
    ['indent.zero'] = {},
  }

  local query = ctx.get_query(lang, 'indents')
  if not query then
    return map
  end
  for id, node, metadata in query:iter_captures(root, bufnr) do
    if assert(query.captures[id]):sub(1, 1) ~= '_' then
      map[query.captures[id]][node:id()] = metadata or {}
    end
  end

  return map
end, function(bufnr, root, lang)
  return tostring(bufnr) .. root:id() .. '_' .. lang
end)

--- Retrieves the language tree with the smallest range around `lnum` that does not consist of comments.
---@param parser vim.treesitter.LanguageTree
---@param lnum integer
---@param ctx table
---@return TSNode?, vim.treesitter.LanguageTree?
local function find_smallest_lang_tree(parser, lnum, ctx)
  local root, lang_tree ---@type TSNode?, vim.treesitter.LanguageTree?
  parser:for_each_tree(function(tstree, tree)
    if not tstree or M.comment_parsers[tree:lang()] then
      return
    end
    local local_root = tstree:root()
    if ctx.is_in_node_range(local_root, lnum - 1, 0) then
      if not root or root:byte_length() >= local_root:byte_length() then
        root = local_root
        lang_tree = tree
      end
    end
  end)
  return root, lang_tree
end

--- Determine the starting node for a blank line by searching backward to the previous non-empty line.
---@param root TSNode
---@param lnum integer
---@param q table<string, table>
---@param ctx table
---@return TSNode?
local function resolve_node_for_blank_line(root, lnum, q, ctx)
  local prevlnum = ctx.prevnonblank(lnum)
  local indentcols = get_indentcols_at_line(prevlnum, ctx)
  local prevline = ctx.trim(getline(prevlnum, ctx))

  -- The final position can be trailing spaces, which should not affect indentation
  local node = get_last_node_at_line(root, prevlnum, indentcols + #prevline - 1, ctx)

  if node and node:type():match('comment') then
    -- The final node we capture of the previous line can be a comment node, which should also be ignored
    -- Unless the last line is an entire line of comment, ignore the comment range and find the last node again
    local first_node = get_first_node_at_line(root, prevlnum, indentcols, ctx)
    local _, scol, _, _ = node:range()
    if first_node and first_node:id() ~= node:id() then
      -- In case the last captured node is a trailing comment node, re-trim the string
      prevline = ctx.trim(prevline:sub(1, scol - indentcols))
      -- Add back indent as indent of prevline was trimmed away
      local col = indentcols + #prevline - 1
      node = get_last_node_at_line(root, prevlnum, col, ctx)
    end
  end

  if node and q['indent.end'][node:id()] then
    node = get_first_node_at_line(root, lnum, nil, ctx)
  end

  return node
end

--- Determine the starting node from which to begin ascending the syntactic tree.
---@param root TSNode
---@param lnum integer
---@param q table<string, table>
---@param ctx table
---@return TSNode?
local function get_initial_node(root, lnum, q, ctx)
  if getline(lnum, ctx):find('^%s*$') then
    return resolve_node_for_blank_line(root, lnum, q, ctx)
  end
  return get_first_node_at_line(root, lnum, nil, ctx)
end

--- Promueve el aligned_indent del primer hijo cuando el nodo padre tiene un error sintáctico.
---@param node TSNode
---@param q table<string, table>
local function promote_child_align_on_error(node, q)
  local node_id = node:id()
  if not q['indent.align'][node_id] then
    for c in node:iter_children() do
      local c_id = c:id()
      if q['indent.align'][c_id] then
        q['indent.align'][node_id] = q['indent.align'][c_id]
        break
      end
    end
  end
end

---Calculate the indentation adjustment for nodes marked with @indent.align.
---@param bufnr integer
---@param node TSNode
---@param lnum integer
---@param indent integer
---@param indent_size integer
---@param metadata table
---@param ctx table
---@return integer new_indent
---@return boolean is_processed
---@return boolean indent_is_absolute
local function compute_aligned_indent(bufnr, node, lnum, indent, indent_size, metadata, ctx)
  local o_delim_node, o_is_last_in_line ---@type TSNode?, boolean?
  local c_delim_node, c_is_last_in_line ---@type TSNode?, boolean?
  local indent_is_absolute = false

  if metadata['indent.open_delimiter'] then
    o_delim_node, o_is_last_in_line =
      find_delimiter(bufnr, node, metadata['indent.open_delimiter'], ctx)
  else
    o_delim_node = node
  end

  if metadata['indent.close_delimiter'] then
    c_delim_node, c_is_last_in_line =
      find_delimiter(bufnr, node, metadata['indent.close_delimiter'], ctx)
  else
    c_delim_node = node
  end

  if not o_delim_node then
    return indent, false, false
  end

  local o_srow, o_scol = o_delim_node:start()
  local c_srow = c_delim_node and c_delim_node:start() or nil

  if o_is_last_in_line then
    -- hanging indent (previous line ended with starting delimiter)
    indent = indent + indent_size
    if c_is_last_in_line and c_srow and c_srow < lnum - 1 then
      -- If current line is outside the range of a node marked with `@aligned_indent`
      -- Then its indent level shouldn't be affected by `@aligned_indent` node
      indent = math.max(indent - indent_size, 0)
    end
  else
    -- aligned indent
    if c_is_last_in_line and c_srow and o_srow ~= c_srow and c_srow < lnum - 1 then
      -- If current line is outside the range of a node marked with `@aligned_indent`
      -- Then its indent level shouldn't be affected by `@aligned_indent` node
      indent = math.max(indent - indent_size, 0)
    else
      indent = o_scol + (metadata['indent.increment'] or 1)
      indent_is_absolute = true
    end
  end

  -- deal with the final line
  local avoid_last_matching_next = false
  if c_srow and c_srow ~= o_srow and c_srow == lnum - 1 then
    avoid_last_matching_next = metadata['indent.avoid_last_matching_next'] or false
  end

  if avoid_last_matching_next then
    if indent <= ctx.indent(o_srow + 1) + indent_size then
      indent = indent + indent_size
    end
  end

  return indent, true, indent_is_absolute
end

---@param lnum integer (1-indexed)
---@param _ctx? table Contexto interno opcional para inyección en pruebas unitarias
---@return integer
function M.get_indent(lnum, _ctx)
  local ctx = _ctx or default_ctx
  local bufnr = ctx.get_current_buf()
  local parser = ctx.get_parser(bufnr)
  if not parser or not lnum then
    return -1
  end

  parser:parse({ ctx.line('w0') - 1, ctx.line('w$') })

  local root, lang_tree = find_smallest_lang_tree(parser, lnum, ctx)
  if not root then
    return 0
  end

  -- Note: the second call to get_current_buf() is preserved exactly as in the original
  local q = get_indents(ctx.get_current_buf(), root, lang_tree:lang(), ctx)
  local node = get_initial_node(root, lnum, q, ctx)

  local indent_size = ctx.shiftwidth()
  local indent = 0
  local _, _, root_start = root:start()
  if root_start ~= 0 then
    -- injected tree
    indent = ctx.indent(root:start() + 1)
  end

  if node and q['indent.zero'][node:id()] then
    return 0
  end

  local is_processed_by_row = {} ---@type table<integer,boolean>
  local target_row = lnum - 1

  while node do
    local node_id = node:id()
    local srow, _, erow = node:range()

    -- do 'autoindent' if not marked as @indent
    if
      not q['indent.begin'][node_id]
      and not q['indent.align'][node_id]
      and q['indent.auto'][node_id]
      and srow < target_row
      and target_row <= erow
    then
      return -1
    end

    -- Do not indent if we are inside an @ignore block.
    if
      not q['indent.begin'][node_id]
      and q['indent.ignore'][node_id]
      and srow < target_row
      and target_row <= erow
    then
      return 0
    end

    local is_processed = false
    local should_process = not is_processed_by_row[srow]

    -- Dedent / Branch
    if
      should_process
      and (
        (q['indent.branch'][node_id] and srow == target_row)
        or (q['indent.dedent'][node_id] and srow ~= target_row)
      )
    then
      indent = indent - indent_size
      is_processed = true
    end

    -- Begin indent
    local is_in_err = false
    if should_process then
      local parent = node:parent()
      is_in_err = parent and parent:has_error() or false
    end

    local begin_meta = q['indent.begin'][node_id]
    if
      should_process
      and begin_meta
      and (srow ~= erow or is_in_err or begin_meta['indent.immediate'])
      and (srow ~= target_row or begin_meta['indent.start_at_same_line'])
    then
      indent = indent + indent_size
      is_processed = true
    end

    if is_in_err then
      promote_child_align_on_error(node, q)
    end

    -- Aligned indent
    local align_meta = q['indent.align'][node_id]
    if
      should_process
      and align_meta
      and (srow ~= erow or is_in_err)
      and (srow ~= target_row)
    then
      local aligned_processed, indent_is_absolute
      indent, aligned_processed, indent_is_absolute =
        compute_aligned_indent(bufnr, node, lnum, indent, indent_size, align_meta, ctx)
      is_processed = is_processed or aligned_processed
      if indent_is_absolute then
        return indent
      end
    end

    is_processed_by_row[srow] = is_processed_by_row[srow] or is_processed
    node = node:parent()
  end

  return indent
end

return M