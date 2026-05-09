local constants = require('nvim-treesitter.health.constants')

local M = {}

---@param lang string
---@param query_group string
---@return string status, string|nil err
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

  for _, lang in ipairs(languages) do
    local parser = parsers[lang]
    if parser and parser.requires then
      for _, p in ipairs(parser.requires) do
        if not vim.list_contains(languages, p) then
          table.insert(
            errors,
            { lang = lang, query_group = 'queries', err = 'dependency ' .. p .. ' missing' }
          )
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
      for _, query_group in ipairs(constants.BUNDLED_QUERIES) do
        local _status, err = M.query_status(lang, query_group)
        if err then
          table.insert(errors, { lang = lang, query_group = query_group, err = err })
        end
      end
    end
  end

  for _, e in ipairs(errors) do
    local files = tsq.get_files(e.lang, e.query_group)
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
