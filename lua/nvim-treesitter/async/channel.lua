-- nvim-treesitter.async.channel
-- Implements an unbuffered/buffered async FIFO channel for passing values
-- between async Tasks. Modelled after Go channels: senders never block
-- (values are buffered), while receivers suspend if no value is available.
--
-- Design notes:
--   - Send is always synchronous: values are either delivered directly to a
--     waiting receiver or appended to the internal queue. Send never suspends.
--   - Recv returns a Future: already-resolved if a value is queued, or a
--     pending Future that resolves when the next send arrives.
--   - Close unblocks all pending receivers with an error and prevents further sends.
--   - Only one value is delivered per send/recv pair (no broadcast).

local Future = require('nvim-treesitter.async.future').Future
local Promise = require('nvim-treesitter.async.future').Promise
local pack_len = require('nvim-treesitter.async.future').pack_len

--- @class async.Channel
--- A one-way async message queue. Values flow from sender(s) to receiver(s)
--- in FIFO order. Multiple senders and receivers are supported, but each
--- value is delivered to exactly one receiver.
---
--- @field private _queue   any[]             Buffered values not yet consumed by a receiver.
--- @field private _waiters async.Promise[]   FIFO queue of Promises for suspended receivers.
--- @field private _closed  boolean           True once close() has been called.
local Channel = {}
Channel.__index = Channel

--- Creates a new, open, empty Channel.
--- @return async.Channel
---
--- Example:
---   local ch = Channel.new()
function Channel.new()
  return setmetatable({
    _queue = {},
    _waiters = {},
    _closed = false,
  }, Channel)
end

--- Sends a value into the channel.
--- Never suspends: if a receiver is already waiting, the value is delivered
--- directly to it (FIFO); otherwise it is appended to the internal buffer.
---
--- @param val any  The value to send. May be any Lua value including nil,
---                 though nil cannot be distinguished from "no value" by
---                 receivers — prefer sentinel values if nil is meaningful.
---
--- Boundary cases:
---   - Sending on a closed channel raises immediately.
---   - Multiple senders are safe; values are queued in call order.
---   - There is no backpressure: the internal buffer grows unboundedly if
---     receivers are slower than senders.
---
--- Example:
---   ch:send(42)
---   ch:send("hello")
function Channel:send(val)
  if self._closed then
    error('send on closed channel')
  end

  if #self._waiters > 0 then
    -- A receiver is already suspended waiting for a value.
    -- Deliver directly to the oldest waiter (FIFO) without buffering.
    local promise = table.remove(self._waiters, 1)
    promise:resolve(val)
  else
    -- No receivers waiting: buffer the value for the next recv() call.
    table.insert(self._queue, val)
  end
end

--- Receives the next value from the channel.
--- Returns an already-resolved Future if a value is buffered, or a pending
--- Future that resolves when the next send() arrives. Must be awaited:
---   local val = M.await(ch:recv())
---
--- @return async.Future  Resolves to the next value, or rejects with
---                       'channel closed' if the channel is closed.
---
--- Boundary cases:
---   - Receiving from a closed channel returns an immediately-rejected Future
---     (error: 'channel closed'). Does not raise.
---   - Multiple concurrent receivers are safe; each gets a distinct value in
---     FIFO order relative to when they called recv().
---   - If the channel is closed while a receiver is suspended, its Future is
---     rejected via Channel:close().
---
--- Example (inside async context):
---   local val = M.await(ch:recv())   -- suspends if no value is available
---   if val == nil then ... end        -- check for close if using sentinel
function Channel:recv()
  if self._closed then
    -- Return a pre-rejected Future so the caller can handle close gracefully
    -- without needing a separate is_closed() check.
    return Future.new_resolved('channel closed', nil)
  end

  if #self._queue > 0 then
    -- A value is already buffered: return a pre-resolved Future so the
    -- caller does not need to suspend at all (fast path).
    local val = table.remove(self._queue, 1)
    return Future.new_resolved(nil, pack_len(val))
  end

  -- No value available: create a Promise and queue it.
  -- The caller suspends on the returned Future until send() resolves it.
  local promise = Promise.new()
  table.insert(self._waiters, promise)
  return promise.future
end

--- Closes the channel, unblocking all currently suspended receivers with an error.
--- After close():
---   - All pending recv() Futures are rejected with 'channel closed'.
---   - Any subsequent send() call raises immediately.
---   - Any subsequent recv() call returns an already-rejected Future.
---
--- Idempotent in effect (calling close() twice is safe only if no sends occur
--- between calls, since the second close does not re-reject already-cleared waiters).
---
--- Example:
---   ch:close()
---   -- Any task awaiting ch:recv() will now receive an error.
function Channel:close()
  self._closed = true

  -- Reject all pending receiver Promises so suspended Tasks are unblocked
  -- and can handle the close condition rather than waiting forever.
  for _, promise in ipairs(self._waiters) do
    promise:reject('channel closed')
  end

  -- Clear the waiters list. Buffered values in _queue are silently dropped.
  self._waiters = {}
end

return Channel
