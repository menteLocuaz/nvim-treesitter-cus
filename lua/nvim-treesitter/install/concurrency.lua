local uv = vim.uv

local LOCK_TIMEOUT_NS = 5 * 60 * 1e9

local M = {}

local ConcurrencyState = {}
ConcurrencyState.__index = ConcurrencyState

function ConcurrencyState.new()
  return setmetatable({ installing = {} }, ConcurrencyState)
end

local default = ConcurrencyState.new()

function M.new()
  return ConcurrencyState.new()
end

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

function M._reset()
  default = ConcurrencyState.new()
end

return M
