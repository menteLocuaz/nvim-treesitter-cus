local M = {}

local function info(msg)
  vim.health.info(msg)
end

local function error(msg)
  vim.health.error(msg)
end

local function section(title)
  vim.health.start(title)
end

function M.render_languages(languages, parsers, bundled_queries, query_status_fn)
  section('Installed languages' .. string.rep(' ', 5) .. 'H L F I J')

  for _, lang in ipairs(languages) do
    local parser = parsers[lang]
    local out = string.format('%-22s', lang)

    if parser and parser.install_info then
      for _, query_group in ipairs(bundled_queries) do
        local status = query_status_fn(lang, query_group)
        out = out .. status .. ' '
      end
    end

    info(out)
  end

  section('  Legend: [H]ighlights, [L]ocals, [F]olds, [I]ndents, In[J]ections')
end

function M.render_errors(errors)
  if #errors == 0 then
    return
  end

  section('The following errors have been detected in query files:')
  for _, e in ipairs(errors) do
    local lines = { string.format('%s(%s):', e.lang, e.query_group) }
    if e.files then
      for _, file in ipairs(e.files) do
        table.insert(lines, '  ' .. file)
      end
    end
    if e.err then
      table.insert(lines, '  ' .. e.err)
    end
    error(table.concat(lines, '\n  '))
  end
end

return M
