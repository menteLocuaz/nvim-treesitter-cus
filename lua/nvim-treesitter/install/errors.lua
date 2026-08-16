local M = {}

---@class InstallError
---@field stage string: which installation step failed (validate, download, generate, compile, install, queries)
---@field lang string: the language being installed
---@field message string: description of what went wrong
---@field cause? string: underlying error output
local InstallError = {}
InstallError.__index = InstallError

M.InstallError = InstallError

---Creates a structured installation error.
---@param stage string
---@param lang string
---@param message string
---@param cause? string
---@return InstallError
function M.new(stage, lang, message, cause)
  return setmetatable({
    stage = stage,
    lang = lang,
    message = message,
    cause = cause,
  }, InstallError)
end

---Formats the error for display.
---@return string
function InstallError:__tostring()
  local header = string.format("Failed to %s parser '%s'", self.stage, self.lang)
  if self.cause and self.cause ~= '' then
    return string.format('%s:\n  %s\n  Cause: %s', header, self.message, self.cause)
  end
  return string.format('%s:\n  %s', header, self.message)
end

---Creates an InstallError, logs it via the given logger, and returns it.
---This lets call-sites keep the `return logger.error(...)` pattern while
---producing structured, context-rich errors.
---@param logger Logger
---@param stage string
---@param lang string
---@param message string
---@param cause? string
---@return InstallError
function M.error(logger, stage, lang, message, cause)
  local err = M.new(stage, lang, message, cause)
  logger:error('%s', tostring(err))
  return err
end

return M
