local helpers = require('tests.helpers')
local config = require('nvim-treesitter.config')
local constants = require('nvim-treesitter.constants')
local parsers = require('nvim-treesitter.parsers')

describe('Performance and Organization Improvements', function()
  it('should have centralized constants', function()
    assert.are.same({ 'stable', 'unstable', 'unmaintained', 'unsupported' }, constants.TIERS)
    assert.is.number(constants.MAX_JOBS)
  end)

  it('should have a configurable max_jobs', function()
    local default_max = config.get_max_jobs()
    assert.is.number(default_max)

    config.setup({ max_jobs = 5 })
    assert.equal(5, config.get_max_jobs())

    -- Restore default
    config.setup({ max_jobs = constants.MAX_JOBS })
  end)

  it('should load parsers via manifest with pre-populated metadata', function()
    -- Check if manifest exists
    local ok, manifest = pcall(require, 'nvim-treesitter.parsers.manifest')
    assert.True(ok, 'Manifest should exist and be readable')

    -- Check a known parser (e.g., lua)
    local lua_parser = parsers.lua
    assert.is_table(lua_parser)
    assert.equal(2, lua_parser.tier)
    assert.is_table(lua_parser.maintainers)

    -- Verify that accessing a non-pre-populated field triggers lazy loading
    -- 'install_info' is typically NOT in the manifest metadata we added
    assert.is_nil(rawget(lua_parser, 'install_info'))
    local install_info = lua_parser.install_info
    assert.is_table(install_info)
    assert.is_string(install_info.url)
    -- Now it should be in the table
    assert.is_table(rawget(lua_parser, 'install_info'))
  end)

  it('should filter available parsers by tier efficiently', function()
    local stable = config.get_available(1)
    local unstable = config.get_available(2)

    assert.is_table(stable)
    assert.is_table(unstable)

    -- Ensure some results are found (based on the project state)
    assert.True(#unstable > 0)

    -- Check that lua is in unstable (tier 2)
    local found_lua = false
    for _, lang in ipairs(unstable) do
      if lang == 'lua' then
        found_lua = true
        break
      end
    end
    assert.True(found_lua, 'Lua should be in unstable tier')
  end)
end)
