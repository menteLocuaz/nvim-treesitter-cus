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

local MAX_CACHE_PER_BUFFER = 32

local EMPTY_METADATA = setmetatable({}, {
  __newindex = function()
    error('attempt to mutate EMPTY metadata')
  end,
  __metatable = false,
})

local COMMENT_PARSERS = utils.COMMENT_PARSERS

-- CLOCK cache: O(1) amortized eviction, no array shifts.
-- Guarantee: evict() terminates in at most 2 * max iterations.
local ClockCache = {}
ClockCache.__index = ClockCache

function ClockCache.new(max_size)
  return setmetatable({
    slots = {},
    index = {},
    hand = 1,
    max = max_size,
    size = 0,
  }, ClockCache)
end

function ClockCache:get(key)
  local idx = self.index[key]
  if idx then
    self.slots[idx].ref = true
    return self.slots[idx].value
  end
end

function ClockCache:put(key, value)
  local idx = self.index[key]
  if idx then
    self.slots[idx].value = value
    self.slots[idx].ref = true
    return
  end

  if self.size < self.max then
    self.size = self.size + 1
    self.slots[self.size] = { key = key, value = value, ref = true }
    self.index[key] = self.size
    return
  end

  for _ = 1, 2 * self.max do
    local slot = self.slots[self.hand]
    if not slot.ref then
      self.index[slot.key] = nil
      slot.key = key
      slot.value = value
      slot.ref = true
      self.index[key] = self.hand
      self.hand = self.hand % self.max + 1
      return
    end
    slot.ref = false
    self.hand = self.hand % self.max + 1
  end
  error('ClockCache: evict invariant violated after 2*max iterations')
end

function ClockCache:clear()
  self.slots = {}
  self.index = {}
  self.hand = 1
  self.size = 0
end

---Holds all mutable cache state for indent calculations.
---Separate from the capture_map_pool (which is an object recycler, not a cache).
local CacheState = {}
CacheState.__index = CacheState

function CacheState.new()
  return setmetatable({
    clock_caches = {}, ---@type table<integer, ClockCache>
    changedtick_cache = {}, ---@type table<integer, integer>
    valid_captures_cache = {}, ---@type table<string, table<integer, string>>
    any_capture_cache = {}, ---@type table<string, table<integer, true>>
  }, CacheState)
end

local default = CacheState.new()

local M = {}

---@return CacheState
function M.new()
  return CacheState.new()
end

local function new_capture_map()
  local map = {}
  for i = 1, #CAPTURE_KEYS do
    map[CAPTURE_KEYS[i]] = {}
  end
  return map
end

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
  local cached = default.valid_captures_cache[cache_key]
  if cached then
    return cached
  end
  local valid = build_valid_captures(query)
  default.valid_captures_cache[cache_key] = valid
  return valid
end

local function clear_if_stale(bufnr)
  local tick = vim.b[bufnr].changedtick
  if default.changedtick_cache[bufnr] ~= tick then
    default.changedtick_cache[bufnr] = tick
    local cc = default.clock_caches[bufnr]
    if cc then
      cc:clear()
    end
    local prefix = tostring(bufnr) .. ':'
    for k in pairs(default.any_capture_cache) do
      if k:sub(1, #prefix) == prefix then
        default.any_capture_cache[k] = nil
      end
    end
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

  local cache_key = lang .. ':' .. srow .. ':' .. scol .. ':' .. erow .. ':' .. ecol

  local buf_cache = default.clock_caches[bufnr]
  if not buf_cache then
    buf_cache = ClockCache.new(MAX_CACHE_PER_BUFFER)
    default.clock_caches[bufnr] = buf_cache
  end

  local cached = buf_cache:get(cache_key)
  if cached then
    return cached
  end

  local map = new_capture_map()

  local query = ts.query.get(lang, 'indents')
  if not query then
    buf_cache:put(cache_key, map)
    return map
  end

  local valid_captures = get_valid_captures(lang, query)

  for id, node, metadata in query:iter_captures(root, bufnr, srow, erow) do
    local capture = valid_captures[id]
    if capture then
      local bucket = map[capture]
      if bucket then
        bucket[node:id()] = metadata or EMPTY_METADATA
      end
    end
  end

  -- Build any_capture set keyed by (bufnr .. ':' .. lang).
  local ac_key = bufnr .. ':' .. lang
  if not default.any_capture_cache[ac_key] then
    local ac = {}
    for _, bucket in pairs(map) do
      for node_id in pairs(bucket) do
        ac[node_id] = true
      end
    end
    default.any_capture_cache[ac_key] = ac
  end
  map.any_capture = default.any_capture_cache[ac_key]

  buf_cache:put(cache_key, map)
  return map
end

M.resolve_root = resolve_root
M.resolve_initial_indent = resolve_initial_indent
M.get_indents = get_indents

function M.clear_cache(bufnr)
  if bufnr then
    local cc = default.clock_caches[bufnr]
    if cc then
      cc:clear()
    end
    default.changedtick_cache[bufnr] = nil
    local prefix = tostring(bufnr) .. ':'
    for k in pairs(default.any_capture_cache) do
      if k:sub(1, #prefix) == prefix then
        default.any_capture_cache[k] = nil
      end
    end
  else
    default.clock_caches = {}
    default.changedtick_cache = {}
    default.any_capture_cache = {}
  end
end

function M._reset()
  default = CacheState.new()
end

return M
