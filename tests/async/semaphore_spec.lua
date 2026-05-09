describe('Semaphore', function()
  local Semaphore = require('nvim-treesitter.async.semaphore')
  local Promise = require('nvim-treesitter.async.future').Promise
  local pack_len = require('nvim-treesitter.async.future').pack_len

  local function resolved_values(future)
    local vals
    future:on_resolved(function(err, ...)
      vals = pack_len(err, ...)
    end)
    return vals
  end

  describe('new()', function()
    it('defaults to 1 permit', function()
      local sem = Semaphore.new()
      assert.is_equal(1, sem._permits)
    end)

    it('accepts custom permit count', function()
      local sem = Semaphore.new(3)
      assert.is_equal(3, sem._permits)
    end)
  end)

  describe('acquire()', function()
    it('returns resolved future when permit available', function()
      local sem = Semaphore.new(1)
      local f = sem:acquire()
      assert.is_true(f:is_resolved())
      local vals = resolved_values(f)
      assert.is_nil(vals[1])
      assert.is_true(vals[2])
    end)

    it('decrements permit count on immediate acquire', function()
      local sem = Semaphore.new(2)
      sem:acquire()
      assert.is_equal(1, sem._permits)
      sem:acquire()
      assert.is_equal(0, sem._permits)
    end)

    it('returns unresolved future when no permits', function()
      local sem = Semaphore.new(0)
      local f = sem:acquire()
      assert.is_false(f:is_resolved())
    end)

    it('queues waiter when no permits', function()
      local sem = Semaphore.new(0)
      local p = Promise.new()
      table.insert(sem._waiters, p)
      assert.is_equal(1, #sem._waiters)
    end)
  end)

  describe('release()', function()
    it('returns permit to pool when no waiters', function()
      local sem = Semaphore.new(1)
      sem._acquired = 1
      sem._permits = 0
      sem:release()
      assert.is_equal(1, sem._permits)
      assert.is_equal(0, sem._acquired)
    end)

    it('grants permit to next waiter (FIFO)', function()
      local sem = Semaphore.new(0)
      local p1 = Promise.new()
      local p2 = Promise.new()
      table.insert(sem._waiters, p1)
      table.insert(sem._waiters, p2)
      sem._acquired = 1
      sem._permits = 0
      local granted
      p1.future:on_resolved(function(err, v)
        granted = v
      end)
      local ok = pcall(function()
        sem:release()
      end)
      assert.is_true(ok)
      assert.is_true(granted)
    end)

    it('errors if release called without acquire', function()
      local sem = Semaphore.new(1)
      local ok, err = pcall(function()
        sem:release()
      end)
      assert.is_false(ok)
      assert.is_not_nil(err:match('Semaphore:release%(%) called without prior acquire'))
    end)

    it('errors if over-released', function()
      local sem = Semaphore.new(1)
      sem:acquire() -- _acquired=1
      sem:release() -- ok
      local ok, err = pcall(function()
        sem:release()
      end)
      assert.is_false(ok)
      assert.is_not_nil(err:match('Semaphore:release%(%) called without prior acquire'))
    end)
  end)

  describe('scoped()', function()
    it('returns a closeable table', function()
      local sem = Semaphore.new(1)
      local guard = sem:scoped()
      assert.is_table(guard)
      local mt = getmetatable(guard)
      assert.is_table(mt)
      assert.is_function(mt.__close)
    end)

    it('releases on scope exit', function()
      local sem = Semaphore.new(1)
      sem:acquire() -- _acquired=1, _permits=0
      local guard = sem:scoped()
      getmetatable(guard).__close(guard, nil)
      assert.is_equal(1, sem._permits)
      assert.is_equal(0, sem._acquired)
    end)
  end)
end)
