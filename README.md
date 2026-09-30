# nvim config

Neovim config built on [LazyVim](https://github.com/LazyVim/LazyVim)
(`lua/config/lazy.lua`). Own plugin specs and overrides are in
`lua/plugins/*.lua`, own code in `lua/config/*.lua`. Most behavior comes from
LazyVim and its plugins, not from this repository — see `CLAUDE.md`
("Debugging") for where to look.

## Docs

| Topic | File |
| --- | --- |
| Debugging, verifying changes, conventions | [`CLAUDE.md`](CLAUDE.md) |
| MS SQL layer (connections, deploy, format, lint, ...) | [`docs/sql.md`](docs/sql.md) |
| Why the SQL layer is split the way it is | [`docs/sql-refactor.md`](docs/sql-refactor.md) |
| Keyboard layout switching | [`docs/keyboard.md`](docs/keyboard.md) |

Tests for the SQL layer: `tests/sql/` (run command in `CLAUDE.md`).
