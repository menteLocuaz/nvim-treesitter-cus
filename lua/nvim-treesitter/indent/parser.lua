local ts = vim.treesitter

local utils = require('nvim-treesitter.indent.utils')
local CAPTURE = utils.CAPTURE

local CAPTURE_KEYS = {
  CAPTURE.AUTO,
  CAPTURE.BEGIN,
  CAPTURE.END,
  CAPTURE.DEDENT,
  CAPTURE.BRANCH,
  CAPTURE.IGNORE,
  CAPTURE.ALIGN,
  CAPTURE.ZERO,
}

local MAX_POOL_SIZE = 64

local EMPTY_METADATA = setmetatable({}, {
  __newindex = function()
    error('attempt to mutate EMPTY metadata')
  end,
  __metatable = false,
})

local function new_capture_map()
  local map = {}
  for i = 1, #CAPTURE_KEYS do
    map[CAPTURE_KEYS[i]] = {}
  end
  return map
end

local capture_map_pool = {}

local function clear_capture_map(map)
  for i = 1, #CAPTURE_KEYS do
    local bucket = map[CAPTURE_KEYS[i]]
    if bucket then
      for k in pairs(bucket) do
        bucket[k] = nil
      end
    end
  end
end

local function acquire_capture_map()
  local pool = capture_map_pool
  local n = #pool
  if n > 0 then
    local map = pool[n]
    pool[n] = nil
    return map
  end
  return new_capture_map()
end

local function release_capture_map(map)
  if map and #capture_map_pool < MAX_POOL_SIZE then
    clear_capture_map(map)
    capture_map_pool[#capture_map_pool + 1] = map
  end
end

local function release_buffer_cache(buf_cache)
  if not buf_cache then
    return
  end
  for _, map in pairs(buf_cache) do
    release_capture_map(map)
  end
end

local VIEWPORT_PADDING = 200

local COMMENT_PARSERS = utils.COMMENT_PARSERS

---Cache keyed by bufnr, then by cache_key (lang + root range).
---@type table<integer, table<string, table>>
local indents_cache = {}

---LRU tracking for cache eviction.
---MAX_CACHE_PER_BUFFER is small (32), so O(N) operations are acceptable.
---@type table<integer, { order: string[], index: table<string, integer> }>
local lru_tracker = {}

---Tracks changedtick per buffer to detect modifications.
---@type table<integer, integer>
local changedtick_cache = {}

local MAX_CACHE_PER_BUFFER = 32

---Precomputed valid captures per query.
---@type table<string, table<integer, string>>
local valid_captures_cache = {}

---@param parser vim.treesitter.LanguageTree
---@param row integer
---@return TSNode|nil, vim.treesitter.LanguageTree|nil
local function resolve_root(parser, row)
  row = math.max(row or 0, 0)

  local root, lang_tree
  local best_size

  parser:for_each_tree(function(tstree, tree)
    if not tstree then
      return
    end
    local lang = tree:lang()
    if COMMENT_PARSERS[lang] then
      return
    end
    local local_root = tstree:root()
    if not local_root then
      return
    end

    if ts.is_in_node_range(local_root, row, 0) then
      local sr, _, er, _ = local_root:range()
      local size = er - sr
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

local function build_valid_captures(query)
  local valid = {}
  for id, cap in ipairs(query.captures) do
    if string.byte(cap, 1) ~= 95 then
      valid[id] = cap
    end
  end
  return valid
end

local function get_valid_captures(lang, query)
  local cache_key = lang .. ':' .. tostring(query)
  local cached = valid_captures_cache[cache_key]
  if cached then
    return cached
  end
  local valid = build_valid_captures(query)
  valid_captures_cache[cache_key] = valid
  return valid
end

local function touch_lru(bufnr, cache_key)
  local tracker = lru_tracker[bufnr]
  if not tracker then
    tracker = { order = {}, index = {} }
    lru_tracker[bufnr] = tracker
  end

  local idx = tracker.index[cache_key]
  if idx then
    table.remove(tracker.order, idx)
    for i = idx, #tracker.order do
      tracker.index[tracker.order[i]] = i
    end
  end

  tracker.order[#tracker.order + 1] = cache_key
  tracker.index[cache_key] = #tracker.order
end

---Evict oldest entry if cache exceeds MAX_CACHE_PER_BUFFER.
local function evict_if_needed(bufnr, buf_cache)
  local tracker = lru_tracker[bufnr]
  if tracker and #tracker.order >= MAX_CACHE_PER_BUFFER then
    local oldest = table.remove(tracker.order, 1)
    tracker.index[oldest] = nil
    -- Update indices for all shifted elements
    for i = 1, #tracker.order do
      tracker.index[tracker.order[i]] = i
    end

    local old_map = buf_cache[oldest]
    if old_map then
      release_capture_map(old_map)
      buf_cache[oldest] = nil
    end
  end
end

local function clear_if_stale(bufnr)
  local tick = vim.b[bufnr].changedtick
  if changedtick_cache[bufnr] ~= tick then
    changedtick_cache[bufnr] = tick
    release_buffer_cache(indents_cache[bufnr])
    indents_cache[bufnr] = nil
    lru_tracker[bufnr] = nil
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

  local cache_key = lang
    .. ':'
    .. srow
    .. ':'
    .. scol
    .. ':'
    .. erow
    .. ':'
    .. ecol
    .. ':'
    .. start_row
    .. ':'
    .. end_row

  local buf_cache = indents_cache[bufnr]
  if buf_cache then
    local cached = buf_cache[cache_key]
    if cached then
      touch_lru(bufnr, cache_key)
      return cached
    end
  else
    buf_cache = {}
    indents_cache[bufnr] = buf_cache
  end

  evict_if_needed(bufnr, buf_cache)

  local map = acquire_capture_map()

  local query = ts.query.get(lang, 'indents')
  if not query then
    buf_cache[cache_key] = map
    touch_lru(bufnr, cache_key)
    return map
  end

  local valid_captures = get_valid_captures(lang, query)

  for id, node, metadata in query:iter_captures(root, bufnr, start_row, end_row) do
    local capture = valid_captures[id]
    if capture then
      local bucket = map[capture]
      if bucket then
        bucket[node:id()] = metadata or EMPTY_METADATA
      end
    end
  end

  buf_cache[cache_key] = map
  touch_lru(bufnr, cache_key)
  return map
end

local M = {
  resolve_root = resolve_root,
  resolve_initial_indent = resolve_initial_indent,
  get_indents = get_indents,
}

function M.clear_cache(bufnr)
  if bufnr then
    release_buffer_cache(indents_cache[bufnr])
    indents_cache[bufnr] = nil
    changedtick_cache[bufnr] = nil
    lru_tracker[bufnr] = nil
  else
    for _, buf_cache in pairs(indents_cache) do
      release_buffer_cache(buf_cache)
    end
    indents_cache = {}
    changedtick_cache = {}
    lru_tracker = {}
  end
end

return M
