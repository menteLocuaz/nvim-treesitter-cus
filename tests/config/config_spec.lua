local config = require('nvim-treesitter.config')

describe('config.norm_languages', function()
  local original_parsers

  before_each(function()
    original_parsers = package.loaded['nvim-treesitter.parsers']
    package.loaded['nvim-treesitter.parsers'] = {
      root = { requires = { 'middle' }, tier = 1 },
      middle = { requires = { 'leaf', 'shared' }, tier = 1 },
      leaf = { requires = { 'shared' }, tier = 1 },
      shared = { tier = 1 },
      cyclic_a = { requires = { 'cyclic_b' }, tier = 1 },
      cyclic_b = { requires = { 'cyclic_a' }, tier = 1 },
    }
  end)

  after_each(function()
    package.loaded['nvim-treesitter.parsers'] = original_parsers
  end)

  it('includes transitive dependencies without duplicates', function()
    assert.are.same({ 'root', 'middle', 'leaf', 'shared' }, config.norm_languages('root'))
  end)

  it('handles circular dependencies', function()
    assert.are.same({ 'cyclic_a', 'cyclic_b' }, config.norm_languages('cyclic_a'))
  end)

  it('omits dependencies when requested', function()
    assert.are.same({ 'root' }, config.norm_languages('root', { dependencies = true }))
  end)
end)
