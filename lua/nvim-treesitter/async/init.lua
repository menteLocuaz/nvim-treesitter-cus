---@meta nvim-treesitter.async
-- nvim-treesitter.async
-- Provides structured async/await primitives for Neovim plugin development,
-- built on top of Lua coroutines. Supports Tasks, Futures, Promises,
-- Semaphores, Channels, and callback-based async interop.

local Scheduler = require('nvim-treesitter.async.scheduler')
local Future = require('nvim-treesitter.async.future').Future
local Promise = require('nvim-treesitter.async.future').Promise
local Task = require('nvim-treesitter.async.task').Task
local CancellationToken = require('nvim-treesitter.async.cancellation')
local Semaphore = require('nvim-treesitter.async.semaphore')
local Channel = require('nvim-treesitter.async.channel')
local timer_mod = require('nvim-treesitter.async.timer')
local future_mod = require('nvim-treesitter.async.future')

-- Helpers for packing/unpacking variadic return values while preserving length.
-- Required because Lua's `select('#', ...)` can't track trailing nils.
local pack_len = future_mod.pack_len
local unpack_len = future_mod.unpack_len

-- Returns the currently running Task, or nil if called outside async context.
local running = require('nvim-treesitter.async.task').running

-- Returns true if the given value is an async handle (Task or similar).
local is_async_handle = require('nvim-treesitter.async.task').is_async_handle

--- @class async
--- The main public module. Exposes all async primitives and control-flow utilities.
local M = {}

-- Re-export concurrency primitives for consumer use.
M.Semaphore = Semaphore -- Limits concurrent access to a resource (counting semaphore).
M.Channel = Channel -- Buffered/unbuffered async message passing between tasks.

--------------------------------------------------------------------------------
-- Timer: Async sleep and timeouts
--------------------------------------------------------------------------------

--- Suspends the current async task for the given number of milliseconds.
--- Must be called from within an async context (inside M.async or M.arun).
---
--- @param ms number  Duration to sleep in milliseconds.
---
--- Example:
---   local fetch = M.async(function()
---     print("waiting...")
---     M.await(M.sleep(500))  -- suspend for 500ms
---     print("done")
---   end)
---   fetch()
function M.sleep(ms)
  return timer_mod.sleep(ms)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Creates and immediately starts a new async Task from a plain function.
--- Unlike M.async, this does NOT wrap the function — it runs it right away.
---
--- @param func function  The async function to run as a task.
--- @param ...  any       Arguments forwarded to `func`.
--- @return Task          The running Task handle.
---
--- Example:
---   local task = M.arun(function(x)
---     M.await(M.sleep(100))
---     print("got:", x)
---   end, 42)
---
--- Boundary: `func` must be a plain function, not a TaskFun. Use M.async for
--- wrapping. Errors inside `func` are captured by the Task and re-raised on await.
function M.arun(func, ...)
  local task = Task._new(func)
  task:_resume(...)
  return task
end

-- Metatable for TaskFun objects — functions wrapped with M.async().
-- Calling a TaskFun directly spawns a new Task via M.arun.
local TaskFun = {}
TaskFun.__index = TaskFun

--- Calling a TaskFun spawns and starts a new Task with the given arguments.
--- @param ... any  Arguments forwarded to the wrapped function.
--- @return Task
function TaskFun:__call(...)
  return M.arun(self._fun, ...)
end

--- Wraps a function as an async TaskFun.
--- The returned value can be called like a function to spawn a Task,
--- or passed to M.await to run inline within another async context.
---
--- @param fun function  The coroutine-based async function to wrap.
--- @return TaskFun      A callable wrapper that spawns Tasks on invocation.
---
--- Example:
---   local greet = M.async(function(name)
---     M.await(M.sleep(100))
---     print("Hello,", name)
---   end)
---   greet("world")  -- spawns a Task immediately
---
---   -- Or await it inline:
---   local pipeline = M.async(function()
---     M.await(greet, "inline")
---   end)
---   pipeline()
function M.async(fun)
  return setmetatable({ _fun = fun }, TaskFun)
end

--- Returns the status of a Task.
--- If no task is provided, returns the status of the currently running Task.
---
--- @param task? Task  The Task to query. Defaults to the running task.
--- @return string|nil  Task status string, or nil if not in async context.
---
--- Boundary: Asserts that the argument (if given) is actually a Task.
--- Returns nil if called outside an async context with no argument.
function M.status(task)
  task = task or running()
  if task then
    assert(getmetatable(task) == Task, 'Expected Task')
    return task:status()
  end
end

--- Yields the current coroutine, passing a continuation callback to `fun`.
--- `fun` receives a `callback` and must call it when the async operation completes.
--- This is the low-level suspension primitive used by all await variants.
---
--- @param fun function  A function that accepts a callback and initiates async work.
--- @return any          Values passed to the callback when it is called.
---
--- Boundary: `fun` must be a function. Errors if called outside a coroutine.
local function yield(fun)
  assert(type(fun) == 'function', 'Expected function')
  return coroutine.yield(fun)
end

--- Awaits a Task, suspending until it completes.
--- Re-raises any error the Task produced.
---
--- @param task Task  The Task to await.
--- @return any       Return values of the Task's function.
local function await_task(task)
  local res = pack_len(yield(function(callback)
    task:await(callback)
  end))

  -- res[1] is the error (if any); values start at index 2.
  if res[1] then
    error(res[1], 0)
  end
  return unpack_len(res, 2)
end

--- Awaits a Future, suspending until it resolves.
--- Re-raises any error the Future was rejected with.
---
--- @param future Future  The Future to await.
--- @return any           Resolved values of the Future.
local function await_future(future)
  local res = pack_len(yield(function(callback)
    future:on_resolved(callback)
  end))
  -- res[1] is the error (if any); values start at index 2.
  if res[1] then
    error(res[1], 0)
  end
  return unpack_len(res, 2)
end

--- Awaits a callback-style async function by injecting a continuation at position `argc`.
--- Suspends the current task until the callback is invoked.
---
--- @param argc number    The argument position where the callback should be injected.
--- @param fun  function  The callback-style function to call.
--- @param ...  any       Arguments to pass before the injected callback.
--- @return any           Values passed to the callback by `fun`.
---
--- Example:
---   -- vim.schedule(callback) takes callback as arg 1
---   M.await(1, vim.schedule)
---
--- Boundary: If `argc` is beyond the number of provided args, the table is
--- extended to fit. Trailing nils are handled via pack_len/unpack_len.
local function await_cbfun(argc, fun, ...)
  local args = pack_len(...)
  return yield(function(callback)
    -- Inject the continuation callback at the specified argument position.
    args[argc] = callback
    args.n = math.max(args.n, argc)
    return fun(unpack_len(args))
  end)
end

--- Awaits a TaskFun inline, running its function directly in the current coroutine
--- rather than spawning a new Task. This avoids Task overhead for simple composition.
---
--- @param taskfun TaskFun  The wrapped async function.
--- @param ...     any      Arguments forwarded to the inner function.
--- @return any             Return values of the inner function.
local function await_taskfun(taskfun, ...)
  return taskfun._fun(...)
end

--- Suspends the current async task until the given awaitable completes.
--- Dispatches to the appropriate await implementation based on argument type.
---
--- Overloads:
---   M.await(argc: number, func: function, ...)  -- callback-style function
---   M.await(task: Task)                         -- await a Task
---   M.await(future: Future)                     -- await a Future
---   M.await(taskfun: TaskFun, ...)              -- inline-run a TaskFun
---
--- @param ... any  See overloads above.
--- @return any     Result(s) of the awaited operation.
---
--- Boundary: Must be called from within an async context (M.async / M.arun).
--- Raises an error if called outside async context or with unsupported argument types.
---
--- Example:
---   local work = M.async(function()
---     -- Await a callback-style API (callback is arg 1):
---     M.await(1, vim.schedule)
---
---     -- Await another Task:
---     local t = M.arun(some_fn)
---     M.await(t)
---
---     -- Await a Future:
---     local f = Future.new()
---     M.await(f)
---   end)
function M.await(...)
  assert(running(), 'Not in async context')
  local arg1 = select(1, ...)
  if type(arg1) == 'number' then
    return await_cbfun(...)
  elseif getmetatable(arg1) == Task then
    return await_task(arg1)
  elseif getmetatable(arg1) == Future then
    return await_future(arg1)
  elseif getmetatable(arg1) == TaskFun then
    return await_taskfun(...)
  end
  error('Invalid arguments, expected Task, Future or (argc, func) got: ' .. type(arg1), 2)
end

--- Wraps a callback-style function so it can be awaited directly without
--- specifying `argc` each time. Useful for frequently-awaited APIs.
---
--- @param argc number    The argument position of the callback in `func`.
--- @param func function  The callback-style function to wrap.
--- @return function      A new function that, when called, awaits `func` automatically.
---
--- Example:
---   local schedule = M.awrap(1, vim.schedule)
---   -- Inside async context:
---   schedule()  -- equivalent to M.await(1, vim.schedule)
function M.awrap(argc, func)
  return function(...)
    return M.await(argc, func, ...)
  end
end

-- Provide M.schedule as a pre-wrapped vim.schedule for convenience.
-- Suspends the current task until the next Neovim event loop tick.
-- Only defined when vim.schedule is available (i.e., inside Neovim).
--
-- Example (inside async context):
--   M.await(M.schedule)  -- yield to the main loop before touching the UI
if vim.schedule then
  M.schedule = M.awrap(1, vim.schedule)
end

--- Creates an object that is both callable and has a GC finalizer.
--- Used internally to attach cleanup logic to the iterator returned by M.iter.
---
--- @param f   function  The callable behavior.
--- @param gc  function  Called when the object is garbage collected.
--- @return table        A callable table with a __gc metamethod.
local function gc_fun(f, gc)
  return setmetatable({}, {
    __gc = gc,
    __call = function(_, ...)
      return f(...)
    end,
  })
end

--- Returns an async iterator over a list of Tasks.
--- Each call to the iterator suspends until the next Task completes,
--- yielding results in completion order (not submission order).
---
--- @param tasks Task[]  A list of Task objects to iterate over.
--- @return function     An async iterator: each call returns (index, err, ...) for
---                      the next completed task, or () when all tasks are done.
---
--- Boundary: Must be called from within an async context.
--- The iterator must be consumed from the same async context it was created in.
--- Dropping the iterator (GC) sets `can_gc = true` but does not cancel tasks.
---
--- Example:
---   local work = M.async(function()
---     local tasks = { M.arun(fn1), M.arun(fn2), M.arun(fn3) }
---     local iter = M.iter(tasks)
---     local i, err, result = iter()
---     while i do
---       if err then print("task", i, "failed:", err)
---       else print("task", i, "returned:", result) end
---       i, err, result = iter()
---     end
---   end)
function M.iter(tasks)
  assert(running(), 'Not in async context')
  local results = {} -- Buffer for completed task results not yet consumed.
  local waiter = nil -- Pending callback waiting for the next result.
  local remaining = #tasks
  local can_gc = false -- Set to true when the iterator is GC'd (unused currently).

  -- Register completion callbacks for all tasks up front.
  -- Results are either dispatched immediately to a waiting consumer,
  -- or buffered in `results` for later consumption.
  for i, task in ipairs(tasks) do
    task:await(function(err, ...)
      remaining = remaining - 1
      if waiter then
        -- A consumer is already waiting — deliver directly.
        local callback = waiter
        waiter = nil
        callback(i, err, ...)
      else
        -- No consumer yet — buffer the result.
        table.insert(results, pack_len(i, err, ...))
      end
    end)
  end

  -- Return a GC-aware callable that yields the next completed task result.
  return gc_fun(
    M.awrap(1, function(callback)
      if #results > 0 then
        -- A result is already buffered — deliver it immediately.
        local res = table.remove(results, 1)
        callback(unpack_len(res))
      elseif remaining == 0 then
        -- All tasks done and no buffered results — signal exhaustion.
        callback()
      else
        -- No result yet — register as the waiting consumer.
        waiter = callback
      end
    end),
    function()
      can_gc = true
    end
  )
end

do
  --- Stores a single iterator result into `results` at index `i`.
  --- Returns false when the iterator is exhausted (i is nil).
  ---
  --- @param results table  Accumulator table.
  --- @param i       any    Task index, or nil if iterator is done.
  --- @param ...     any    Result values for the task.
  --- @return boolean       True if a result was stored, false if done.
  local function collect(results, i, ...)
    if i then
      results[i] = pack_len(...)
    end
    return i ~= nil
  end

  --- Drains an async iterator to completion, collecting all results.
  --- Blocks (suspends) until every task has completed.
  ---
  --- @param iter function  The async iterator from M.iter.
  --- @return table         A table mapping task index -> packed result values.
  local function drain_iter(iter)
    local results = {}
    while collect(results, iter()) do
    end
    return results
  end

  --- Awaits all tasks in the list and returns all results indexed by submission order.
  --- Suspends until every task has completed.
  ---
  --- @param tasks Task[]  List of Tasks to await.
  --- @return table        Table of results: results[i] = packed return values of tasks[i].
  ---
  --- Boundary: Must be called from within an async context.
  --- If any task errors, its error is stored in results[i] but does NOT propagate.
  ---
  --- Example:
  ---   local work = M.async(function()
  ---     local tasks = { M.arun(fn1), M.arun(fn2) }
  ---     local results = M.join(tasks)
  ---     -- results[1] = return values of fn1
  ---     -- results[2] = return values of fn2
  ---   end)
  function M.join(tasks)
    assert(running(), 'Not in async context')
    return drain_iter(M.iter(tasks))
  end

  --- Awaits the first task in the list to complete and returns its result.
  --- Does NOT cancel the remaining tasks.
  ---
  --- @param tasks Task[]  List of Tasks to race.
  --- @return number, any, ...  Index of the first completed task, its error (or nil), and return values.
  ---
  --- Boundary: Must be called from within an async context.
  --- Remaining tasks continue running in the background.
  ---
  --- Example:
  ---   local work = M.async(function()
  ---     local tasks = { M.arun(slow_fn), M.arun(fast_fn) }
  ---     local i, err, result = M.joinany(tasks)
  ---     print("first done:", i, result)
  ---   end)
  function M.joinany(tasks)
    return M.iter(tasks)()
  end
end

-- Re-export core async types for consumers who need direct access.
M.Future = Future -- Read-only async value handle.
M.Promise = Promise -- Write side of a Future; resolves or rejects it.
M.Task = Task -- A running coroutine-based async unit of work.
M.CancellationToken = CancellationToken -- Token for cooperative task cancellation.

return M
