local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local a = require('nvim-treesitter.async')
local config = require('nvim-treesitter.config')
local log = require('nvim-treesitter.log')
local parsers = require('nvim-treesitter.parsers')
local util = require('nvim-treesitter.util')

local system = require('nvim-treesitter.install.system')
local install_mod = require('nvim-treesitter.install.install')
local info_mod = require('nvim-treesitter.install.info')
local concurrency = require('nvim-treesitter.install.concurrency')

local M = {}

M.try_install_lang = install_mod.try_install_lang
M.install_lang = install_mod.install_lang
M.uninstall_lang = install_mod.uninstall_lang
M.join = system.join
M.is_installing = concurrency.is_installing

---@class InstallOptions
---@field force? boolean
---@field generate? boolean
---@field max_jobs? integer
---@field summary? boolean

local function reload_parsers()
  package.loaded['nvim-treesitter.parsers'] = nil
  ---@diagnostic disable-next-line:duplicate-require
  parsers = require('nvim-treesitter.parsers')
  vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
end

local function get_package_path(...)
  local info = assert(debug.getinfo(1, 'S'))
  return fs.joinpath(fn.fnamemodify(info.source:sub(2), ':p:h:h:h'), ...)
end

M.get_package_path = get_package_path

---@async
---@param languages string[]
---@param options? InstallOptions
---@return boolean
local function do_install(languages, options)
  options = options or {}

  local cache_dir = fs.normalize(fn.stdpath('cache') --[[@as string]])
  if not uv.fs_stat(cache_dir) then
    fn.mkdir(cache_dir, 'p')
  end

  local install_dir = config.get_install_dir('parser')

  local tasks = {} ---@type async.TaskFun[]
  local done = 0
  for _, lang in ipairs(languages) do
    tasks[#tasks + 1] = a.async(--[[@async]] function()
      a.schedule()
      local success =
        install_mod.install_lang(lang, cache_dir, install_dir, options.force, options.generate)
      if success then
        done = done + 1
      end
    end)
  end

  system.join(options.max_jobs or system.MAX_JOBS, tasks)
  if #tasks > 1 then
    a.schedule()
    if options and options.summary then
      log.info('Installed %d/%d languages', done, #tasks)
    end
  end
  return done == #tasks
end

M.install = a.async(function(languages, options)
  reload_parsers()
  languages = config.norm_languages(languages, { unsupported = true })
  return do_install(languages, options)
end)

M.update = a.async(function(languages, options)
  reload_parsers()
  if not languages or #languages == 0 then
    languages = 'all'
  end
  languages = config.norm_languages(languages, { missing = true, unsupported = true })
  local query_src = get_package_path('runtime', 'queries', 'dummy')

  local update_tasks = {}
  local to_update = {}
  for _, lang in ipairs(languages) do
    update_tasks[#update_tasks + 1] = a.async(function()
      if info_mod.needs_update(lang, query_src) then
        table.insert(to_update, lang)
      end
    end)
  end

  system.join(options.max_jobs or system.MAX_JOBS, update_tasks)
  languages = to_update

  local summary = options and options.summary
  if #languages > 0 then
    return do_install(languages, { force = true, summary = summary, max_jobs = options.max_jobs })
  else
    if options and options.summary then
      log.info('All parsers are up-to-date')
    end
    return true
  end
end)

M.uninstall = a.async(function(languages, options)
  vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
  languages = config.norm_languages(languages or 'all', { missing = true, dependencies = true })

  local parser_dir = config.get_install_dir('parser')
  local query_dir = config.get_install_dir('queries')
  local installed = config.get_installed()

  local tasks = {} ---@type async.TaskFun[]
  local done = 0
  for _, lang in ipairs(languages) do
    local logger = log.new('uninstall/' .. lang)
    if not vim.list_contains(installed, lang) then
      log.warn('Parser for ' .. lang .. ' is not managed by nvim-treesitter')
    else
      local parser = fs.joinpath(parser_dir, lang) .. '.so'
      local queries = fs.joinpath(query_dir, lang)
      tasks[#tasks + 1] = a.async(--[[@async]] function()
        local err = install_mod.uninstall_lang(logger, lang, parser, queries)
        if not err then
          done = done + 1
        end
      end)
    end
  end

  system.join(system.MAX_JOBS, tasks)
  if #tasks > 1 then
    a.schedule()
    if options and options.summary then
      log.info('Uninstalled %d/%d languages', done, #tasks)
    end
  end
end)

return M
