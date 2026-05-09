local a = require('nvim-treesitter.async')

local M = {}
local installing = {} ---@type table<string,boolean?>

function M.is_installing(lang)
  return installing[lang] ~= nil
end

function M.lock(lang)
  installing[lang] = true
end

function M.unlock(lang)
  installing[lang] = nil
end

return M