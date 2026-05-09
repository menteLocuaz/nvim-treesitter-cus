local M = {}

function M.render_languages(languages, parsers, bundled_queries)
  local health = vim.health
  local report = require('nvim-treesitter.health.report')

  health.start('Installed languages' .. string.rep(' ', 5) .. 'H L F I J')

  for _, lang in ipairs(languages) do
    local parser = parsers[lang]
    local out = string.format('%-22s', lang)

    if parser and parser.install_info then
      for _, query_group in ipairs(bundled_queries) do
        local status = report.query_status(lang, query_group)
        out = out .. status .. ' '
      end
    end

    health.info(vim.fn.trim(out, ' ', 2))
  end

  health.start('  Legend: [H]ighlights, [L]ocals, [F]olds, [I]ndents, In[J]ections')
end

function M.render_errors(errors)
  local health = vim.health

  if #errors == 0 then
    return
  end

  health.start('The following errors have been detected in query files:')
  for _, e in ipairs(errors) do
    local lines = { e.lang .. '(' .. e.type .. '): ' }
    if e.files then
      for _, file in ipairs(e.files) do
        table.insert(lines, '\n  ' .. file)
      end
    end
    if e.err then
      table.insert(lines, '\n  ' .. e.err)
    end
    health.error(table.concat(lines, ''))
  end
end

return M