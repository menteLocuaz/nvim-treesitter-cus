#!/usr/bin/env -S nvim -l
vim.o.rtp = vim.o.rtp .. ',.'

local query_types = require('nvim-treesitter.health').bundled_queries
local configs = require('nvim-treesitter.parsers')

local parsers = #_G.arg > 0 and { table.unpack(_G.arg) }
  or require('nvim-treesitter.config').get_installed('queries')

---@class QueryTiming
---@field duration integer
---@field lang string
---@field query_type string

---@type string[]
local errors = {}

---@type QueryTiming[]
local timings = {}

print('::group::Check parsers')

for _, lang in ipairs(parsers) do
  local config = configs[lang]

  if config and config.install_info then
    for _, query_type in ipairs(query_types) do
      local before = vim.uv.hrtime()

      local ok, result = pcall(vim.treesitter.query.get, lang, query_type)

      local duration = vim.uv.hrtime() - before

      if ok and result then
        timings[#timings + 1] = {
          duration = duration,
          lang = lang,
          query_type = query_type,
        }

        print(string.format('Checking %s %s (%.02fms)', lang, query_type, duration * 1e-6))
      end

      if not ok then
        errors[#errors + 1] = string.format('%s (%s): %s', lang, query_type, result)
      end
    end
  end
end

print('::endgroup::')

if #errors > 0 then
  print('::group::Errors')

  for _, err in ipairs(errors) do
    print(err)
  end

  print('::endgroup::')
  print('Check failed!\n')

  vim.cmd.cq()
  return
end

print('::group::Timings')

table.sort(timings, function(a, b)
  return a.duration > b.duration
end)

for i, val in ipairs(timings) do
  print(string.format('%i. %.02fms %s %s', i, val.duration * 1e-6, val.lang, val.query_type))
end

print('::endgroup::')
print('Check successful!')
