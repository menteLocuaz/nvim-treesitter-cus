local uv = vim.uv

local a = require('nvim-treesitter.async')
local log = require('nvim-treesitter.log')

local M = {}
local MAX_JOBS = 100

--- Wrapper for vim.system that catches spawn errors and returns a proper SystemCompleted.
--- Without this, uv.spawn failures kill the coroutine and cause hangs.
--- TODO(clason): remove when https://github.com/neovim/neovim/issues/38257 is resolved.
---@param cmd string[]
---@param opts vim.SystemOpts
---@param on_exit fun(result: vim.SystemCompleted)
---@return vim.SystemObj?
local function system_wrap(cmd, opts, on_exit)
  local ok, ret = pcall(vim.system, cmd, opts, on_exit)
  if not ok then
    on_exit({
      code = 125,
      signal = 0,
      stdout = '',
      stderr = ret --[[@as string]],
    })
    return nil
  end
  return ret --[[@as vim.SystemObj]]
end

---@async
---@param cmd string[]
---@param opts? vim.SystemOpts
---@param logger Logger
---@return vim.SystemCompleted
function M.system(cmd, opts, logger)
  local cwd = opts and opts.cwd or uv.cwd()
  logger:trace('running job: (cwd=%s) %s', cwd, table.concat(cmd, ' '))

  local r = a.await(3, system_wrap, cmd, opts) --[[@as vim.SystemCompleted]]
  a.schedule()
  if r.stdout and r.stdout ~= '' then
    logger:trace('stdout -> %s', r.stdout)
  end
  if r.stderr and r.stderr ~= '' then
    logger:trace('stderr -> %s', r.stderr)
  end

  return r
end

--- Manages parallel execution of async tasks with a job limit.
--- Runs up to max_jobs tasks concurrently, queuing remaining tasks.
---@async
---@param max_jobs integer
---@param tasks async.TaskFun[]
function M.join(max_jobs, tasks)
  local count = #tasks
  if count == 0 then
    return
  end

  max_jobs = math.min(max_jobs, count)
  local remaining_idx = max_jobs + 1
  local to_go = count

  a.await(1, function(finish)
    local function cb()
      to_go = to_go - 1
      if to_go == 0 then
        finish()
      elseif remaining_idx <= count then
        local next_task = tasks[remaining_idx]
        remaining_idx = remaining_idx + 1
        next_task():await(cb)
      end
    end

    for i = 1, max_jobs do
      tasks[i]():await(cb)
    end
  end)
end

M.MAX_JOBS = MAX_JOBS

return M