describe('Future and Promise', function()
  local Future = require('nvim-treesitter.async.future').Future
  local Promise = require('nvim-treesitter.async.future').Promise
  local pack_len = require('nvim-treesitter.async.future').pack_len
  local unpack_len = require('nvim-treesitter.async.future').unpack_len

  describe('Future', function()
    describe('new()', function()
      it('creates an unresolved future', function()
        local f = Future.new()
        assert.is_false(f:is_resolved())
      end)
    end)

    describe('new_resolved()', function()
      it('creates a resolved future with value', function()
        local f = Future.new_resolved(nil, pack_len(42, 'hello'))
        assert.is_true(f:is_resolved())
      end)

      it('creates a rejected future with error', function()
        local f = Future.new_resolved('oops', nil)
        assert.is_true(f:is_resolved())
      end)

      it('calls callback immediately if already resolved', function()
        local f = Future.new_resolved(nil, pack_len('val'))
        local called = false
        f:on_resolved(function(err, v)
          called = true
          assert.is_nil(err)
          assert.is_equal('val', v)
        end)
        assert.is_true(called)
      end)
    end)

    describe('on_resolved()', function()
      it('queues callback when unresolved', function()
        local f = Future.new()
        local called = false
        f:on_resolved(function()
          called = true
        end)
        assert.is_false(called)
        f:_complete(nil, pack_len('x'))
        assert.is_true(called)
      end)

      it('receives err=nil and values on resolve', function()
        local f = Future.new()
        local err_val, a, b
        f:on_resolved(function(err, x, y)
          err_val, a, b = err, x, y
        end)
        f:_complete(nil, pack_len('first', 'second'))
        assert.is_nil(err_val)
        assert.is_equal('first', a)
        assert.is_equal('second', b)
      end)

      it('receives err and no values on reject', function()
        local f = Future.new()
        local err_val
        f:on_resolved(function(err)
          err_val = err
        end)
        f:_complete('error', nil)
        assert.is_equal('error', err_val)
      end)

      it('resolves with zero arguments', function()
        local f = Future.new()
        local called = false
        f:on_resolved(function(err)
          called = true
          assert.is_nil(err)
        end)
        f:_complete(nil, pack_len())
        assert.is_true(called)
      end)

      it('resolves with trailing nil', function()
        local f = Future.new()
        local vals
        f:on_resolved(function(err, ...)
          vals = pack_len(...)
        end)
        f:_complete(nil, pack_len(1, nil, 3))
        assert.is_equal(3, vals.n)
        assert.is_equal(1, vals[1])
        assert.is_nil(vals[2])
        assert.is_equal(3, vals[3])
      end)

      it('is idempotent — second _complete returns false', function()
        local f = Future.new()
        local called = 0
        f:on_resolved(function()
          called = called + 1
        end)
        local r1 = f:_complete(nil, pack_len('first'))
        local r2 = f:_complete(nil, pack_len('second'))
        local r3 = f:_complete('ignored', nil)
        assert.is_true(r1)
        assert.is_false(r2)
        assert.is_false(r3)
        assert.is_equal(1, called)
      end)
    end)

    describe('is_resolved()', function()
      it('returns false before resolution', function()
        assert.is_false(Future.new():is_resolved())
      end)

      it('returns true after resolve', function()
        local f = Future.new()
        f:_complete(nil, pack_len(1))
        assert.is_true(f:is_resolved())
      end)

      it('returns true after reject', function()
        local f = Future.new()
        f:_complete('err', nil)
        assert.is_true(f:is_resolved())
      end)
    end)
  end)

  describe('Promise', function()
    describe('resolve()', function()
      it('resolves the attached future', function()
        local p = Promise.new()
        assert.is_false(p.future:is_resolved())
        p:resolve(42)
        assert.is_true(p.future:is_resolved())
      end)

      it('passes values to on_resolved callback', function()
        local p = Promise.new()
        local a, b
        p.future:on_resolved(function(err, x, y)
          a, b = x, y
        end)
        p:resolve('foo', 'bar')
        assert.is_equal('foo', a)
        assert.is_equal('bar', b)
      end)

      it('resolves with zero arguments', function()
        local p = Promise.new()
        local called = false
        p.future:on_resolved(function(err)
          called = true
          assert.is_nil(err)
        end)
        p:resolve()
        assert.is_true(called)
      end)

      it('is idempotent — second resolve is ignored', function()
        local p = Promise.new()
        local vals
        p.future:on_resolved(function(err, ...)
          vals = pack_len(...)
        end)
        p:resolve('first')
        p:resolve('second')
        assert.is_equal(1, vals.n)
        assert.is_equal('first', vals[1])
      end)
    end)

    describe('reject()', function()
      it('rejects the attached future', function()
        local p = Promise.new()
        p:reject('boom')
        assert.is_true(p.future:is_resolved())
      end)

      it('passes error to on_resolved callback', function()
        local p = Promise.new()
        local err_val
        p.future:on_resolved(function(err)
          err_val = err
        end)
        p:reject('failure')
        assert.is_equal('failure', err_val)
      end)

      it('rejects after resolve is ignored', function()
        local p = Promise.new()
        p:resolve('ok')
        p:reject('ignored')
        local err_val
        p.future:on_resolved(function(err)
          err_val = err
        end)
        assert.is_nil(err_val)
      end)

      it('resolve after reject is ignored', function()
        local p = Promise.new()
        p:reject('oops')
        p:resolve('ok')
        local err_val
        p.future:on_resolved(function(err)
          err_val = err
        end)
        assert.is_equal('oops', err_val)
      end)
    end)
  end)

  describe('pack_len / unpack_len', function()
    it('pack_len preserves count with trailing nils', function()
      local t = pack_len(1, nil, 3)
      assert.is_equal(3, t.n)
      assert.is_equal(1, t[1])
      assert.is_nil(t[2])
      assert.is_equal(3, t[3])
    end)

    it('unpack_len restores values including trailing nils', function()
      local t = pack_len(1, nil, 3)
      local a, b, c = unpack_len(t)
      assert.is_equal(1, a)
      assert.is_nil(b)
      assert.is_equal(3, c)
    end)

    it('unpack_len returns nothing for nil table', function()
      local a, b = unpack_len(nil)
      assert.is_nil(a)
      assert.is_nil(b)
    end)

    it('unpack_len with first offset', function()
      local t = pack_len(1, 2, 3)
      local a, b = unpack_len(t, 2)
      assert.is_equal(2, a)
      assert.is_equal(3, b)
    end)
  end)
end)
