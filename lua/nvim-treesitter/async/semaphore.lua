-- nvim-treesitter.async.semaphore
-- Implements an async counting semaphore for limiting concurrent access to a
-- shared resource across async Tasks. Waiters are queued in FIFO order and
-- resumed one at a time as permits become available.

local Future = require('nvim-treesitter.async.future').Future
local Promise = require('nvim-treesitter.async.future').Promise

--- @class async.Semaphore
--- @field private _permits  integer      Number of currently available permits.
--- @field private _acquired integer      Number of permits currently held by callers.
--- @field private _waiters  async.Promise[]  FIFO queue of Promises for blocked acquirers.
local Semaphore = {}
Semaphore.__index = Semaphore

--- Creates a new Semaphore with the given number of permits.
---
--- @param permits? integer  Maximum number of concurrent holders. Defaults to 1
---                          (i.e., a mutex / binary semaphore).
--- @return async.Semaphore
---
--- Example — limit to 3 concurrent tasks:
---   local sem = Semaphore.new(3)
---
--- Example — mutual exclusion (default):
---   local sem = Semaphore.new()  -- equivalent to Semaphore.new(1)
---
--- Boundary: `permits` must be a positive integer. Passing 0 means all
--- acquirers will block immediately until someone releases.
function Semaphore.new(permits)
  return setmetatable({
    _permits = permits or 1,
    _acquired = 0,
    _waiters = {},
  }, Semaphore)
end

--- Acquires one permit from the semaphore.
--- If a permit is available, returns an already-resolved Future immediately.
--- If no permits are available, returns a Future that resolves once a permit
--- is released and this waiter reaches the front of the FIFO queue.
---
--- Must be awaited inside an async context:
---   M.await(sem:acquire())
---
--- @return async.Future  Resolves to `true` when the permit is granted.
---
--- Example:
---   local work = M.async(function()
---     M.await(sem:acquire())
---     -- critical section
---     sem:release()
---   end)
---
--- Boundary: The returned Future must eventually be paired with a release()
--- call, or the semaphore will be permanently exhausted for those permits.
function Semaphore:acquire()
  if self._permits > 0 then
    self._permits = self._permits - 1
    self._acquired = self._acquired + 1
    return Future.new_resolved(nil, { n = 1, true })
  end

  -- No permits available: create a Promise and queue it.
  -- The caller will suspend on the returned Future until release() resolves it.
  local promise = Promise.new()
  table.insert(self._waiters, promise)
  return promise.future
end

--- Releases one previously acquired permit back to the semaphore.
--- If there are waiters in the queue, the oldest waiter is immediately granted
--- the permit (FIFO) by resolving its Promise. Otherwise the permit count is
--- incremented for the next acquire() call.
---
--- @return nil
---
--- Example:
---   sem:release()
---
--- Boundary: Calling release() more times than acquire() is a programming
--- error and raises immediately. This prevents permit count inflation.
function Semaphore:release()
  if self._acquired <= 0 then
    error('Semaphore:release() called without prior acquire()')
  end
  self._acquired = self._acquired - 1

  if #self._waiters > 0 then
    -- Hand the permit directly to the next waiter without returning it to
    -- the pool first, keeping _permits consistent (it was already decremented
    -- by the waiter's acquire() call path via this release).
    local promise = table.remove(self._waiters, 1)
    self._permits = self._permits - 1 -- Offset: permit goes to waiter, not pool.
    promise:resolve(true)
  else
    -- No waiters: return the permit to the pool.
    self._permits = self._permits + 1
  end
end

--- Returns a scope guard that automatically releases the semaphore when the
--- enclosing scope exits, including on error. Designed for use with Lua 5.4
--- to-be-closed variables (`<close>`).
---
--- @return table  A to-be-closed object whose __close metamethod calls release().
---
--- Example (Lua 5.4):
---   local work = M.async(function()
---     M.await(sem:acquire())
---     local _guard <close> = sem:scoped()
---     -- permit is held here
---     do_work()
---     -- permit is automatically released when _guard goes out of scope,
---     -- even if do_work() raises an error.
---   end)
---
--- Boundary: acquire() must be called (and awaited) BEFORE calling scoped().
--- scoped() only manages the release — it does not acquire the permit itself.
--- If the scope exits with an error, the error is re-raised after release().
function Semaphore:scoped()
  return setmetatable({ _sem = self }, {
    __close = function(_, err)
      self:release()
      if err then
        -- Re-raise the original error after releasing, preserving the error
        -- without adding extra stack levels (level 0).
        error(err, 0)
      end
    end,
  })
end

return Semaphore
