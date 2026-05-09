describe('CancellationToken', function()
  local CancellationToken = require('nvim-treesitter.async.cancellation')

  describe('new()', function()
    it('creates uncancelled token', function()
      local ct = CancellationToken.new()
      assert.is_false(ct:is_cancelled())
    end)
  end)

  describe('cancel()', function()
    it('marks token as cancelled', function()
      local ct = CancellationToken.new()
      ct:cancel()
      assert.is_true(ct:is_cancelled())
    end)

    it('executes registered callbacks via scheduler', function()
      local ct = CancellationToken.new()
      local called = false
      ct:on_cancelled(function()
        called = true
      end)
      ct:cancel()
      assert.is_true(called)
    end)

    it('clears callbacks after execution (no memory leak)', function()
      local ct = CancellationToken.new()
      local called = 0
      ct:on_cancelled(function()
        called = called + 1
      end)
      ct:cancel()
      local r = ct:cancel()
      assert.is_nil(r)
      assert.is_equal(1, called)
    end)

    it('is idempotent — second cancel does nothing', function()
      local ct = CancellationToken.new()
      local called = 0
      ct:on_cancelled(function()
        called = called + 1
      end)
      ct:cancel()
      ct:cancel()
      assert.is_equal(1, called)
    end)

    it('executes callback registered after cancel (sync)', function()
      local ct = CancellationToken.new()
      ct:cancel()
      local called = false
      ct:on_cancelled(function()
        called = true
      end)
      assert.is_true(called)
    end)
  end)

  describe('on_cancelled()', function()
    it('registers callback for future cancel', function()
      local ct = CancellationToken.new()
      local called = false
      ct:on_cancelled(function()
        called = true
      end)
      assert.is_false(called)
      ct:cancel()
      assert.is_true(called)
    end)

    it('registers multiple callbacks', function()
      local ct = CancellationToken.new()
      local count = 0
      ct:on_cancelled(function()
        count = count + 1
      end)
      ct:on_cancelled(function()
        count = count + 1
      end)
      ct:cancel()
      assert.is_equal(2, count)
    end)
  end)

  describe('is_cancelled()', function()
    it('returns false initially', function()
      local ct = CancellationToken.new()
      assert.is_false(ct:is_cancelled())
    end)

    it('returns true after cancel', function()
      local ct = CancellationToken.new()
      ct:cancel()
      assert.is_true(ct:is_cancelled())
    end)
  end)
end)
