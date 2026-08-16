describe('parsers registry', function()
  local parsers = require('nvim-treesitter.parsers')

  it('returns parser info for known languages', function()
    assert.is_table(parsers.lua)
    assert.is_table(parsers.c)
  end)

  it('returns nil for unknown languages (no stack overflow)', function()
    -- Regression: __index used to recurse infinitely on missing keys
    assert.is_nil(parsers.not_a_real_language)
    assert.is_nil(parsers[''])
  end)

  it('get_available loads the full manifest', function()
    local available = require('nvim-treesitter.config').get_available()
    assert.is_true(#available > 100)
    assert.is_true(vim.list_contains(available, 'lua'))
  end)

  it('norm_languages skips unknown languages', function()
    local langs = require('nvim-treesitter.config').norm_languages(
      { 'not_a_real_language', 'lua' },
      { unsupported = true }
    )
    assert.are.same({ 'lua' }, langs)
  end)
end)
