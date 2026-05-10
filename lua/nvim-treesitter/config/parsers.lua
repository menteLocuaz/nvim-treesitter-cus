local M = {}

local TIERS = { 'stable', 'unstable', 'unmaintained', 'unsupported' }

local ts_update_fired = false

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
  if not ts_update_fired then
    ts_update_fired = true
    vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
  end

  local parsers = require('nvim-treesitter.parsers')
  local languages = vim.tbl_keys(parsers)
  table.sort(languages)

  if tier then
    languages = vim.tbl_filter(
      --- @param p string
      function(p)
        return parsers[p] ~= nil and parsers[p].tier == tier
      end,
      languages
    )
  end
  return languages
end

return M
