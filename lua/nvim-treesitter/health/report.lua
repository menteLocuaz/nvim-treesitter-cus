local M = {}

M.bundled_queries = { 'highlights', 'locals', 'folds', 'indents', 'injections' }

function M.query_status(lang, query_group)
  local ok, err = pcall(vim.treesitter.query.get, lang, query_group)
  if not ok then
    return 'x', err
  elseif not err then
    return '.'
  else
    return '✓'
  end
end

function M.collect(languages, parsers)
  local errors = {}
  local config = require('nvim-treesitter.config')

  for _, lang in ipairs(languages) do
    local parser = parsers[lang]
    if parser and parser.requires then
      for _, p in ipairs(parser.requires) do
        if not vim.list_contains(languages, p) then
          table.insert(errors, { lang = lang, type = 'queries', err = 'dependency ' .. p .. ' missing' })
        end
      end
    end
  end

  return errors
end

function M.collect_query_errors(languages, parsers)
  local errors = {}
  local tsq = vim.treesitter.query
  local util = require('nvim-treesitter.util')

  for _, lang in ipairs(languages) do
    local parser = parsers[lang]
    if parser and parser.install_info then
      for _, query_group in ipairs(M.bundled_queries) do
        local status, err = M.query_status(lang, query_group)
        if err then
          table.insert(errors, { lang = lang, type = query_group, err = err })
        end
      end
    end
  end

  for _, e in ipairs(errors) do
    local files = tsq.get_files(e.lang, e.type)
    if #files > 0 then
      for _, file in ipairs(files) do
        local query = util.read_file(file)
        if query then
          local _, file_err = pcall(tsq.parse, e.lang, query)
          if file_err then
            e.files = e.files or {}
            table.insert(e.files, file)
          end
        end
      end
    end
  end

  return errors
end

return M