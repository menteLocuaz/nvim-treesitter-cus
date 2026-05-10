# Project Overview: nvim-treesitter

`nvim-treesitter` is a Neovim plugin that provides a high-level interface for working with [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) parsers and queries. It manages the installation and updating of parsers and provides a curated collection of queries for syntax highlighting, folding, indentation, and more.

## Architecture & Key Components

- **Parser Management (`lua/nvim-treesitter/parsers.lua`):** A central manifest of supported languages, their source repositories, revisions, and maintainers.
- **Queries (`runtime/queries/`):** Language-specific Scheme-like files that define how Tree-sitter nodes map to Neovim features:
    - `highlights.scm`: Syntax highlighting.
    - `injections.scm`: Multi-language support (e.g., JS inside HTML).
    - `folds.scm`: Code folding logic.
    - `indents.scm`: Auto-indentation (experimental).
- **Core Logic (`lua/nvim-treesitter/`):** Functions for downloading, compiling, and loading parsers.
- **Plugin Integration (`plugin/`):** Hooks into Neovim's filetype detection and Tree-sitter subsystem.
- **Automation (`scripts/`):** Scripts for documentation generation (`update-readme.lua`) and health checks (`check-parsers.lua`).

## Building and Running

This project uses a `Makefile` to manage development tasks and dependencies. Dependencies for testing and linting are automatically downloaded into `.test-deps/`.

### Key Commands

- `make all`: Runs all formatting, linting, and tests.
- `make lua`: Formats Lua code with `stylua` and checks it with `emmylua_check`.
- `make query`: Formats and lints Tree-sitter queries using `ts_query_ls`.
- `make checkquery`: Validates queries against installed parsers.
- `make tests`: Runs the test suite using `plentest.nvim` and `highlight-assertions`.
- `make docs`: Updates `SUPPORTED_LANGUAGES.md` based on the parser manifest.
- `make clean`: Removes the `.test-deps/` directory.

### Requirements

- Neovim nightly (0.12.0+)
- `tar`, `curl`, and a C compiler in your path.
- `tree-sitter-cli` (0.26.1+).

## Development Conventions

### Parser Inclusion
Parsers must meet specific criteria:
- Correspond to a Neovim-detected filetype.
- Be actively maintained and hosted on GitHub.
- Support the latest ABI if `src/parser.c` is provided.

### Query Standards
- **Formatting:** Use 2-space indentation. Each node should typically be on its own line. Run `make formatquery` before submitting changes.
- **Captures:** Only use valid Neovim captures (e.g., `@variable`, `@function.call`, `@keyword.repeat`). See `CONTRIBUTING.md` for the full list.
- **Inheritance:** Use `; inherits: <lang>` at the top of query files to extend base language queries.

### Testing
- Add new test cases to the `tests/` directory.
- Use `make tests` to verify changes.
- For highlighting issues, use `highlight-assertions` to verify capture assignments.

## Important Note on Indentation
Tree-sitter based indentation is currently **experimental** and defined in `indents.scm` queries. Use with caution.
