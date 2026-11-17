
-- plugin/nvim-treesitter.lua

if vim.g.loaded_nvim_treesitter then
  return
end
vim.g.loaded_nvim_treesitter = true

local api = vim.api

-- Helper function to avoid duplicating completion filtering logic.
--- @param arglead string
--- @param parsers string[]
--- @return string[]
local function filter_completions(arglead, parsers)
  if arglead == '' then
    return parsers
  end

  return vim.tbl_filter(function(v)
    -- Use startswith instead of find() to avoid bugs with special characters.
    return vim.startswith(v, arglead)
  end, parsers)
end

local function complete_available_parsers(arglead)
  local available = require('nvim-treesitter.config').get_available()
  return filter_completions(arglead, available)
end

local function complete_installed_parsers(arglead)
  local installed = require('nvim-treesitter.config').get_installed()
  return filter_completions(arglead, installed)
end

-- ======================================================================
-- User Commands (Lazy-loaded)
-- ======================================================================

api.nvim_create_user_command('TSInstall', function(args)
  require('nvim-treesitter.install').install(args.fargs, { force = args.bang, summary = true })
end, {
  nargs = '+',
  bang = true,
  bar = true,
  complete = complete_available_parsers,
  desc = 'Install Tree-sitter parsers',
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
  desc = 'Install Tree-sitter parsers from grammar',
})

api.nvim_create_user_command('TSUpdate', function(args)
  require('nvim-treesitter.install').update(args.fargs, { summary = true })
end, {
  nargs = '*',
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Update installed Tree-sitter parsers',
})

api.nvim_create_user_command('TSUninstall', function(args)
  require('nvim-treesitter.install').uninstall(args.fargs, { summary = true })
end, {
  nargs = '+',
  bar = true,
  complete = complete_installed_parsers,
  desc = 'Uninstall Tree-sitter parsers',
})

api.nvim_create_user_command('TSLog', function()
  require('nvim-treesitter.log').show()
end, {
  desc = 'View log messages',
})
