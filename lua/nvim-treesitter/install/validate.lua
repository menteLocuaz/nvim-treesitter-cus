local M = {}

---@class ToolCheck
---@field name string
---@field min_version? table

---Validates that a command is available in PATH.
---@param name string
---@return string? err human-readable error if the tool is missing
function M.check_executable(name)
  if vim.fn.executable(name) ~= 1 then
    return name .. ' not found in PATH'
  end
  return nil
end

---Validates that all tools in the list are available in PATH.
---Returns the first error encountered, or nil on success.
---@param tools string[]
---@return string? err
function M.check_tools(tools)
  for _, tool in ipairs(tools) do
    local err = M.check_executable(tool)
    if err then
      return err
    end
  end
  return nil
end

---Determines which external tools are required for a given install configuration.
---tree-sitter is always needed (for compilation); curl and tar are only needed
---when downloading from a remote URL.
---@param repo InstallInfo?
---@return string[] tools list of tool names that must be in PATH
function M.required_tools(repo)
  local tools = { 'tree-sitter' }
  if not repo or not repo.path then
    tools[#tools + 1] = 'curl'
    tools[#tools + 1] = 'tar'
  end
  return tools
end

return M
