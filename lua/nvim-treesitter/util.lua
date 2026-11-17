local M = {}

--- @param filename string
--- @return string
function M.read_file(filename)
  local file, open_err = io.open(filename, 'r')
  if not file then
    -- We retain the abort behavior, but with a clear message.
    error(string.format("The file could not be opened '%s': %s", filename, open_err))
  end

  local content, read_err = file:read('*a')
  file:close() -- We guarantee closure IMMEDIATELY after the operation.

  if not content then
    error(string.format("Error reading the file '%s': %s", filename, read_err))
  end

  return content
end

--- @param filename string
--- @param content string
function M.write_file(filename, content)
  local file, open_err = io.open(filename, 'w')
  if not file then
    error(string.format("The file could not be opened '%s' for writing: %s", filename, open_err))
  end

  local success, write_err = file:write(content)
  file:close() -- We guarantee the closing even if the writing process fails.

  if not success then
    error(string.format("Error writing to the file '%s': %s", filename, write_err))
  end
end

return M