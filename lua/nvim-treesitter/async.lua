---@meta nvim-treesitter.async
local pcall = copcall or pcall

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
    return unpack(t, first or 1, t.n or #t)
  end
end

--- @class async
local M = {}

--------------------------------------------------------------------------------
-- Scheduler: Manages execution to prevent stack overflows
--------------------------------------------------------------------------------
local Scheduler = {}
do
  local queue = {}
  local is_running = false

  function Scheduler.enqueue(fn)
    table.insert(queue, fn)
    if is_running then
      return
    end
    is_running = true
    while #queue > 0 do
      local next_fn = table.remove(queue, 1)
      local ok, err = pcall(next_fn)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = 'nvim-treesitter.async' })
      end
    end
    is_running = false
  end
end

--------------------------------------------------------------------------------
-- Future & Promise: Result representation and fulfillment
--------------------------------------------------------------------------------
--- @class async.Future
--- @field private _resolved boolean
--- @field private _err any
--- @field private _args table?
--- @field private _callbacks fun(err: any, ...: any)[]
local Future = {}
Future.__index = Future

function Future.new()
  return setmetatable({
    _resolved = false,
    _callbacks = {},
    _err = nil,
    _args = nil,
  }, Future)
end

function Future:on_resolved(cb)
  if self._resolved then
    Scheduler.enqueue(function()
      cb(self._err, unpack_len(self._args))
    end)
  else
    table.insert(self._callbacks, cb)
  end
end

function Future:is_resolved()
  return self._resolved
end

--- @class async.Promise
--- @field future async.Future
local Promise = {}
Promise.__index = Promise

function Promise.new()
  return setmetatable({
    future = Future.new(),
  }, Promise)
end

function Promise:resolve(...)
  if self.future._resolved then
    return
  end
  self.future._resolved = true
  self.future._args = pack_len(...)
  for _, cb in ipairs(self.future._callbacks) do
    Scheduler.enqueue(function()
      cb(nil, unpack_len(self.future._args))
    end)
  end
end

function Promise:reject(err)
  if self.future._resolved then
    return
  end
  self.future._resolved = true
  self.future._err = err
  for _, cb in ipairs(self.future._callbacks) do
    Scheduler.enqueue(function()
      cb(err)
    end)
  end
end

--------------------------------------------------------------------------------
-- CancellationToken: Cooperative cancellation
--------------------------------------------------------------------------------
--- @class async.CancellationToken
--- @field private _cancelled boolean
--- @field private _callbacks fun()[]
local CancellationToken = {}
CancellationToken.__index = CancellationToken

function CancellationToken.new()
  return setmetatable({
    _cancelled = false,
    _callbacks = {},
  }, CancellationToken)
end

function CancellationToken:cancel()
  if self._cancelled then
    return
  end
  self._cancelled = true
  for _, cb in ipairs(self._callbacks) do
    Scheduler.enqueue(cb)
  end
end

function CancellationToken:is_cancelled()
  return self._cancelled
end

function CancellationToken:on_cancelled(cb)
  if self._cancelled then
    Scheduler.enqueue(cb)
  else
    table.insert(self._callbacks, cb)
  end
end

--------------------------------------------------------------------------------
-- Task: High-level coroutine wrapper
--------------------------------------------------------------------------------
local threads = setmetatable({}, { __mode = 'k' })

--- @return async.Task?
local function running()
  return threads[coroutine.running()]
end

--- @class async.Handle
--- @field close fun(self: async.Handle, callback?: fun())
--- @field is_closing? fun(self: async.Handle): boolean

--- @alias async.CallbackFn fun(...: any): async.Handle?

--- @class async.Task : async.Handle
--- @field private _thread thread
--- @field private _future async.Future
--- @field private _cancellation_token async.CancellationToken
--- @field private _current_child? async.Handle
--- @field private _closing boolean
local Task = {}
Task.__index = Task

function Task._new(func)
  local thread = coroutine.create(func)
  local self = setmetatable({
    _thread = thread,
    _future = Future.new(),
    _cancellation_token = CancellationToken.new(),
    _current_child = nil,
    _closing = false,
  }, Task)

  threads[thread] = self
  return self
end

function Task:await(callback)
  self._future:on_resolved(callback)
end

function Task:_completed()
  return self._future:is_resolved()
end

local MAX_TIMEOUT = 2 ^ 31 - 1

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

function Task:wait(timeout)
  local res = pack_len(self:pwait(timeout))
  if not res[1] then
    error(self:traceback(res[2]))
  end
  return unpack_len(res, 2)
end

function Task:_traceback(msg, _lvl)
  _lvl = _lvl or 0
  local thread_id = ('[%s] '):format(self._thread)
  local child = self._current_child
  if getmetatable(child) == Task then
    msg = child:_traceback(msg, _lvl + 1)
  end

  local tblvl = getmetatable(child) == Task and 2 or nil
  msg = (msg or '') .. debug.traceback(self._thread, '', tblvl):gsub('\n\t', '\n\t' .. thread_id)

  if _lvl == 0 then
    msg = msg
      :gsub('\nstack traceback:\n', '\nSTACK TRACEBACK:\n', 1)
      :gsub('\nstack traceback:\n', '\n')
      :gsub('\nSTACK TRACEBACK:\n', '\nstack traceback:\n', 1)
  end
  return msg
end

function Task:traceback(msg)
  return self:_traceback(msg)
end

function Task:raise_on_error()
  self:await(function(err)
    if err then
      error(self:_traceback(err), 0)
    end
  end)
  return self
end

function Task:is_closing()
  return self._closing
end

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
  self._cancellation_token:cancel()

  local function finish()
    self._future._resolved = true
    self._future._err = 'closed'
    threads[self._thread] = nil
    for _, cb in ipairs(self._future._callbacks) do
      Scheduler.enqueue(function()
        cb('closed')
      end)
    end
    if callback then
      callback()
    end
  end

  if self._current_child then
    self._current_child:close(finish)
  else
    finish()
  end

  if not callback then
    vim.wait(0, function()
      return self:_completed()
    end)
  end
end

local function is_async_handle(obj)
  local ty = type(obj)
  return (ty == 'table' or ty == 'userdata') and vim.is_callable(obj.close)
end

function Task:_resume(...)
  local args = pack_len(...)
  Scheduler.enqueue(function()
    if self:_completed() or self._closing then
      return
    end

    local ret = pack_len(coroutine.resume(self._thread, unpack_len(args)))
    local stat = ret[1]

    if not stat then
      self._future._resolved = true
      self._future._err = ret[2]
      threads[self._thread] = nil
      for _, cb in ipairs(self._future._callbacks) do
        cb(ret[2])
      end
    elseif coroutine.status(self._thread) == 'dead' then
      local result = pack_len(unpack_len(ret, 2))
      self._future._resolved = true
      self._future._args = result
      threads[self._thread] = nil
      for _, cb in ipairs(self._future._callbacks) do
        cb(nil, unpack_len(result))
      end
    else
      local fn = ret[2]
      local ok, r = pcall(fn, function(...)
        if is_async_handle(r) then
          local args = pack_len(...)
          r:close(function()
            self:_resume(unpack_len(args))
          end)
        else
          self:_resume(...)
        end
      end)

      if not ok then
        self._future._resolved = true
        self._future._err = r
        threads[self._thread] = nil
        for _, cb in ipairs(self._future._callbacks) do
          cb(r)
        end
      elseif is_async_handle(r) then
        self._current_child = r
      end
    end
  end)
end

function Task:status()
  return coroutine.status(self._thread)
end

--------------------------------------------------------------------------------
-- Semaphore: Synchronization primitive
--------------------------------------------------------------------------------
--- @class async.Semaphore
--- @field private _permits integer
--- @field private _waiters async.Promise[]
local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.new(permits)
  return setmetatable({
    _permits = permits or 1,
    _waiters = {},
  }, Semaphore)
end

function Semaphore:acquire()
  if self._permits > 0 then
    self._permits = self._permits - 1
    local f = Future.new()
    f._resolved = true
    f._args = pack_len(true)
    return f
  end
  local promise = Promise.new()
  table.insert(self._waiters, promise)
  return promise.future
end

function Semaphore:release()
  self._permits = self._permits + 1
  if #self._waiters > 0 then
    local promise = table.remove(self._waiters, 1)
    self._permits = self._permits - 1
    promise:resolve(true)
  end
end
M.Semaphore = Semaphore

--------------------------------------------------------------------------------
-- Channel: Task communication
--------------------------------------------------------------------------------
--- @class async.Channel
--- @field private _queue any[]
--- @field private _waiters async.Promise[]
local Channel = {}
Channel.__index = Channel

function Channel.new()
  return setmetatable({
    _queue = {},
    _waiters = {},
  }, Channel)
end

function Channel:send(val)
  if #self._waiters > 0 then
    local promise = table.remove(self._waiters, 1)
    promise:resolve(val)
  else
    table.insert(self._queue, val)
  end
end

function Channel:recv()
  if #self._queue > 0 then
    local val = table.remove(self._queue, 1)
    local future = Future.new()
    future._resolved = true
    future._args = pack_len(val)
    return future
  end
  local promise = Promise.new()
  table.insert(self._waiters, promise)
  return promise.future
end
M.Channel = Channel

--------------------------------------------------------------------------------
-- Timer: Async sleep and timeouts
--------------------------------------------------------------------------------
--- @async
--- @param ms integer
function M.sleep(ms)
  local promise = Promise.new()
  local timer = vim.uv.new_timer()
  timer:start(ms, 0, function()
    timer:stop()
    timer:close()
    promise:resolve()
  end)
  return M.await(promise.future)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
function M.arun(func, ...)
  local task = Task._new(func)
  task:_resume(...)
  return task
end

local TaskFun = {}
TaskFun.__index = TaskFun

function TaskFun:__call(...)
  return M.arun(self._fun, ...)
end

function M.async(fun)
  return setmetatable({ _fun = fun }, TaskFun)
end

function M.status(task)
  task = task or running()
  if task then
    assert(getmetatable(task) == Task, 'Expected Task')
    return task:status()
  end
end

local function yield(fun)
  assert(type(fun) == 'function', 'Expected function')
  return coroutine.yield(fun)
end

local function await_task(task)
  local res = pack_len(yield(function(callback)
    task:await(callback)
  end))

  if res[1] then
    error(res[1], 0)
  end
  return unpack_len(res, 2)
end

local function await_future(future)
  local res = pack_len(yield(function(callback)
    future:on_resolved(callback)
  end))
  if res[1] then
    error(res[1], 0)
  end
  return unpack_len(res, 2)
end

local function await_cbfun(argc, fun, ...)
  local args = pack_len(...)
  return yield(function(callback)
    args[argc] = callback
    args.n = math.max(args.n, argc)
    return fun(unpack_len(args))
  end)
end

local function await_taskfun(taskfun, ...)
  return taskfun._fun(...)
end

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

function M.awrap(argc, func)
  return function(...)
    return M.await(argc, func, ...)
  end
end

if vim.schedule then
  M.schedule = M.awrap(1, vim.schedule)
end

local function gc_fun(f, gc)
  return setmetatable({}, {
    __gc = gc,
    __call = function(_, ...)
      return f(...)
    end,
  })
end

function M.iter(tasks)
  assert(running(), 'Not in async context')
  local results = {}
  local waiter = nil
  local remaining = #tasks
  local can_gc = false

  for i, task in ipairs(tasks) do
    task:await(function(err, ...)
      remaining = remaining - 1
      if waiter then
        local callback = waiter
        waiter = nil
        callback(i, err, ...)
      else
        table.insert(results, pack_len(i, err, ...))
      end
    end)
  end

  return gc_fun(
    M.awrap(1, function(callback)
      if #results > 0 then
        local res = table.remove(results, 1)
        callback(unpack_len(res))
      elseif remaining == 0 then
        callback()
      else
        waiter = callback
      end
    end),
    function()
      can_gc = true
    end
  )
end

do
  local function collect(results, i, ...)
    if i then
      results[i] = pack_len(...)
    end
    return i ~= nil
  end

  local function drain_iter(iter)
    local results = {}
    while collect(results, iter()) do
    end
    return results
  end

  function M.join(tasks)
    assert(running(), 'Not in async context')
    return drain_iter(M.iter(tasks))
  end

  function M.joinany(tasks)
    return M.iter(tasks)()
  end
end

return M
