---@class LineCache
---@field bufnr integer
---@field cache table<integer, string>

---@class LineCacheModule
---@field new fun(bufnr: integer): LineCache
---@field get fun(self: LineCache, lnum: integer): string
---@field get_indent fun(self: LineCache, lnum: integer): integer
---@field get_global fun(bufnr: integer): LineCache
---@field invalidate fun(bufnr: integer): nil
---@field memoize fun<T...>(fn: fun(...: T...)): fun(...: T...)

---LineCache holds cached lines for a buffer to avoid repeated API calls.
---NOTE: Lines are cached for the lifetime of the buffer. If the buffer is
---modified externally, the cache may return stale data until invalidation.
local LineCache = {}

---Create a new LineCache for the given buffer.
---@param bufnr integer Buffer number
---@return LineCache
function LineCache.new(bufnr)
  local self = setmetatable({}, { __index = LineCache })
  self.bufnr = bufnr
  self.cache = {}
  self.tick = vim.api.nvim_buf_get_changedtick(bufnr)
  return self
end

---Get a line from the cache (or fetch it from the buffer).
---@param lnum integer 1-based line number
---@return string
function LineCache:get(lnum)
  local tick = vim.api.nvim_buf_get_changedtick(self.bufnr)
  if self.tick ~= tick then
    self.cache = {}
    self.tick = tick
  end

  if not self.cache[lnum] then
    self.cache[lnum] = vim.api.nvim_buf_get_lines(self.bufnr, lnum - 1, lnum, false)[1] or ''
  end
  return self.cache[lnum]
end

---Get the indentation columns of a line.
---@param lnum integer 1-based line number
---@return integer Number of indentation columns
function LineCache:get_indent(lnum)
  local line = self:get(lnum)
  local _, indentcols = line:find('^%s*')
  return indentcols or 0
end

---Memoize a function with efficient key generation.
---@generic T: any[]
---@param fn fun(...: T)
---@return fun(...: T)
local function memoize(fn)
  local cache = {}

  return function(arg1, arg2, ...)
    -- Optimized path for 1 or 2 arguments (common in indent logic)
    if not ... then
      if not arg2 then
        if cache[arg1] == nil then
          local v = fn(arg1)
          cache[arg1] = v ~= nil and v or vim.NIL
        end
        local v = cache[arg1]
        return v ~= vim.NIL and v or nil
      end

      local c1 = cache[arg1]
      if not c1 then
        c1 = {}
        cache[arg1] = c1
      end
      if c1[arg2] == nil then
        local v = fn(arg1, arg2)
        c1[arg2] = v ~= nil and v or vim.NIL
      end
      local v = c1[arg2]
      return v ~= vim.NIL and v or nil
    end

    -- Fallback for 3+ arguments
    local key = table.concat(vim.tbl_map(tostring, { arg1, arg2, ... }), ':')
    if cache[key] == nil then
      local v = fn(arg1, arg2, ...)
      cache[key] = v ~= nil and v or vim.NIL
    end
    local v = cache[key]
    return v ~= vim.NIL and v or nil
  end
end

---Global cache keyed by buffer number.
---@type table<integer, LineCache>
local global_cache = {}

---Get or create a global LineCache for a buffer.
---@param bufnr integer Buffer number
---@return LineCache
function LineCache.get_global(bufnr)
  if not global_cache[bufnr] then
    global_cache[bufnr] = LineCache.new(bufnr)
  end
  return global_cache[bufnr]
end

---Invalidate the cache for a buffer.
---@param bufnr integer Buffer number
function LineCache.invalidate(bufnr)
  global_cache[bufnr] = nil
end

function LineCache._reset()
  global_cache = {}
end

return {
  LineCache = LineCache,
  memoize = memoize,
}
