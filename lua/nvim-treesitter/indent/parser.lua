local ts = vim.treesitter

local utils = require('nvim-treesitter.indent.utils')
local CAPTURE = utils.CAPTURE

local EMPTY = setmetatable({}, {
  __newindex = function()
    error('attempt to mutate EMPTY metadata')
  end,
  __metatable = false,
})

local indents_cache = {}
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

    local size = local_root:byte_length()
    if best_size and size >= best_size then
      return
    end

    if ts.is_in_node_range(local_root, row, 0) then
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
  local srow, _, root_start = root:start()
  if root_start ~= 0 then
    return vim.fn.indent(srow + 1)
  end
  return 0
end

local function should_clear(bufnr)
  local tick = vim.b[bufnr].changedtick
  if changedtick_cache[bufnr] ~= tick then
    changedtick_cache[bufnr] = tick
    indents_cache = {}
    return true
  end
  return false
end

---@param bufnr integer
---@param root TSNode
---@param lang string
---@param row? integer
---@return table<string, table<integer, table>>
local VIEWPORT_PADDING = 200

local function get_indents(bufnr, root, lang, row)
  should_clear(bufnr)

  local srow, scol, erow, ecol = root:range()
  local cache_key = string.format('%d:%s:%d:%d:%d:%d', bufnr, lang, srow, scol, erow, ecol)

  local cached = indents_cache[cache_key]
  if cached then
    return cached
  end

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
    indents_cache[cache_key] = map
    return map
  end

  local captures = query.captures

  local start_row, end_row
  if row ~= nil then
    start_row = math.max(row - VIEWPORT_PADDING, srow)
    end_row = math.min(row + VIEWPORT_PADDING, erow)
  else
    start_row = srow
    end_row = erow
  end

  for id, node, metadata in query:iter_captures(root, bufnr, start_row, end_row) do
    local capture = captures[id]
    if capture and capture:sub(1, 1) ~= '_' then
      local bucket = map[capture]
      if bucket then
        bucket[node:id()] = metadata or EMPTY
      end
    end
  end

  indents_cache[cache_key] = map
  return map
end

local M = {
  resolve_root = resolve_root,
  resolve_initial_indent = resolve_initial_indent,
  get_indents = get_indents,
}

function M.clear_cache()
  indents_cache = {}
end

return M
