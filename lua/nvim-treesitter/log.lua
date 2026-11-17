local M = {}

-- TODO(lewis6991): Write these messages to a file.
local messages = {} --- @type {[1]: string, [2]: string?, [3]: string}[]

local sev_to_hl = {
  trace = 'DiagnosticHint',
  debug = 'Normal',
  info = 'MoreMsg',
  warn = 'WarningMsg',
  error = 'ErrorMsg',
}

---@param ctx string?
---@return string
local function mkpfx(ctx)
  return ctx and string.format('[nvim-treesitter/%s]', ctx) or '[nvim-treesitter]'
end

---@class Logger
---@field ctx? string
local Logger = {}
Logger.__index = Logger

M.Logger = Logger

---@param ctx? string
---@return Logger
function M.new(ctx)
  return setmetatable({ ctx = ctx }, Logger)
end

-- =====================================================================
-- Internal Helpers: Standardization and Code Reuse
-- =====================================================================

---@param self Logger
---@param sev string
---@param m string
---@param ... any
---@return string formatted_msg
local function process_log(self, sev, m, ...)
  local formatted = m:format(...)
  messages[#messages + 1] = { sev, self.ctx, formatted }
  return formatted
end

---@param ctx string?
---@param sev string
---@param msg string
---@param label string?
local function echo_log(ctx, sev, msg, label)
  local hl = sev_to_hl[sev]
  local prefix = mkpfx(ctx)

  local text = label and string.format('%s %s: %s', prefix, label, msg)
                      or string.format('%s: %s', prefix, msg)

  -- Call vim.api directly instead of using a local alias
  -- to allow dependency injection and mocking in tests.
  vim.api.nvim_echo({ { text, hl } }, true, {})
end

-- =====================================================================
-- Logger Instance Methods
-- =====================================================================

function Logger:trace(m, ...)
  process_log(self, 'trace', m, ...)
end

function Logger:debug(m, ...)
  process_log(self, 'debug', m, ...)
end

function Logger:info(m, ...)
  local msg = process_log(self, 'info', m, ...)
  echo_log(self.ctx, 'info', msg)
end

function Logger:warn(m, ...)
  local msg = process_log(self, 'warn', m, ...)
  echo_log(self.ctx, 'warn', msg, 'warning')
end

function Logger:error(m, ...)
  local msg = process_log(self, 'error', m, ...)
  echo_log(self.ctx, 'error', msg, 'error')
  return msg
end

-- =====================================================================
-- Global Interface (Context-Free Fallback)
-- =====================================================================
local noctx_logger = M.new()

-- Define methods explicitly instead of using magic metatables
-- to provide autocompletion and static analysis through the LSP.
function M.trace(...) return noctx_logger:trace(...) end
function M.debug(...) return noctx_logger:debug(...) end
function M.info(...)  return noctx_logger:info(...) end
function M.warn(...)  return noctx_logger:warn(...) end
function M.error(...) return noctx_logger:error(...) end

function M.show()
  for _, l in ipairs(messages) do
    local sev, ctx, msg = l[1], l[2], l[3]
    local hl = sev_to_hl[sev]

    local text = ctx and string.format('%s(%s): %s', sev, ctx, msg)
                      or string.format('%s: %s', sev, msg)

    vim.api.nvim_echo({ { text, hl } }, false, {})
  end
end

return M
