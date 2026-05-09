describe('Channel', function()
  local Channel = require('nvim-treesitter.async.channel')
  local Promise = require('nvim-treesitter.async.future').Promise
  local pack_len = require('nvim-treesitter.async.future').pack_len

  local function resolved_values(future)
    local vals
    future:on_resolved(function(err, ...)
      vals = pack_len(err, ...)
    end)
    return vals
  end

  describe('send / recv', function()
    it('recv returns value when queue has items', function()
      local ch = Channel.new()
      ch:send('hello')
      local vals = resolved_values(ch:recv())
      assert.is_nil(vals[1])
      assert.is_equal('hello', vals[2])
    end)

    it('send unblocks pending recv', function()
      local ch = Channel.new()
      local p = Promise.new()
      p.future:on_resolved(function(err, v)
        p._test_val = v
      end)
      table.insert(ch._waiters, p)
      ch:send('unblock')
      assert.is_equal('unblock', p._test_val)
    end)

    it('multiple sends drain in order', function()
      local ch = Channel.new()
      ch:send('first')
      ch:send('second')
      local r1 = resolved_values(ch:recv())
      local r2 = resolved_values(ch:recv())
      assert.is_equal('first', r1[2])
      assert.is_equal('second', r2[2])
    end)
  end)

  describe('close()', function()
    it('reject closes pending waiters', function()
      local ch = Channel.new()
      local p1 = Promise.new()
      local p2 = Promise.new()
      table.insert(ch._waiters, p1)
      table.insert(ch._waiters, p2)
      ch:close()
      local err1, err2
      p1.future:on_resolved(function(err)
        err1 = err
      end)
      p2.future:on_resolved(function(err)
        err2 = err
      end)
      assert.is_equal('channel closed', err1)
      assert.is_equal('channel closed', err2)
    end)

    it('recv on closed channel returns rejected future', function()
      local ch = Channel.new()
      ch:close()
      local vals = resolved_values(ch:recv())
      assert.is_equal('channel closed', vals[1])
    end)

    it('send on closed channel raises error', function()
      local ch = Channel.new()
      ch:close()
      local ok, err = pcall(function()
        ch:send('oops')
      end)
      assert.is_false(ok)
      assert.is_not_nil(err:match('send on closed channel'))
    end)

    it('clear waiters after close', function()
      local ch = Channel.new()
      local p = Promise.new()
      table.insert(ch._waiters, p)
      ch:close()
      assert.is_equal(0, #ch._waiters)
    end)
  end)
end)
