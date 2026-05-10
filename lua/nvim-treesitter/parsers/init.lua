local meta = require('nvim-treesitter.parsers.meta')
local langs = require('nvim-treesitter.parsers.lang')

---@type nvim-ts.parsers
local M = {}

for k, v in pairs(meta) do
  M[k] = v
end

for k, v in pairs(langs) do
  M[k] = v
end

return M