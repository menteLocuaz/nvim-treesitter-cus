if vim.g.loaded_nvim_treesitter then
  return
end
vim.g.loaded_nvim_treesitter = true

local api = vim.api

local function complete_available_parsers(arglead)
  return vim.tbl_filter(
    --- @param v string
    function(v)
      return v:find(arglead) ~= nil
    end,
    require('nvim-treesitter.config').get_available()
  )
end

local function complete_installed_parsers(arglead)
  return vim.tbl_filter(
    --- @param v string
    function(v)
      return v:find(arglead) ~= nil
    end,
    require('nvim-treesitter.config').get_installed()
  )
end

-- create user commands
api.nvim_create_user_command('TSInstall', function(args)
  require('nvim-treesitter.install').install(args.fargs, { force = args.bang, summary = true })
end, {
  nargs = '+',
  bang = true,
  bar = true,
  complete = complete_available_parsers,
  desc = 'Install treesitter parsers',
})

api.nvim_create_user_command('TSInstallFromGrammar', function(args)
  require('nvim-treesitter.install').install(args.fargs, {
    generate = true,
    summary = true,
    force = args.bang,
  })
end, {
  nargs = '+',
  bang = true,
  bar = true,
  complete = complete_available_parsers,
  desc = 'Install treesitter parsers from grammar',
})

api.nvim_create_user_command('TSUpdate', function(args)
  require('nvim-treesitter.install').update(args.fargs, { summary = true })
end, {
  nargs = '*',
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Update installed treesitter parsers',
})

api.nvim_create_user_command('TSUninstall', function(args)
  require('nvim-treesitter.install').uninstall(args.fargs, { summary = true })
end, {
  nargs = '+',
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Uninstall treesitter parsers',
})

api.nvim_create_user_command('TSLog', function()
  require('nvim-treesitter.log').show()
end, {
  desc = 'View log messages',
})

api.nvim_create_user_command('TSHealthInfo', function()
  local checks = require('nvim-treesitter.health.checks')
  local config = require('nvim-treesitter.config')

  local info = {
    '=== nvim-treesitter health (verbose) ===',
    'Minimum ABI: ' .. checks.NVIM_TREESITTER_MINIMUM_ABI,
    'Tree-sitter min version: ' .. vim.inspect(checks.TREE_SITTER_MIN_VER),
    'Install dir: ' .. config.get_install_dir(''),
    'Configured languages: ' .. #config.get_available(),
    'Installed languages: ' .. #config.get_installed(),
  }

  local ts = checks.check_exe('tree-sitter')
  if ts then
    table.insert(info, 'tree-sitter-cli: ' .. (ts.version and tostring(ts.version) or 'unknown'))
  end

  vim.list_extend(info, { '', '=== Installed parsers ===' })
  for _, lang in ipairs(config.get_installed()) do
    table.insert(info, '  ' .. lang)
  end

  api.nvim_echo({ { table.concat(info, '\n'), 'Normal' } }, false, {})
end, {
  desc = 'Display detailed health info',
})
