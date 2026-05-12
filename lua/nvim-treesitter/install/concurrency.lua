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
  return default.installing[lang] ~= nil
end

function M.lock(lang)
  default.installing[lang] = true
end

function M.unlock(lang)
  default.installing[lang] = nil
end

function M._reset()
  default = ConcurrencyState.new()
end

return M
