---@meta nvim-treesitter.async vendored file, don't diagnose
local pcall = copcall or pcall

--- Internal environment dependency provider (allows mocking vim.wait / vim.is_callable in tests)
local deps = {
  wait = function(timeout, condition)
    return vim.wait(timeout, condition)
  end,
  is_callable = function(f)
    return vim.is_callable(f)
  end,
}

--- @param ... any
--- @return {[integer]: any, n: integer}
local function pack_len(...)
  return { n = select('#', ...), ... }
end

--- like unpack() but use the length set by F.pack_len if present
--- @param t? { [integer]: any, n?: integer }
--- @param first? integer
--- @return ...any
local function unpack_len(t, first)
  if t then
    return unpack(t, first or 1, t.n or table.maxn(t))
  end
end

--- @param obj any
--- @return boolean
local function is_async_handle(obj)
  local ty = type(obj)
  return (ty == 'table' or ty == 'userdata') and deps.is_callable(obj.close)
end

--- Normalize repeated "stack traceback:" headers, keeping only the first one.
--- @param trace string
--- @return string
local function deduplicate_traceback_headers(trace)
  return (
    trace
      :gsub('\nstack traceback:\n', '\nSTACK TRACEBACK:\n', 1)
      :gsub('\nstack traceback:\n', '\n')
      :gsub('\nSTACK TRACEBACK:\n', '\nstack traceback:\n', 1)
  )
end

--- @class async
local M = {}

--- Weak table to keep track of running tasks
--- @type table<thread,async.Task?>
local threads = setmetatable({}, { __mode = 'k' })

--- @return async.Task?
local function running()
  local task = threads[coroutine.running()]
  if task and not (task:_completed() or task._closing) then
    return task
  end
end

--- Base class for async tasks. Async functions should return a subclass of
--- this. This is designed specifically to be a base class of uv_handle_t
--- @class async.Handle
--- @field close fun(self: async.Handle, callback?: fun())
--- @field is_closing? fun(self: async.Handle): boolean

--- @alias async.CallbackFn fun(...: any): async.Handle?

--- @class async.Task<R> : async.Handle
--- @field package _callbacks table<integer,fun(err?: any, ...: R...)>
--- @field package _callback_pos integer
--- @field private _thread thread
--- @field private _current_child? async.Handle
--- @field private _err? any
--- @field private _result? R[]
local Task = {}
Task.__index = Task

--- @private
--- @generic T, R
--- @param func async fun(...: T...): R...
--- @return async.Task<R...>
function Task._new(func)
  local thread = coroutine.create(func)

  local self = setmetatable({
    _closing = false,
    _thread = thread,
    _callbacks = {},
    _callback_pos = 1,
  }, Task)

  threads[thread] = self

  return self
end

--- @param obj any
--- @return boolean
local function is_task(obj)
  return getmetatable(obj) == Task
end

--- @param callback fun(err?: any, ...: R...)
function Task:await(callback)
  if self._closing then
    callback('closing')
  elseif self:_completed() then
    -- Already finished or closed
    callback(self._err, unpack_len(self._result))
  else
    self._callbacks[self._callback_pos] = callback
    self._callback_pos = self._callback_pos + 1
  end
end

--- @package
function Task:_completed()
  return (self._err or self._result) ~= nil
end

-- Use max 32-bit signed int value to avoid overflow on 32-bit systems.
-- Do not use `math.huge` as it is not interpreted as a positive integer on all
-- platforms.
local MAX_TIMEOUT = 2 ^ 31 - 1

--- Synchronously wait (protected) for a task to finish (blocking)
--- @param timeout? integer
--- @return boolean status
--- @return R... result or error
function Task:pwait(timeout)
  local done = deps.wait(timeout or MAX_TIMEOUT, function()
    return self:_completed()
  end)

  if not done then
    return false, 'timeout'
  elseif self._err then
    return false, self._err
  else
    return true, unpack_len(self._result)
  end
end

--- Synchronously wait for a task to finish (blocking)
--- @param timeout? integer Timeout in milliseconds
--- @return R result
function Task:wait(timeout)
  local res = pack_len(self:pwait(timeout))
  local stat = res[1]

  if not stat then
    error(self:traceback(res[2]))
  end

  return unpack_len(res, 2)
end

--- @private
--- @param msg? string
--- @param _lvl? integer
--- @return string
function Task:_traceback(msg, _lvl)
  _lvl = _lvl or 0

  local thread_prefix = ('[%s] '):format(self._thread)
  local child = self._current_child
  local child_is_task = is_task(child)

  if child_is_task then
    --- @cast child async.Task
    msg = child:_traceback(msg, _lvl + 1)
  end

  local tblvl = child_is_task and 2 or nil
  local raw_tb = debug.traceback(self._thread, '', tblvl):gsub('\n\t', '\n\t' .. thread_prefix)
  msg = (msg or '') .. raw_tb

  if _lvl == 0 then
    msg = deduplicate_traceback_headers(msg)
  end

  return msg
end

--- Get the traceback of a task when it is not active.
--- Will also get the traceback of nested tasks.
--- @param msg? string
--- @return string
function Task:traceback(msg)
  return self:_traceback(msg)
end

--- If a task completes with an error, raise the error
--- @return async.Task<R>
function Task:raise_on_error()
  self:await(function(err)
    if err then
      error(self:_traceback(err), 0)
    end
  end)
  return self
end

--- @private
--- @param err? any
--- @param result? {[integer]: any, n: integer}
function Task:_finish(err, result)
  self._current_child = nil
  self._err = err
  self._result = result
  threads[self._thread] = nil

  local errs = {} --- @type string[]
  for _, cb in pairs(self._callbacks) do
    --- @type boolean, string
    local ok, cb_err = pcall(cb, err, unpack_len(result))
    if not ok then
      errs[#errs + 1] = cb_err
    end
  end

  if #errs > 0 then
    error(table.concat(errs, '\n'), 0)
  end
end

--- @return boolean
function Task:is_closing()
  return self._closing
end

--- @private
--- @param on_closed fun()
function Task:_close_child_or_finish(on_closed)
  if self._current_child then
    self._current_child:close(function()
      self:_finish('closed')
      on_closed()
    end)
  else
    self:_finish('closed')
    on_closed()
  end
end

--- Close the task and all its children.
--- If callback is provided it will run asynchronously,
--- else it will run synchronously.
--- @param callback? fun()
function Task:close(callback)
  if self:_completed() then
    if callback then
      callback()
    end
    return
  end

  if self._closing then
    return
  end

  self._closing = true

  if callback then -- async
    self:_close_child_or_finish(callback)
  else -- sync
    self:_close_child_or_finish(function() end)
    deps.wait(0, function()
      return self:_completed()
    end)
  end
end

--- Executes the function provided by the coroutine and manages its child handle, if one exists.
--- @private
--- @param fn async.CallbackFn
function Task:_dispatch_yielded(fn)
  local ok, r
  ok, r = pcall(fn, function(...)
    if is_async_handle(r) then
      --- @cast r async.Handle
      -- We must close children before we resume to ensure
      -- all resources are collected.
      local args = pack_len(...)
      r:close(function()
        self:_resume(unpack_len(args))
      end)
    else
      self:_resume(...)
    end
  end)

  if not ok then
    self:_finish(r)
  elseif is_async_handle(r) then
    self._current_child = r
  end
end

--- @param ... any
function Task:_resume(...)
  --- @type [boolean, string|async.CallbackFn]
  local ret = pack_len(coroutine.resume(self._thread, ...))
  local stat = ret[1]

  if not stat then
    -- Coroutine had error
    self:_finish(ret[2])
  elseif coroutine.status(self._thread) == 'dead' then
    -- Coroutine finished
    local result = pack_len(unpack_len(ret, 2))
    self:_finish(nil, result)
  else
    local fn = ret[2]
    --- @cast fn -string
    self:_dispatch_yielded(fn)
  end
end

--- @return 'running'|'suspended'|'normal'|'dead'?
function Task:status()
  return coroutine.status(self._thread)
end

--- Run a function in an async context, asynchronously.
--- @generic T, R
--- @param func async fun(...: T...): R...
--- @param ... T...
--- @return async.Task<R...>
function M.arun(func, ...)
  local task = Task._new(func)
  task:_resume(...)
  return task
end

--- @alias async.TaskFun<T, R> fun(...: T...): async.Task<R>

--- @generic T, R
--- @class async._TaskFun<T, R>
--- @field package _fun async fun(...: T...): R...
--- @operator call(...: T...): async.Task<R>
local TaskFun = {}
TaskFun.__index = TaskFun

--- @param obj any
--- @return boolean
local function is_taskfun(obj)
  return getmetatable(obj) == TaskFun
end

--- @generic T, R
--- @param self async._TaskFun<T, R>
--- @param ... T...
--- @return async.Task<R>
function TaskFun:__call(...)
  return M.arun(self._fun, ...)
end

--- Create an async function
--- @generic T, R
--- @param fun async fun(...: T...): R...
--- @return fun(...: T...): async.Task<R...>
function M.async(fun)
  return setmetatable({ _fun = fun }, TaskFun)
end

--- Returns the status of a task’s thread.
--- @param task? async.Task
--- @return 'running'|'suspended'|'normal'|'dead'?
function M.status(task)
  task = task or running()
  if task then
    assert(is_task(task), 'Expected Task')
    return task:status()
  end
end

--- @async
--- @generic R1, R2, R3, R4
--- @param fun fun(callback: fun(r1: R1, r2: R2, r3: R3, r4: R4)): any?
--- @return R1, R2, R3, R4
local function yield(fun)
  assert(type(fun) == 'function', 'Expected function')
  return coroutine.yield(fun)
end

--- @async
--- @generic R
--- @param task async.Task<R>
--- @return R
local function await_task(task)
  local res = pack_len(yield(function(callback)
    task:await(callback)
    return task
  end))

  local err = res[1]
  if err then
    error(err, 0)
  end

  return unpack_len(res, 2)
end

--- Asynchronous blocking wait
--- @param argc integer
--- @param fun async.CallbackFn
--- @param ... any func arguments
--- @return any ...
local function await_cbfun(argc, fun, ...)
  local args = pack_len(...)

  return yield(function(callback)
    args[argc] = callback
    args.n = math.max(args.n, argc)
    return fun(unpack_len(args))
  end)
end

--- @generic T, R
--- @param taskfun async._TaskFun<T, R>
--- @param ... T...
--- @return R
local function await_taskfun(taskfun, ...)
  return taskfun._fun(...)
end

--- Asynchronous blocking wait
--- @async
--- @generic T, R
--- @overload fun(argc: integer, func: async.CallbackFn, ...:any): any ...
--- @overload fun(task: async.Task<R>): R
--- @overload fun(taskfun: (fun(...: T...): async.Task<R>), ...: T...): R
function M.await(...)
  assert(running(), 'Not in async context')

  local arg1 = select(1, ...)

  if type(arg1) == 'number' then
    return await_cbfun(...)
  elseif is_task(arg1) then
    return await_task(...)
  elseif is_taskfun(arg1) then
    return await_taskfun(...)
  end

  error('Invalid arguments, expected Task or (argc, func) got: ' .. type(arg1), 2)
end

--- Creates an async function with a callback style function.
--- @param argc integer
--- @param func async.CallbackFn
--- @return async function
function M.awrap(argc, func)
  assert(type(argc) == 'number')
  assert(type(func) == 'function')
  --- @async
  return function(...)
    return M.await(argc, func, ...)
  end
end

if vim and vim.schedule then
  --- An async function that when called will yield to the Neovim scheduler to be
  --- able to call the API.
  M.schedule = M.awrap(1, vim.schedule)
end

--- Create a function that runs a function when it is garbage collected.
--- @generic F
--- @param f F
--- @param gc fun()
--- @return F
local function gc_fun(f, gc)
  local proxy = newproxy(true)
  local proxy_mt = getmetatable(proxy)
  proxy_mt.__gc = gc
  proxy_mt.__call = function(_, ...)
    return f(...)
  end

  return proxy
end

--- @param task_cbs table<async.Task,function>
local function gc_cbs(task_cbs)
  for task, tcb in pairs(task_cbs) do
    for j, cb in pairs(task._callbacks) do
      if cb == tcb then
        task._callbacks[j] = nil
        break
      end
    end
  end
end

--- @async
--- @param tasks async.Task[]
--- @return fun(): (integer?, any?, ...)
function M.iter(tasks)
  assert(running(), 'Not in async context')

  local results = {} --- @type [integer, any, ...][]
  local waiter = nil
  local task_cbs = {} --- @type table<async.Task,function>
  local remaining = #tasks
  local can_gc_cbs = false

  local function register_task(i, task)
    local function cb(err, ...)
      if can_gc_cbs == true then
        gc_cbs(task_cbs)
      end

      local callback = waiter
      waiter = nil
      remaining = remaining - 1

      if callback then
        callback(i, err, ...)
      else
        table.insert(results, pack_len(i, err, ...))
      end
    end

    task_cbs[task] = cb
    task:await(cb)
  end

  for i, task in ipairs(tasks) do
    register_task(i, task)
  end

  local function next_item(callback)
    if next(results) then
      local res = table.remove(results, 1)
      callback(unpack_len(res))
    elseif remaining == 0 then
      callback() -- finish
    else
      assert(not waiter, 'internal error: waiter already set')
      waiter = callback
    end
  end

  return gc_fun(M.awrap(1, next_item), function()
    can_gc_cbs = true
  end)
end

do -- join()
  --- @param results table<integer,table>
  --- @param i integer
  --- @param ... any
  --- @return boolean
  local function collect(results, i, ...)
    if i then
      results[i] = pack_len(...)
    end
    return i ~= nil
  end

  --- @param iter fun(): ...
  --- @return table<integer,table>
  local function drain_iter(iter)
    local results = {} --- @type table<integer,table>
    while collect(results, iter()) do
    end
    return results
  end

  --- @async
  --- Wait for all tasks to finish and return their results.
  --- @param tasks async.Task[]
  --- @return table<integer,[any?,...?]>
  function M.join(tasks)
    assert(running(), 'Not in async context')
    return drain_iter(M.iter(tasks))
  end

  --- @async
  --- @param tasks async.Task[]
  --- @return integer?, any?, ...?
  function M.joinany(tasks)
    return M.iter(tasks)()
  end
end

return M