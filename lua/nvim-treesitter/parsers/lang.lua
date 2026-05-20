local ok, manifest = pcall(require, 'nvim-treesitter.parsers.manifest')

---@type nvim-ts.parsers
local M = {}

if ok then
  for lang, meta in pairs(manifest) do
    M[lang] = setmetatable({
      tier = meta.tier,
      maintainers = meta.maintainers,
      requires = meta.requires,
    }, {
      __index = function(t, k)
        local res = require('nvim-treesitter.parsers.list.' .. lang:gsub('/', '_'))
        for key, val in pairs(res) do
          rawset(t, key, val)
        end
        return res[k]
      end,
    })
  end
else
  local script_path = debug.getinfo(1, 'S').source:sub(2)
  local script_dir = vim.fn.fnamemodify(script_path, ':p:h')
  local list_dir = vim.fs.joinpath(script_dir, 'list')

  for name, type in vim.fs.dir(list_dir) do
    if type == 'file' and name:match('%.lua$') then
      local lang = name:sub(1, -5)
      M[lang] = setmetatable({}, {
        __index = function(t, k)
          local res = require('nvim-treesitter.parsers.list.' .. lang:gsub('/', '_'))
          for key, val in pairs(res) do
            rawset(t, key, val)
          end
          return res[k]
        end,
      })
    end
  end
end

return M
