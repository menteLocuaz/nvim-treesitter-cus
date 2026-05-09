-- nvim-treesitter.async.scheduler
-- A simple synchronous FIFO task scheduler used to drive async task resumptions.
-- Ensures that enqueued callbacks are executed one at a time in order, and that
-- re-entrant enqueues (callbacks that enqueue more work) are handled safely
-- without recursion or stack overflow.

-- Prefer coroutine-aware pcall (copcall) if available (e.g., from coxpcall),
-- falling back to standard pcall. This ensures errors inside coroutine-resumed
-- callbacks are caught correctly in environments that need it.
local pcall = copcall or pcall

local Scheduler = {}
Scheduler.__index = Scheduler

-- FIFO queue of pending callback functions to execute.
local queue = {}

-- Guards against re-entrant execution. When true, the drain loop is already
-- running and new enqueues will simply append to the queue rather than
-- starting a second loop.
local is_running = false

--- Enqueues a function to be executed by the scheduler.
--- If the scheduler is not already running, starts the drain loop immediately,
--- processing all queued functions in FIFO order.
--- If called re-entrantly (i.e., from within a running callback), the function
--- is appended to the queue and will be picked up by the already-running loop.
---
--- Errors thrown by any callback are caught and reported via vim.notify
--- without interrupting the remaining queue.
---
--- @param fn function  The callback to enqueue and eventually execute.
---
--- Example:
---   Scheduler.enqueue(function() print("step 1") end)
---   Scheduler.enqueue(function() print("step 2") end)
---   -- Output (in order): "step 1", then "step 2"
---
--- Re-entrant example:
---   Scheduler.enqueue(function()
---     print("outer")
---     Scheduler.enqueue(function() print("inner") end)
---     -- "inner" is queued but NOT run recursively; it runs after "outer" returns.
---   end)
---   -- Output: "outer", then "inner"
---
--- Boundary cases:
---   - If `fn` raises an error, it is reported but does NOT stop subsequent callbacks.
---   - Re-entrant calls are safe; no recursion occurs.
---   - The queue is fully drained before is_running is reset to false.
function Scheduler.enqueue(fn)
  table.insert(queue, fn)

  -- If already draining, let the active loop pick up the new entry.
  if is_running then
    return
  end

  -- Claim the drain loop.
  is_running = true

  -- Process all queued functions in order. New entries added during execution
  -- are appended to `queue` and caught by subsequent iterations of this loop.
  while #queue > 0 do
    local next_fn = table.remove(queue, 1)
    local ok, err = pcall(next_fn)
    if not ok then
      -- Report errors without halting the scheduler.
      vim.notify(tostring(err), vim.log.levels.ERROR, { title = 'nvim-treesitter.async' })
    end
  end

  -- Release the lock so future enqueues can start a new drain loop.
  is_running = false
end

return Scheduler
