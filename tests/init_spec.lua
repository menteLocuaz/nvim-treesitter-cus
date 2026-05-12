describe('init module', function()
  local nvim_treesitter = require('nvim-treesitter')

  before_each(function()
    -- Clear internal caches if possible, or reload the module
    package.loaded['nvim-treesitter'] = nil
    nvim_treesitter = require('nvim-treesitter')
  end)

  it('proxies config functions', function()
    local config_mock = {
      setup = function() return 'setup_called' end,
      get_available = function() return 'get_available_called' end,
      get_installed = function() return 'get_installed_called' end,
    }
    package.loaded['nvim-treesitter.config'] = config_mock

    assert.are.equal('setup_called', nvim_treesitter.setup())
    assert.are.equal('get_available_called', nvim_treesitter.get_available())
    assert.are.equal('get_installed_called', nvim_treesitter.get_installed())
  end)

  it('proxies install functions', function()
    local install_mock = {
      install = function() return 'install_called' end,
      uninstall = function() return 'uninstall_called' end,
      update = function() return 'update_called' end,
    }
    package.loaded['nvim-treesitter.install'] = install_mock

    assert.are.equal('install_called', nvim_treesitter.install())
    assert.are.equal('uninstall_called', nvim_treesitter.uninstall())
    assert.are.equal('update_called', nvim_treesitter.update())
  end)

  it('indentexpr calls indent.get_indent', function()
    local indent_mock = {
      get_indent = function(lnum) return lnum * 2 end,
    }
    package.loaded['nvim-treesitter.indent'] = indent_mock
    vim.v.lnum = 10

    assert.are.equal(20, nvim_treesitter.indentexpr())
  end)

  it('indentexpr returns -1 if indent module fails to load', function()
    -- Temporarily break require for nvim-treesitter.indent
    local old_indent = package.loaded['nvim-treesitter.indent']
    package.loaded['nvim-treesitter.indent'] = nil
    
    -- We need to mock require to fail for this specific module
    local old_require = _G.require
    _G.require = function(mod)
      if mod == 'nvim-treesitter.indent' then
        error('module not found')
      end
      return old_require(mod)
    end

    assert.are.equal(-1, nvim_treesitter.indentexpr())

    -- Restore
    _G.require = old_require
    package.loaded['nvim-treesitter.indent'] = old_indent
  end)
end)
