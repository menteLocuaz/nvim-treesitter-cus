local parsers = require('nvim-treesitter.parsers')
local config = require('nvim-treesitter.config')

local checks = require('nvim-treesitter.health.checks')
local report = require('nvim-treesitter.health.report')
local render = require('nvim-treesitter.health.render')

local M = {}

function M.check()
  checks.install_health()
  checks.check_install_dir()

  local languages = config.get_installed()
  table.sort(languages)

  render.render_languages(languages, parsers, report.bundled_queries)

  local errors = report.collect(languages, parsers)
  local query_errors = report.collect_query_errors(languages, parsers)

  for _, e in ipairs(query_errors) do
    table.insert(errors, e)
  end

  render.render_errors(errors)
end

M.bundled_queries = report.bundled_queries

return M