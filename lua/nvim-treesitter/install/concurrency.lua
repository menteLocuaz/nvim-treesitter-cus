local uv = vim.uv

local a = require('nvim-treesitter.async')

local LOCK_TIMEOUT_NS = 5 * 60 * 1e9
local WAIT_POLL_MS = 100

local M = {}

local ConcurrencyState = {}
ConcurrencyState.__index = ConcurrencyState

function ConcurrencyState.new()
  return setmetatable({ installing = {} }, ConcurrencyState)
end

local default = ConcurrencyState.new()

function M.is_installing(lang)
  local ts = default.installing[lang]
  if not ts then
    return false
  end

  if uv.hrtime() - ts > LOCK_TIMEOUT_NS then
    default.installing[lang] = nil
    return false
  end

  return true
end

function M.lock(lang)
  default.installing[lang] = uv.hrtime()
end

function M.unlock(lang)
  default.installing[lang] = nil
end

--- Waits (asynchronously) until no install of `lang` is in progress.
--- Polls with a.sleep instead of vim.wait: vim.wait pumps the event loop
--- re-entrantly, breaking the Scheduler's no-reentrancy invariant, and must
--- never be called from inside an async Task.
--- Stale locks (from crashed/cancelled installs) are observed via the
--- LOCK_TIMEOUT_NS expiry in is_installing.
---@async
---@param lang string
---@param timeout_ms integer
---@return boolean released false if the lock was still held after timeout_ms
function M.wait_unlock(lang, timeout_ms)
  local deadline = uv.hrtime() + timeout_ms * 1e6
  while M.is_installing(lang) do
    if uv.hrtime() >= deadline then
      return false
    end
    a.sleep(WAIT_POLL_MS)
  end
  return true
end

function M._reset()
  default = ConcurrencyState.new()
end

return M
