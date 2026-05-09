local M = {}

---@class HealthDiagnostic
---@field lang string
---@field query_group string
---@field err string
---@field files? string[]

M.Severity = {
  ERROR = 'error',
  WARN = 'warn',
  INFO = 'info',
}

return M
