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

---@class TSLogModule
---@field trace fun(fmt: string, ...: any)
---@field debug fun(fmt: string, ...: any)
---@field info fun(fmt: string, ...: any)
---@field warn fun(fmt: string, ...: any)
---@field error fun(fmt: string, ...: any)
local M = {}

---@class Logger
---@field ctx? string
---@field messages {[1]: string, [2]: string?, [3]: string}[]
local Logger = {}

M.Logger = Logger

local MAX_HISTORY = 1000

---Global capped history with the messages of ALL loggers (including
---per-language ones), so M.show() can display e.g. install output.
---@type {[1]: string, [2]: string?, [3]: string}[]
local history = {}

---@param sev string
---@param ctx? string
---@param msg string
local function record(sev, ctx, msg)
  history[#history + 1] = { sev, ctx, msg }
  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
end

---@param ctx? string
---@return Logger
function M.new(ctx)
  return setmetatable({ ctx = ctx, messages = {} }, { __index = Logger })
end

---@param m string
---@param ... any
function Logger:trace(m, ...)
  local m1 = m:format(...)
  self.messages[#self.messages + 1] = { 'trace', self.ctx, m1 }
  record('trace', self.ctx, m1)
end

---@param m string
---@param ... any
function Logger:debug(m, ...)
  local m1 = m:format(...)
  self.messages[#self.messages + 1] = { 'debug', self.ctx, m1 }
  record('debug', self.ctx, m1)
end

---@param m string
---@param ... any
function Logger:info(m, ...)
  local m1 = m:format(...)
  self.messages[#self.messages + 1] = { 'info', self.ctx, m1 }
  record('info', self.ctx, m1)
  vim.api.nvim_echo({ { mkpfx(self.ctx) .. ': ' .. m1, sev_to_hl.info } }, true, {})
end

---@param m string
---@param ... any
function Logger:warn(m, ...)
  local m1 = m:format(...)
  self.messages[#self.messages + 1] = { 'warn', self.ctx, m1 }
  record('warn', self.ctx, m1)
  vim.api.nvim_echo({ { mkpfx(self.ctx) .. ' warning: ' .. m1, sev_to_hl.warn } }, true, {})
end

---@param m string
---@param ... any
---@return string
function Logger:error(m, ...)
  local m1 = m:format(...)
  self.messages[#self.messages + 1] = { 'error', self.ctx, m1 }
  record('error', self.ctx, m1)
  vim.api.nvim_echo({ { mkpfx(self.ctx) .. ' error: ' .. m1, sev_to_hl.error } }, true, {})
  return m1
end

local default_logger = M.new()

setmetatable(M, {
  __index = function(t, k)
    --- @diagnostic disable-next-line:no-unknown
    t[k] = function(...)
      return default_logger[k](default_logger, ...)
    end
    return t[k]
  end,
})

---Show accumulated log messages.
---@param logger? Logger if nil, shows the global history of all loggers
function M.show(logger)
  local messages = logger and logger.messages or history
  for _, l in ipairs(messages) do
    local sev, ctx, msg = l[1], l[2], l[3]
    local hl = sev_to_hl[sev]
    local text = ctx and string.format('%s(%s): %s', sev, ctx, msg)
      or string.format('%s: %s', sev, msg)
    vim.api.nvim_echo({ { text, hl } }, false, {})
  end
end

---Resets the global history and the default logger's message buffer.
---Does NOT affect instances created via log.new().
function M._reset()
  history = {}
  default_logger.messages = {}
end

return M
