-- nvim-treesitter.async.future
-- Implements the Future/Promise pair: the core value-passing mechanism between
-- async Tasks. A Promise is the write side (resolve/reject), and a Future is
-- the read side (await completion). Together they decouple the producer of an
-- async result from its consumers.
--
-- Design notes:
--   - A Future can have multiple callbacks (fan-out is supported).
--   - All callbacks are dispatched via the Scheduler, never called inline,
--     to prevent re-entrancy and unbounded call stack growth.
--   - pack_len/unpack_len are exported for use by Task and the public API,
--     since they are needed wherever variadic results cross async boundaries.

local Scheduler = require('nvim-treesitter.async.scheduler')

-- Compatibility shim: Lua 5.1 exposes unpack as a global; 5.2+ moved it to table.unpack.
local unpack = table.unpack or unpack

--- Packs variadic arguments into a table, preserving the exact argument count
--- in the `n` field. This is necessary because Lua's `#t` operator stops at
--- the first nil, so trailing nils would be silently dropped without `n`.
---
--- @param ... any  Values to pack.
--- @return table   { n = count, [1] = v1, [2] = v2, ... }
---
--- Example:
---   pack_len(1, nil, 3)  --> { n = 3, 1, nil, 3 }
local function pack_len(...)
  return { n = select('#', ...), ... }
end

--- Unpacks a table packed by pack_len, respecting the stored `n` count so
--- trailing nils are preserved. Falls back to `#t` if `n` is absent.
---
--- @param t?    table    The packed table, or nil (returns nothing if nil).
--- @param first? integer Starting index (default 1). Use 2 to skip an error slot.
--- @return ...           The unpacked values.
---
--- Example:
---   unpack_len({ n = 3, 1, nil, 3 })      --> 1, nil, 3
---   unpack_len({ n = 3, 'err', 2, 3 }, 2) --> 2, 3  (skip error at index 1)
local function unpack_len(t, first)
  if t then
    return unpack(t, first or 1, t.n or #t)
  end
end

--- @class async.Future
--- The read side of a Future/Promise pair. Represents a value that will be
--- available at some point in the future. Consumers register callbacks via
--- on_resolved(); if the Future is already resolved, the callback is enqueued
--- immediately rather than called inline.
---
--- @field private _resolved  boolean                        True once _complete() has been called.
--- @field private _err       any                            Non-nil if the Future was rejected.
--- @field private _args      table?                         pack_len'd success values, or nil on error.
--- @field private _callbacks fun(err: any, ...: any)[]      Pending callbacks waiting for resolution.
--- @field private _complete  fun(self, err: any, args: table?): boolean  Internal resolution method.
local Future = {}
Future.__index = Future

--- Creates a new, unresolved Future.
--- @return async.Future
function Future.new()
  return setmetatable({
    _resolved = false,
    _callbacks = {},
    _err = nil,
    _args = nil,
  }, Future)
end

--- Registers a callback to be called when this Future resolves.
--- The callback signature is: fun(err: any, ...: any)
---   - On success: err is nil, remaining args are the resolved values.
---   - On failure: err is the rejection reason, no further args.
---
--- If the Future is already resolved, the callback is enqueued on the
--- Scheduler immediately (never called synchronously) to ensure consistent
--- async behaviour regardless of registration timing.
---
--- Multiple callbacks can be registered (fan-out). They are dispatched in
--- registration order.
---
--- @param cb fun(err: any, ...: any)
---
--- Example:
---   future:on_resolved(function(err, value)
---     if err then print("error:", err)
---     else print("got:", value) end
---   end)
function Future:on_resolved(cb)
  if self._resolved then
    -- Already done: schedule the callback rather than calling it inline,
    -- so callers always experience async behaviour (no "Zalgo" problem).
    Scheduler.enqueue(function()
      cb(self._err, unpack_len(self._args))
    end)
  else
    table.insert(self._callbacks, cb)
  end
end

--- Returns true if this Future has been resolved or rejected.
--- @return boolean
function Future:is_resolved()
  return self._resolved
end

--- Creates a Future that is already resolved at construction time.
--- Useful for returning immediate values through an async interface without
--- needing a Promise or a scheduler round-trip.
---
--- @param err  any     Rejection reason, or nil for a successful resolution.
--- @param args table?  pack_len'd success values (ignored if err is non-nil).
--- @return async.Future
---
--- Example — pre-resolved success:
---   local f = Future.new_resolved(nil, pack_len(42))
---
--- Example — pre-rejected:
---   local f = Future.new_resolved('something went wrong', nil)
function Future.new_resolved(err, args)
  local self = Future.new()
  self._resolved = true
  self._err = err
  self._args = args
  return self
end

--- Internal method that resolves or rejects the Future.
--- Idempotent: returns false (and does nothing) if already resolved.
--- On first call, stores the result and dispatches all pending callbacks
--- via the Scheduler in registration order.
---
--- @param err  any     Rejection reason, or nil for success.
--- @param args table?  pack_len'd success values (only used when err is nil).
--- @return boolean     true if this call resolved the Future; false if it was already resolved.
---
--- Boundary: Not intended for direct use by consumers — use Promise:resolve()
--- or Promise:reject() instead. Direct use bypasses the Promise abstraction
--- and can lead to double-resolution bugs.
function Future:_complete(err, args)
  if self._resolved then
    return false -- Already resolved; ignore (idempotent).
  end
  self._resolved = true
  self._err = err
  self._args = args

  -- Dispatch all waiting callbacks via the Scheduler.
  -- Each callback is enqueued separately so one slow/erroring callback
  -- does not block or prevent the others from running.
  for _, cb in ipairs(self._callbacks) do
    Scheduler.enqueue(function()
      if err then
        cb(err) -- Rejection: only pass the error.
      else
        cb(nil, unpack_len(args)) -- Success: nil error slot + unpacked values.
      end
    end)
  end
  return true
end

--- @class async.Promise
--- The write side of a Future/Promise pair. Holds a Future and provides
--- resolve()/reject() methods to complete it. Typically created by async
--- infrastructure (timers, semaphores, channels) and the Future is handed
--- to consumers for awaiting.
---
--- @field future async.Future  The associated Future that consumers await.
local Promise = {}
Promise.__index = Promise

--- Creates a new Promise (and its associated Future).
--- @return async.Promise
---
--- Example:
---   local promise = Promise.new()
---   -- Hand promise.future to the consumer:
---   consumer_task:await_future(promise.future)
---   -- Later, resolve from the producer side:
---   promise:resolve(42)
function Promise.new()
  return setmetatable({
    future = Future.new(),
  }, Promise)
end

--- Resolves the associated Future with the given success values.
--- All callbacks registered on the Future will be enqueued on the Scheduler.
---
--- @param ... any  Zero or more success values. Trailing nils are preserved via pack_len.
---
--- Boundary: Calling resolve() after the Future is already resolved is a no-op
--- (idempotent via Future:_complete). Calling both resolve() and reject() is a
--- programming error — only the first call takes effect.
function Promise:resolve(...)
  self.future:_complete(nil, pack_len(...))
end

--- Rejects the associated Future with an error reason.
--- All callbacks registered on the Future will receive (err) with no further args.
---
--- @param err any  The rejection reason (typically a string or error object).
---
--- Boundary: Same idempotency guarantee as resolve(). Only the first call wins.
function Promise:reject(err)
  self.future:_complete(err, nil)
end

return {
  Future = Future,
  Promise = Promise,
  pack_len = pack_len,
  unpack_len = unpack_len,
}
