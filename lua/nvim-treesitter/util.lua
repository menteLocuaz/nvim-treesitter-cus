local M = {}

---@param filename string
---@return string?
function M.read_file(filename)
  local ok, result = pcall(vim.fn.readfile, filename)
  if not ok then
    return nil
  end
  return table.concat(result, '\n')
end

local FILE_MODE = 438 -- 0o644 (rw-r--r--)

---@param filename string
---@param content string
---@return string? err
function M.write_file(filename, content)
  local fd, oerr = vim.uv.fs_open(filename, 'w', FILE_MODE)
  if not fd then
    return oerr or ('Could not open file for writing: ' .. filename)
  end
  local _, werr = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  return werr
end

-- CLOCK cache: O(1) amortized eviction, no array shifts.
-- Guarantee: evict() terminates in at most 2 * max iterations.
---@class ClockCache
---@field slots table
---@field index table
---@field hand integer
---@field max integer
---@field size integer
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

M.ClockCache = ClockCache

return M
