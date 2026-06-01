local meta = require('nvim-treesitter.parsers.meta')

---@type nvim-ts.parsers
local M = {}

for k, v in pairs(meta) do
  M[k] = v
end

local loaded = false

local function ensure_loaded()
  if not loaded then
    loaded = true
    local manifest = require('nvim-treesitter.parsers.manifest')
    for k, v in pairs(manifest) do
      rawset(M, k, v)
    end
  end
end

---@diagnostic disable-next-line: assign-type-mismatch
M._load_all = ensure_loaded

return setmetatable(M, {
  __index = function(_, key)
    if key ~= '_load_all' then
      ensure_loaded()
      return M[key]
    end
  end,
})
