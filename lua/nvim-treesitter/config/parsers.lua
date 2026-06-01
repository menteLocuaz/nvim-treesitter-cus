local M = {}

local constants = require('nvim-treesitter.constants')
local TIERS = constants.TIERS

local function expand_tiers(list)
  for i, tier in ipairs(TIERS) do
    if vim.list_contains(list, tier) then
      list = vim.tbl_filter(
        --- @param l string
        function(l)
          return l ~= tier
        end,
        list
      )
      vim.list_extend(list, M.get_available(i))
    end
  end
  return list
end

M.expand_tiers = expand_tiers

---Get a list of all available parsers
---@param tier integer? only get parsers of specified tier
---@return string[]
function M.get_available(tier)
  local parsers = require('nvim-treesitter.parsers')
  ---@diagnostic disable-next-line: undefined-field
  parsers._load_all()
  local languages = {}
  for k in pairs(parsers) do
    if type(k) == 'string' and k:sub(1, 1) ~= '_' then
      languages[#languages + 1] = k
    end
  end
  table.sort(languages)

  if tier then
    languages = vim.tbl_filter(
      --- @param p string
      function(p)
        local info = parsers[p]
        return info and info.tier == tier
      end,
      languages
    )
  end
  return languages
end

return M
