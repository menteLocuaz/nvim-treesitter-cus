-- nvim-treesitter.async.task
-- Implements the async Task primitive: a managed coroutine that integrates with
-- the Scheduler, Future/Promise system, and CancellationToken. Tasks are the
-- core unit of async execution — every M.async / M.arun call produces one.

-- Prefer coroutine-aware pcall if available (e.g., coxpcall), falling back to
-- standard pcall. Needed to correctly catch errors thrown inside coroutines.
local pcall = copcall or pcall

local Scheduler = require('nvim-treesitter.async.scheduler')
local future_mod = require('nvim-treesitter.async.future')
local Future = future_mod.Future
local Promise = future_mod.Promise
local CancellationToken = require('nvim-treesitter.async.cancellation')
local pack_len = future_mod.pack_len
local unpack_len = future_mod.unpack_len

--- Resolves a Future with either an error or a set of return values.
--- Idempotent: if the Future is already resolved, this is a no-op.
---
--- @param future async.Future  The Future to resolve.
--- @param err    any|nil       Error value, or nil on success.
--- @param ...    any           Return values (only used when err is nil).
local function resolve_future(future, err, ...)
  if err then
    future:_complete(err, nil)
  else
    future:_complete(nil, pack_len(...))
  end
end

-- Weak-keyed map from coroutine thread -> Task.
-- Weak keys ensure that finished threads (and their Tasks) can be GC'd
-- without needing explicit cleanup of this table in the common case.
local threads = setmetatable({}, { __mode = 'k' })

--- Returns the Task associated with the currently running coroutine, or nil
--- if called from outside any async Task (e.g., from the main thread).
---
--- @return async.Task?
local function running()
  return threads[coroutine.running()]
end

--- @class async.Handle
--- A generic interface for closeable async resources (Tasks, timers, etc.).
--- @field close      fun(self: async.Handle, callback?: fun())  Cancels/closes the resource.
--- @field is_closing? fun(self: async.Handle): boolean          Returns true if close() was called.

--- @alias async.CallbackFn fun(...: any): async.Handle?
--- A callback-style async function. May return an async.Handle representing
--- the in-progress operation (used by Task._resume to track the current child).

--- @class async.Task : async.Handle
--- Represents a running async coroutine. Wraps a Lua coroutine with a Future
--- for completion tracking, a CancellationToken for cooperative cancellation,
--- and a reference to the current child handle being awaited.
--- @field private _thread             thread                    The underlying Lua coroutine.
--- @field private _future             async.Future              Resolved when the task completes or errors.
--- @field private _cancellation_token async.CancellationToken   Used to signal cancellation to the task body.
--- @field private _current_child?     async.Handle              The async handle currently being awaited, if any.
--- @field private _closing            boolean                   True once close() has been called.
local Task = {}
Task.__index = Task

--- Creates a new Task wrapping the given function, but does NOT start it.
--- The caller must call task:_resume(...) to begin execution.
---
--- @param func function  The async function to run as a coroutine.
--- @return async.Task
---
--- Boundary: `func` should not be called directly — it will be run as a
--- coroutine and may yield. Errors inside it are caught and stored in _future.
function Task._new(func)
  local thread = coroutine.create(func)
  local self = setmetatable({
    _thread = thread,
    _future = Future.new(),
    _cancellation_token = CancellationToken.new(),
    _current_child = nil,
    _closing = false,
  }, Task)

  -- Register the thread so running() can look up the Task from inside the coroutine.
  threads[thread] = self
  return self
end

--- Registers a callback to be called when this Task completes (or errors).
--- The callback receives (err, ...) — err is nil on success.
--- Safe to call before or after the Task has completed.
---
--- @param callback fun(err: any, ...: any)
function Task:await(callback)
  self._future:on_resolved(callback)
end

--- Returns true if the Task has finished (successfully or with an error).
--- @return boolean
function Task:_completed()
  return self._future:is_resolved()
end

-- Maximum value for vim.wait timeout (2^31 - 1 ms ≈ 24.8 days).
-- Used as the default "wait forever" sentinel.
local MAX_TIMEOUT = 2 ^ 31 - 1

--- Blocks the current (non-async) thread until the Task completes or times out.
--- Returns a (success, ...) tuple rather than raising on error.
--- Intended for use at the sync/async boundary (e.g., in tests or top-level calls).
---
--- @param timeout? integer  Milliseconds to wait. Defaults to MAX_TIMEOUT (effectively forever).
--- @return boolean, ...     `true, results...` on success; `false, err` on error or timeout.
---
--- Example:
---   local ok, result = task:pwait(5000)
---   if not ok then print("failed:", result) end
---
--- Boundary: Must NOT be called from inside an async Task — use M.await instead.
--- Calling from a coroutine will deadlock since vim.wait blocks the event loop.
function Task:pwait(timeout)
  local done = vim.wait(timeout or MAX_TIMEOUT, function()
    return self:_completed()
  end)

  if not done then
    return false, 'timeout'
  elseif self._future._err then
    return false, self._future._err
  else
    return true, unpack_len(self._future._args)
  end
end

--- Like pwait, but raises an error (with full traceback) instead of returning it.
--- Use when you want blocking behavior and expect success.
---
--- @param timeout? integer  Milliseconds to wait. Defaults to MAX_TIMEOUT.
--- @return ...              Return values of the Task on success.
---
--- Example:
---   local result = task:wait()  -- raises if the task errored
---
--- Boundary: Same as pwait — do not call from inside an async Task.
function Task:wait(timeout)
  local res = pack_len(self:pwait(timeout))
  if not res[1] then
    error(self:traceback(res[2]))
  end
  return unpack_len(res, 2)
end

--- Internal recursive helper that builds a combined traceback across a chain
--- of nested Tasks (parent -> child -> grandchild...).
--- Deduplicates the "stack traceback:" header so the output reads as a single
--- unified trace rather than multiple concatenated ones.
---
--- @param msg  string|nil  Accumulated error message so far.
--- @param _lvl integer     Recursion depth (0 = outermost/root Task).
--- @return string          The combined traceback string.
function Task:_traceback(msg, _lvl)
  _lvl = _lvl or 0
  local thread_id = ('[%s] '):format(self._thread)

  -- Recurse into the current child Task first so the innermost frame appears
  -- at the top of the traceback (closest to the error site).
  local child = self._current_child
  if getmetatable(child) == Task then
    msg = child:_traceback(msg, _lvl + 1)
  end

  -- Skip one extra traceback level when the child is a Task, since the child's
  -- own traceback already covers the yield point.
  local tblvl = getmetatable(child) == Task and 2 or nil
  msg = (msg or '') .. debug.traceback(self._thread, '', tblvl):gsub('\n\t', '\n\t' .. thread_id)

  -- At the root level, collapse duplicate "stack traceback:" headers that
  -- result from concatenating multiple debug.traceback() outputs.
  if _lvl == 0 then
    msg = msg
      :gsub('\nstack traceback:\n', '\nSTACK TRACEBACK:\n', 1) -- Protect the first occurrence.
      :gsub('\nstack traceback:\n', '\n') -- Remove subsequent duplicates.
      :gsub('\nSTACK TRACEBACK:\n', '\nstack traceback:\n', 1) -- Restore the first as canonical.
  end
  return msg
end

--- Returns a formatted traceback string for this Task, including any nested
--- child Task tracebacks. Suitable for passing to error() or vim.notify.
---
--- @param msg? string  Optional error message to prepend.
--- @return string
function Task:traceback(msg)
  return self:_traceback(msg)
end

--- Registers a callback that raises the Task's error (with traceback) if it
--- fails. Useful for "fire and forget" tasks where you still want errors surfaced.
--- Returns self for chaining.
---
--- @return async.Task  self
---
--- Example:
---   M.arun(risky_fn):raise_on_error()
function Task:raise_on_error()
  self:await(function(err)
    if err then
      error(self:_traceback(err), 0)
    end
  end)
  return self
end

--- Returns true if close() has been called on this Task.
--- @return boolean
function Task:is_closing()
  return self._closing
end

--- Cancels the Task cooperatively and cleans up resources.
--- If the Task is already completed, calls `callback` immediately (if provided).
--- If close() was already called, this is a no-op (idempotent).
---
--- Cancellation is cooperative: the Task's CancellationToken is signalled, and
--- any current child handle is also closed. The Task's Future is resolved with
--- the error string `'closed'` once teardown is complete.
---
--- @param callback? fun()  Called when the Task (and its child) has fully closed.
---                         If nil, blocks synchronously via vim.wait(0) until done.
---
--- Example (async close with callback):
---   task:close(function() print("task closed") end)
---
--- Example (synchronous close, no callback):
---   task:close()  -- blocks until closed
---
--- Boundary: Calling close() does not guarantee the coroutine body has exited —
--- it signals cancellation and resolves the Future, but the coroutine may still
--- be suspended. The thread entry is removed from `threads` on resolution.
function Task:close(callback)
  if self:_completed() then
    if callback then
      callback()
    end
    return
  end

  if self._closing then
    return -- Already closing; ignore duplicate calls.
  end

  self._closing = true
  self._cancellation_token:cancel()

  local function finish()
    resolve_future(self._future, 'closed')
    threads[self._thread] = nil -- Allow the thread to be GC'd.
    if callback then
      callback()
    end
  end

  if self._current_child then
    -- Propagate cancellation to the child handle first; finish after it closes.
    self._current_child:close(finish)
  else
    finish()
  end

  -- If no callback was provided, spin the event loop until the Task is done.
  -- This provides a synchronous close at the cost of blocking the caller briefly.
  if not callback then
    vim.wait(0, function()
      return self:_completed()
    end)
  end
end

--- Returns true if `obj` is a closeable async handle (Task, timer, uv handle, etc.).
--- Checks for a callable `.close` field rather than a specific metatable, so it
--- works with any handle type (libuv userdata, custom tables, etc.).
---
--- @param obj any  Value to test.
--- @return boolean
local function is_async_handle(obj)
  local ty = type(obj)
  return (ty == 'table' or ty == 'userdata') and vim.is_callable(obj.close)
end

--- Schedules the next resumption of this Task's coroutine with the given arguments.
--- This is the core driver of the async state machine:
---
---   1. Resumes the coroutine.
---   2. If it errors → resolves the Future with the error.
---   3. If it returns (dead) → resolves the Future with the return values.
---   4. If it yields a function `fn` → calls fn(callback), where callback will
---      call _resume again when the async operation completes.
---      If `fn` returns an async handle `r`, it is stored as _current_child so
---      that close() can propagate cancellation to it.
---
--- All work is enqueued on the Scheduler to avoid re-entrancy and stack growth.
---
--- @param ... any  Arguments to pass into the coroutine on this resumption.
---
--- Boundary: Must only be called by the scheduler or by async infrastructure.
--- Calling _resume from user code or from inside the coroutine itself is unsafe.
function Task:_resume(...)
  local args = pack_len(...)
  Scheduler.enqueue(function()
    -- Guard: don't resume a completed or cancelled Task.
    if self:_completed() or self._closing then
      return
    end

    local ret = pack_len(coroutine.resume(self._thread, unpack_len(args)))
    local stat = ret[1] -- false if the coroutine threw an unhandled error.

    if not stat then
      -- Coroutine raised an error — capture it and resolve the Future as failed.
      resolve_future(self._future, ret[2])
      threads[self._thread] = nil
    elseif coroutine.status(self._thread) == 'dead' then
      -- Coroutine returned normally — resolve the Future with its return values.
      local result = pack_len(unpack_len(ret, 2))
      resolve_future(self._future, nil, unpack_len(result))
      threads[self._thread] = nil
    else
      -- Coroutine yielded a function `fn` (the continuation injector).
      -- Call fn with a callback that will resume this Task when the operation completes.
      local fn = ret[2]
      local ok, r = pcall(fn, function(...)
        if is_async_handle(r) then
          -- The operation returned a handle that is now closing (e.g., cancelled).
          -- Wait for it to close before resuming, forwarding the original results.
          local args = pack_len(...)
          r:close(function()
            self:_resume(unpack_len(args))
          end)
        else
          -- Normal completion — resume the Task with the callback's arguments.
          self:_resume(...)
        end
      end)

      if not ok then
        -- fn itself threw synchronously (e.g., bad argument to a libuv call).
        resolve_future(self._future, r)
        threads[self._thread] = nil
      elseif is_async_handle(r) then
        -- Track the returned handle as the current child so close() can cancel it.
        self._current_child = r
      end
    end
  end)
end

--- Returns the status of the underlying coroutine.
--- Possible values: "running", "suspended", "normal", "dead".
---
--- @return string
function Task:status()
  return coroutine.status(self._thread)
end

return {
  Task = Task,
  running = running,
  is_async_handle = is_async_handle,
}
