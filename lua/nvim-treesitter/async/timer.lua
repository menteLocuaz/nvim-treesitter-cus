-- nvim-treesitter.async.timer
-- Provides M.sleep: an async-safe, non-blocking delay primitive built on
-- libuv's one-shot timer (vim.uv). Integrates with the Future/Promise system
-- so the calling Task suspends cleanly and resumes after the delay without
-- blocking the Neovim event loop.

local Promise = require('nvim-treesitter.async.future').Promise

local M = {}

--- Low-level coroutine yield helper.
--- Suspends the current coroutine, passing `fun` (a continuation injector)
--- up to the Task scheduler. The scheduler calls fun(callback), and the
--- coroutine resumes when callback is eventually invoked.
---
--- @param fun function  A function that accepts a callback and initiates async work.
--- @return any          Values passed to the callback on resumption.
local function yield(fun)
  return coroutine.yield(fun)
end

--- Suspends the current async Task for at least `ms` milliseconds.
--- Uses a one-shot libuv timer so the Neovim event loop remains unblocked
--- during the wait. The Task resumes automatically once the timer fires.
---
--- Must be called from within an async context (M.async / M.arun).
--- Use via M.await in the public API:
---   M.await(M.sleep(500))
---
--- @async
--- @param ms integer  Duration in milliseconds. Must be a non-negative integer.
---                    0 is valid and defers execution to the next event loop tick.
---
--- Boundary cases:
---   - ms < 0 or non-number: raises immediately (assertion).
---   - Timer creation failure (UV handle limit): raises with a descriptive error.
---   - timer:start() failure (e.g., invalid state): timer is closed before raising.
---   - Cancellation: if the parent Task is closed while sleeping, the Future
---     will be abandoned; the timer will still fire and resolve the Promise,
---     but the Task will not resume (it is already closed).
---
--- Example:
---   local work = M.async(function()
---     print("before")
---     M.await(M.sleep(1000))  -- suspend for 1 second
---     print("after")
---   end)
---   work()
function M.sleep(ms)
  assert(type(ms) == 'number' and ms >= 0, 'sleep: ms must be a non-negative number')

  -- Create the Promise/Future pair. The timer callback resolves the Promise,
  -- which in turn triggers the Future's callbacks to resume the waiting Task.
  local promise = Promise.new()

  -- Allocate a new libuv timer handle. Returns nil if the handle limit is reached.
  local timer = vim.uv.new_timer()

  if not timer then
    error('sleep: failed to create timer (UV handle limit reached?)')
  end

  -- Start the timer as a one-shot (repeat = 0): fires once after `ms` ms.
  -- Wrapped in pcall to safely handle any libuv-level errors from timer:start().
  local ok, err = pcall(timer.start, timer, ms, 0, function()
    -- Timer callback: runs on the libuv thread after the delay.
    -- Stop and close the handle immediately to free the UV resource,
    -- then resolve the Promise to wake the suspended Task.
    timer:stop()
    timer:close()
    promise:resolve()
  end)

  if not ok then
    -- timer:start() failed — close the handle to avoid a resource leak,
    -- then propagate the error to the caller.
    timer:close()
    error('sleep: timer:start() failed: ' .. tostring(err))
  end

  -- Suspend the coroutine until the Promise resolves (i.e., the timer fires).
  -- The Task scheduler receives this function, calls it with a resume callback,
  -- and the coroutine wakes up once promise.future:on_resolved fires that callback.
  return yield(function(callback)
    promise.future:on_resolved(callback)
  end)
end

return M
