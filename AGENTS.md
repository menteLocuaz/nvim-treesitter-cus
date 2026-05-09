# Agent Guidelines for nvim-treesitter

## Repo structure

- `lua/nvim-treesitter/` — Lua source (this is the plugin code)
- `lua/nvim-treesitter/install/` — Modular install subsystem (fs, system, download, compile, concurrency, info, install)
- `runtime/queries/` — Tree-sitter query files (`.scm`), one directory per language
- `lua/nvim-treesitter/parsers.lua` — Parser registry (source of truth for supported languages)
- `plugin/` — Neovim plugin commands (TSInstall, TSUpdate, TSUninstall, TSLog)
- `scripts/` — Utility scripts for checking parsers, queries, and updating README

## Build & check commands

```bash
# Download all dev dependencies (nvim, stylua, emmylua_check, ts_query_ls, etc.)
make
# or specific ones:
make nvim stylua emmyluals  # lua tools

# Lint + format Lua
make lua                    # -> make formatlua checklua

# Lint + format + check queries
make query                  # -> make lintquery formatquery checkquery

# Run tests
make tests                  # needs TESTS=... var, e.g. TESTS=install make tests

# Update README / supported languages list
make docs
```

**Order matters:** `make lua` runs `formatlua` then `checklua`; `make all` runs `lua query docs tests`.

## Adding a new parser

1. Add entry to `lua/nvim-treesitter/parsers.lua` (tier, url, revision, optional: branch, location, generate)
2. If filetype differs from parser name, add to `plugin/filetypes.lua`
3. Run `make docs` to update the supported languages list
4. Test: `:TSInstall <lang>` and `:TSInstallFromGrammar <lang>`; also `make checkquery` (requires parser installed)

## Adding/editing queries

- Create `runtime/queries/<lang>/highlights.scm` etc.
- Valid captures for Neovim differ from other editors — always run `make lintquery` before submitting
- Query format: one node per line, 2-space indentation per nesting level, auto-format with `make formatquery`
- First line can be `; inherits: lang1,(optionallang)` for inheriting base language queries
- Use `; format-ignore` before a node to preserve specific formatting

## Lua module conventions

- Modules use `local M = {}` at top; functions attached to `M`
- Async functions wrapped via `a.async(...)` from `nvim-treesitter.async`
- All UV async operations use `a.awrap(n, fn)` wrappers
- `config.lua` is the single config entry point; `log.lua` for logging
- The `install/` subdirectory is the modular refactor of the former `install.lua`; use `require('nvim-treesitter.install')` (auto-loads `init.lua`)

## Key constraints

- Neovim 0.12+ required (ABI 13+)
- `tree-sitter-cli` must be installed **via package manager, not npm** (min version 0.26.1)
- `tar` and `curl` must be in PATH
- `make checkquery` requires the parser installed via `nvim-treesitter` (not just available)
- This plugin **does not support lazy-loading**
- External scanners must be written in C99