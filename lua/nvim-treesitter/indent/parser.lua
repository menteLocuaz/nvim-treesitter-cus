local ts = vim.treesitter

local utils = require('nvim-treesitter.indent.utils')
local CAPTURE = utils.CAPTURE

local EMPTY_METADATA = setmetatable({}, {
  __newindex = function()
    error('attempt to mutate EMPTY metadata')
  end,
  __metatable = false,
})

local function new_capture_map()
  return {
    [CAPTURE.AUTO] = {},
    [CAPTURE.BEGIN] = {},
    [CAPTURE.END] = {},
    [CAPTURE.DEDENT] = {},
    [CAPTURE.BRANCH] = {},
    [CAPTURE.IGNORE] = {},
    [CAPTURE.ALIGN] = {},
    [CAPTURE.ZERO] = {},
  }
end

local VIEWPORT_PADDING = 200

---Cache keyed by bufnr, then by cache_key (lang + root range).
---@type table<integer, table<string, table>>
local indents_cache = {}

---Tracks changedtick per buffer to detect modifications.
---@type table<integer, integer>
local changedtick_cache = {}

---@param parser vim.treesitter.LanguageTree
---@param row integer
---@return TSNode|nil, vim.treesitter.LanguageTree|nil
local function resolve_root(parser, row)
  row = math.max(row or 0, 0)

  local root, lang_tree
  local best_size

  parser:for_each_tree(function(tstree, tree)
    if not tstree or utils.COMMENT_PARSERS[tree:lang()] then
      return
    end
    local local_root = tstree:root()
    if not local_root then
      return
    end

    if ts.is_in_node_range(local_root, row, 0) then
      local size = local_root:byte_length()
      if not best_size or size < best_size then
        root = local_root
        lang_tree = tree
        best_size = size
      end
    end
  end)

  return root, lang_tree
end

local function resolve_initial_indent(root)
  if not root then
    return 0
  end
  local srow, scol, _ = root:start()
  if srow ~= 0 or scol ~= 0 then
    return vim.fn.indent(srow + 1)
  end
  return 0
end

local function clear_if_stale(bufnr)
  local tick = vim.b[bufnr].changedtick
  if changedtick_cache[bufnr] ~= tick then
    changedtick_cache[bufnr] = tick
    indents_cache[bufnr] = nil
  end
end

---Get indent query results for a buffer.
---@param bufnr integer
---@param root TSNode
---@param lang string
---@param row? integer
---@return table<string, table<integer, table>>
local function get_indents(bufnr, root, lang, row)
  clear_if_stale(bufnr)

  local srow, scol, erow, ecol = root:range()

  local start_row, end_row
  if row ~= nil then
    start_row = math.max(row - VIEWPORT_PADDING, srow)
    end_row = math.min(row + VIEWPORT_PADDING, erow)
  else
    start_row = srow
    end_row = erow
  end

  local cache_key = table.concat({ lang, srow, scol, erow, ecol, start_row, end_row }, ':')

  local buf_cache = indents_cache[bufnr] or {}
  indents_cache[bufnr] = buf_cache

  local cached = buf_cache[cache_key]
  if cached then
    return cached
  end

  local map = new_capture_map()

  local query = ts.query.get(lang, 'indents')
  if not query then
    buf_cache[cache_key] = map
    return map
  end

  local captures = query.captures

  for id, node, metadata in query:iter_captures(root, bufnr, start_row, end_row) do
    local capture = captures[id]
    if capture and string.byte(capture, 1) ~= 95 then
      local bucket = map[capture]
      if bucket then
        bucket[node:id()] = metadata or EMPTY_METADATA
      end
    end
  end

  buf_cache[cache_key] = map
  return map
end

local M = {
  resolve_root = resolve_root,
  resolve_initial_indent = resolve_initial_indent,
  get_indents = get_indents,
}

function M.clear_cache(bufnr)
  if bufnr then
    indents_cache[bufnr] = nil
    changedtick_cache[bufnr] = nil
  else
    indents_cache = {}
    changedtick_cache = {}
  end
end

return M
