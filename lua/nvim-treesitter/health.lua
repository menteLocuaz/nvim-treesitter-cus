-- nvim-treesitter.health
-- Entry point for Neovim's built-in health check system (:checkhealth nvim-treesitter).
--
-- When the user runs :checkhealth nvim-treesitter, Neovim automatically calls
-- M.check() from this module. The function orchestrates a full diagnostic pass:
--
--   1. install_health  – Checks that the Treesitter C library and compiler are available.
--   2. check_install_dir – Verifies the parser installation directory is writable.
--   3. render_languages  – Reports the status of every installed language parser.
--   4. collect / collect_query_errors – Gathers parser and query file errors.
--   5. render_errors     – Displays all collected errors in the health report UI.

local parsers = require('nvim-treesitter.parsers')
local config = require('nvim-treesitter.config')

local checks = require('nvim-treesitter.health.checks')
local report = require('nvim-treesitter.health.report')
local constants = require('nvim-treesitter.health.constants')
local render = require('nvim-treesitter.health.render')

local M = {}

--- Runs the full nvim-treesitter health check.
--- Called automatically by Neovim when the user executes:
---   :checkhealth nvim-treesitter
---
--- Steps (in order):
---   1. checks.install_health()
---        Verifies the Treesitter C library is loadable and that a C compiler
---        (cc / gcc / clang / cl) is available on PATH for building parsers.
---
---   2. checks.check_install_dir()
---        Confirms the parser installation directory exists and is writable.
---        Reports a warning if parsers would be installed to a read-only path.
---
---   3. render.render_languages(languages, parsers, BUNDLED_QUERIES)
---        Iterates over all installed languages (sorted alphabetically) and
---        reports the status of each: parser version, ABI compatibility, and
---        which bundled query files (highlights, indents, folds, etc.) are present.
---
---   4. report.collect(languages, parsers)
---        Collects parser-level errors (e.g., ABI mismatch, missing shared library)
---        for all installed languages.
---
---   5. report.collect_query_errors(languages, parsers)
---        Collects query-level errors (e.g., invalid .scm syntax, missing nodes)
---        for all installed languages. Results are merged into the same error list.
---
---   6. render.render_errors(errors)
---        Displays all collected errors as health report ERROR entries so the
---        user can see exactly which parsers or queries need attention.
function M.check()
  -- Step 1 & 2: environment and installation directory checks.
  checks.install_health()
  checks.check_install_dir()

  -- Retrieve and sort the list of installed language names alphabetically
  -- so the health report output is stable and easy to scan.
  local languages = config.get_installed()
  table.sort(languages)

  -- Step 3: render per-language parser and query file status.
  render.render_languages(languages, parsers, constants.BUNDLED_QUERIES, report.query_status)

  -- Steps 4 & 5: collect parser errors and query errors, then merge them
  -- into a single list so they can be rendered together.
  local errors = report.collect(languages, parsers)
  local query_errors = report.collect_query_errors(languages, parsers)

  vim.list_extend(errors, query_errors)

  -- Step 6: render all collected errors as health report ERROR entries.
  render.render_errors(errors)
end

-- Re-export the bundled query names so external modules (e.g., tests or
-- other health check extensions) can reference the canonical list without
-- importing nvim-treesitter.health.constants directly.
M.bundled_queries = constants.BUNDLED_QUERIES

return M
