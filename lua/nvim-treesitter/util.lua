local M = {}

---@param filename string
---@return string
function M.read_file(filename)
  local file = assert(io.open(filename, 'rb'))

  local ok, result = pcall(file.read, file, '*a')
  file:close()

  if not ok then
    error(result)
  end

  ---@cast result string
  return result
end

---@param filename string
---@param content string
function M.write_file(filename, content)
  local file = assert(io.open(filename, 'wb'))

  local ok, err = pcall(file.write, file, content)
  file:close()

  if not ok then
    error(err)
  end
end

return M
