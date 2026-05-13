<h1 align="center">
  <img src="https://github.com/nvim-treesitter/nvim-treesitter/assets/2361214/0513b223-c902-4f12-92ee-8ac4d8d6f41f" alt="nvim-treesitter">
</h1>

A plugin that installs tree-sitter parsers and provides queries for Neovim's
built-in tree-sitter features.

> [!CAUTION]
> This is a full, incompatible, rewrite: Treat this as a different plugin you
> need to set up from scratch following the instructions below. If you can't
> or don't want to update, specify the
> [`master` branch](https://github.com/nvim-treesitter/nvim-treesitter/blob/master/README.md)
> (which is locked but will remain available for backward compatibility with
> Nvim 0.11).

---

## What is nvim-treesitter?

Neovim has built-in tree-sitter support (`vim.treesitter`) — it can parse
buffers and apply queries for highlighting, folding, and more. But Neovim
does not ship parsers or query files for any language.

nvim-treesitter fills that gap by:

- maintaining a registry of parser sources with pinned revisions
- downloading and compiling parsers on demand
- shipping query files (highlighting, folds, indentation, injections) for
  each supported language
- providing commands to install, update, and remove everything

See [SUPPORTED_LANGUAGES.md](SUPPORTED_LANGUAGES.md) for the full language
list.

---

## Getting started

### Requirements

- Neovim **0.12.0 or later** (nightly)
- `tar` and `curl` in your PATH
- [`tree-sitter-cli`](https://github.com/tree-sitter/tree-sitter/blob/master/crates/cli/README.md)
  **0.26.1 or later** (installed via your package manager, **not npm**)
- a C compiler in your PATH
  (see <https://docs.rs/cc/latest/cc/#compile-time-requirements>)

> [!IMPORTANT]
> Support policy: the latest Neovim
> [stable release](https://github.com/neovim/neovim/releases/tag/stable) and
> the latest [nightly](https://github.com/neovim/neovim/releases/tag/nightly).
> Other versions may work but are not tested.

### 1. Install the plugin

Add nvim-treesitter to your plugin manager. Example with
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'nvim-treesitter/nvim-treesitter',
  lazy = false,
  build = ':TSUpdate'
}
```

> [!IMPORTANT]
> This plugin does not support lazy-loading.

When you upgrade the plugin, always run `:TSUpdate` afterwards to keep
parsers in sync.

### 2. Call setup (optional)

You only need `setup` if you want a non-default install directory:

```lua
require('nvim-treesitter').setup {
  install_dir = vim.fn.stdpath('data') .. '/site'
}
```

With no arguments the defaults are fine.

### 3. Install parsers for your languages

```lua
require('nvim-treesitter').install { 'rust', 'javascript', 'zig' }
```

Or from the command line:

```
:TSInstall rust javascript zig
```

This downloads, compiles, and installs each parser. It is a no-op if a
parser is already installed. Append `!` to force a reinstall (`:TSInstall!`).

Installation runs asynchronously. To wait for completion (e.g. in a
bootstrap script):

```lua
require('nvim-treesitter').install({ 'rust', 'javascript', 'zig' })
                          :wait(300000) -- max 5 minutes
```

### 4. Verify

```
:checkhealth nvim-treesitter
```

---

## How to enable features

Features are **not enabled automatically**. You must opt in per file type.

### Highlighting

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'rust', 'javascript', 'zig' },
  callback = function() vim.treesitter.start() end,
})
```

See `:h treesitter-highlight`.

### Folds

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'rust', 'javascript', 'zig' },
  callback = function()
    vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
    vim.wo.foldmethod = 'expr'
  end,
})
```

### Indentation (experimental)

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'rust', 'javascript', 'zig' },
  callback = function()
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end,
})
```

For details on writing custom indent queries, see
[docs/indent-node.md](docs/indent-node.md).

### Injections

No setup required. Tree-sitter handles multi-language files (e.g. JavaScript
inside HTML) automatically. See `:h treesitter-language-injections`.

---

## Advanced: adding custom languages

If your language's parser is not in the
[supported list](SUPPORTED_LANGUAGES.md), you can register it manually inside
a `User TSUpdate` autocommand:

```lua
vim.api.nvim_create_autocmd('User', { pattern = 'TSUpdate',
callback = function()
  require('nvim-treesitter.parsers').zimbu = {
    install_info = {
      url = 'https://github.com/zimbulang/tree-sitter-zimbu',
      revision = '<sha>',
      -- optional fields:
      branch = 'develop',
      location = 'parser',
      generate = true,
      generate_from_json = false,
      queries = 'queries/neovim',
    },
    maintainers = { '@me' },
    tier = 2,
  }
end})
```

For a local checkout, use `path` instead of `url`:

```lua
    install_info = {
      path = '~/parsers/tree-sitter-zimbu',
      location = 'parser',
      generate = true,
      ...
    },
```

Then register the parser name if it differs from the filetype:

```lua
vim.treesitter.language.register('zimbu', { 'zu' })
```

Finally, run `:TSInstall zimbu`.

> [!IMPORTANT]
> If the parser requires an external scanner, it must be written in C.

### Modifying an existing parser's settings

To always generate the `lua` parser from grammar instead of using its
pre-built `parser.c`:

```lua
vim.api.nvim_create_autocmd('User', { pattern = 'TSUpdate',
callback = function()
  require('nvim-treesitter.parsers').lua.install_info.generate = true
end})
```

### Adding custom queries

Place your query files under `queries/<language>/` anywhere in your
`runtimepath`. Earlier directories take precedence unless the query file
begins with `; extends`. See
[`:h treesitter-query-modelines`](https://neovim.io/doc/user/treesitter.html#treesitter-query-modeline).

---

## Reference

- [`:h nvim-treesitter-commands`](doc/nvim-treesitter.txt) — full command
  and API reference
- [SUPPORTED_LANGUAGES.md](SUPPORTED_LANGUAGES.md) — language support table
- [CONTRIBUTING.md](./CONTRIBUTING.md) — how to add languages or improve
  queries
- [docs/indent-node.md](docs/indent-node.md) — indent query internals
