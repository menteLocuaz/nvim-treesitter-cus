describe('config paths module', function()
  local paths = require('nvim-treesitter.config.paths')

  before_each(function()
    paths.invalidate_cache()
  end)

  it('returns copies, not the cached table', function()
    -- Regression: mutating the result used to corrupt the cache
    local first = paths.get_installed()
    first[#first + 1] = 'bogus_language'
    local second = paths.get_installed()
    assert.is_false(vim.list_contains(second, 'bogus_language'))
  end)

  it('caches results until invalidated', function()
    local first = paths.get_installed()
    local second = paths.get_installed()
    assert.are.same(first, second)
    paths.invalidate_cache()
    local third = paths.get_installed()
    assert.are.same(first, third)
  end)
end)
