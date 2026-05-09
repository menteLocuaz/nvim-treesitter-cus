-- nvim-treesitter.async.cancellation
-- Implements a one-shot cooperative cancellation token. A CancellationToken is
-- created with each Task and can be used by async operations to register cleanup
-- callbacks that fire when the Task is cancelled via Task:close().
--
-- Design notes:
--   - Cancellation is cooperative: the token signals intent, but running code
--     must check is_cancelled() or register on_cancelled() callbacks to act on it.
--   - All callbacks are dispatched via the Scheduler (never inline) for
--     consistent async behaviour and to avoid re-entrancy.
--   - The token is one-shot: once cancelled it stays cancelled permanently.
--     There is no reset or uncancel operation.

local Scheduler = require('nvim-treesitter.async.scheduler')

--- @class async.CancellationToken
--- Signals cooperative cancellation to async operations running inside a Task.
--- Producers (e.g., timers, I/O operations) register on_cancelled() callbacks
--- to clean up resources when the owning Task is closed. Consumers can also
--- poll is_cancelled() at yield points to exit early.
---
--- @field private _cancelled boolean    True once cancel() has been called.
--- @field private _callbacks fun()[]    Pending callbacks to fire on cancellation.
local CancellationToken = {}
CancellationToken.__index = CancellationToken

--- Creates a new, uncancelled CancellationToken.
--- Typically called by Task._new() — one token per Task.
--- @return async.CancellationToken
function CancellationToken.new()
  return setmetatable({
    _cancelled = false,
    _callbacks = {},
  }, CancellationToken)
end

--- Cancels the token, enqueuing all registered callbacks on the Scheduler.
--- Idempotent: subsequent calls after the first are silent no-ops.
---
--- After cancel():
---   - is_cancelled() returns true.
---   - Any future on_cancelled() registrations are enqueued immediately.
---   - The internal callback list is cleared (callbacks fire at most once).
---
--- Boundary: cancel() does not directly stop any running coroutine. It only
--- signals intent and fires registered cleanup callbacks. The Task itself is
--- responsible for resolving its Future and removing the thread entry.
---
--- Example:
---   token:cancel()  -- called by Task:close() on the owning Task
function CancellationToken:cancel()
  if self._cancelled then
    return -- Already cancelled; ignore duplicate calls.
  end
  self._cancelled = true

  -- Snapshot and clear the callback list before enqueuing, so any
  -- on_cancelled() calls made during callback execution go to the
  -- Scheduler directly (via the already-cancelled fast path) rather
  -- than being appended to a list that will never be drained.
  local callbacks = self._callbacks
  self._callbacks = {}

  for _, cb in ipairs(callbacks) do
    Scheduler.enqueue(cb)
  end
end

--- Returns true if this token has been cancelled.
--- Can be polled at yield points inside an async function for early exit.
---
--- @return boolean
---
--- Example:
---   local token = ...  -- obtained from the current Task
---   while not token:is_cancelled() do
---     M.await(M.sleep(100))
---     do_incremental_work()
---   end
function CancellationToken:is_cancelled()
  return self._cancelled
end

--- Registers a callback to be called when this token is cancelled.
--- If the token is already cancelled, the callback is enqueued on the
--- Scheduler immediately rather than called inline (consistent async behaviour).
---
--- Callbacks are fired in registration order and at most once.
--- Typically used by async primitives (timers, I/O handles) to close their
--- underlying resources when the owning Task is cancelled.
---
--- @param cb fun()  Zero-argument cleanup callback.
---
--- Boundary: The callback must not raise — errors inside Scheduler-enqueued
--- functions are caught and reported by the Scheduler, but will not propagate
--- back to the cancelling Task.
---
--- Example — stop a timer if the Task is cancelled before it fires:
---   token:on_cancelled(function()
---     timer:stop()
---     timer:close()
---   end)
function CancellationToken:on_cancelled(cb)
  if self._cancelled then
    -- Already cancelled: enqueue immediately so the caller always experiences
    -- async behaviour regardless of registration timing (no "Zalgo" problem).
    Scheduler.enqueue(cb)
  else
    table.insert(self._callbacks, cb)
  end
end

return CancellationToken
