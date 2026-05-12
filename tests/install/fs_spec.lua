describe('install fs module', function()
  local a = require('nvim-treesitter.async')
  local M = require('nvim-treesitter.install.fs')
  local logger = require('nvim-treesitter.log').new('test/fs')

  local tmpdir

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
  end)

  after_each(function()
    vim.fn.delete(tmpdir, 'rf')
  end)

  describe('async wrapper exports', function()
    it('exports uv_copyfile', function()
      assert.is_function(M.uv_copyfile)
    end)

    it('exports uv_unlink', function()
      assert.is_function(M.uv_unlink)
    end)

    it('exports uv_rename', function()
      assert.is_function(M.uv_rename)
    end)

    it('exports uv_symlink', function()
      assert.is_function(M.uv_symlink)
    end)

    it('exports uv_mkdir', function()
      assert.is_function(M.uv_mkdir)
    end)

    it('exports uv_rmdir', function()
      assert.is_function(M.uv_rmdir)
    end)
  end)

  describe('mkpath', function()
    it('creates nested directories', function()
      local nested = vim.fs.joinpath(tmpdir, 'x', 'y', 'z')
      local err

      local task = a.arun(function()
        err = M.mkpath(nested, logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_not_nil(vim.uv.fs_stat(nested))
    end)

    it('succeeds on already-existing path', function()
      vim.fn.mkdir(vim.fs.joinpath(tmpdir, 'a', 'b'), 'p')
      local existing = vim.fs.joinpath(tmpdir, 'a', 'b')
      local err

      local task = a.arun(function()
        err = M.mkpath(existing, logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it('returns error for invalid path', function()
      local err

      local task = a.arun(function()
        err = M.mkpath('/dev/null/foo/bar', logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_not_nil(err)
      assert.is_string(err)
    end)
  end)

  describe('rmpath', function()
    it('removes a single file', function()
      local file = vim.fs.joinpath(tmpdir, 'test.txt')
      vim.fn.writefile({ 'hello' }, file)
      assert.is_not_nil(vim.uv.fs_stat(file))

      local err
      local task = a.arun(function()
        err = M.rmpath(file, logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_nil(vim.uv.fs_stat(file))
    end)

    it('removes a directory tree recursively', function()
      vim.fn.mkdir(vim.fs.joinpath(tmpdir, 'deep', 'nested'), 'p')
      vim.fn.writefile({ 'a' }, vim.fs.joinpath(tmpdir, 'deep', 'a.txt'))
      vim.fn.writefile({ 'b' }, vim.fs.joinpath(tmpdir, 'deep', 'nested', 'b.txt'))
      assert.is_not_nil(vim.uv.fs_stat(vim.fs.joinpath(tmpdir, 'deep', 'nested', 'b.txt')))

      local err
      local task = a.arun(function()
        err = M.rmpath(vim.fs.joinpath(tmpdir, 'deep'), logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(tmpdir, 'deep')))
    end)

    it('succeeds on non-existent path (idempotent)', function()
      local nonexistent = vim.fs.joinpath(tmpdir, 'does_not_exist')

      local err
      local task = a.arun(function()
        err = M.rmpath(nonexistent, logger)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe('async wrapper error propagation', function()
    it('uv_mkdir returns error for invalid path', function()
      local err
      local task = a.arun(function()
        err = M.uv_mkdir('/dev/null/foo', 493)
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_not_nil(err)
      assert.is_string(err)
    end)

    it('uv_unlink returns error for non-existent file', function()
      local err
      local task = a.arun(function()
        err = M.uv_unlink(vim.fs.joinpath(tmpdir, 'nope'))
      end)
      local ok = task:pwait(2000)
      assert.is_true(ok)
      assert.is_not_nil(err)
      assert.is_string(err)
    end)
  end)
end)
