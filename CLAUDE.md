# CLAUDE.md

Neovim config built on **LazyVim** (`lua/config/lazy.lua`:
`import = "lazyvim.plugins"`). Own plugin specs and overrides live in
`lua/plugins/*.lua`, own code in `lua/config/*.lua`.

## Debugging: read this first

**Most behavior comes from LazyVim and its plugins, not from this
repository.** Grepping `lua/` often will not find the source of a keymap or
option — look in the installed plugins instead:
`C:\Users\<user>\AppData\Local\nvim-data\lazy\`, primarily
`LazyVim/lua/lazyvim/plugins/` and `snacks.nvim/lua/snacks/`. Neovim's own
runtime is in `C:\Program Files\Neovim\share\nvim\runtime\lua\vim\`.

Worked example: LazyVim defines LSP keymaps in
`lazyvim/plugins/lsp/init.lua` (`servers["*"].keys`) and applies them
through `Snacks.keymap.set` with an `lsp` filter — where `on_lsp` is wrapped
in a **100ms debounce** after `LspAttach`. You cannot win that race with your
own mapping, not even from an `LspAttach` autocmd using `vim.schedule` or
`vim.defer_fn` — LazyVim always applies last. The correct fix is to override
the entry in `servers["*"].keys` itself (`has = ...`,
`enabled = function(buf)`); see `lua/plugins/dadbod.lua`.

Second: edits to `lua/config/*.lua` **do not take effect without restarting
nvim** — modules are cached by `require`, and `setup()` runs once at startup.

Syntax-check a file without starting the UI:

```bash
"/c/Program Files/Neovim/bin/nvim.exe" --headless \
  -c "lua print(loadfile('lua/config/sqlobject.lua') ~= nil)" -c "qa"
```

## Custom MS SQL layer

Not a plugin — own code on top of vim-dadbod, wired up from
`lua/plugins/dadbod.lua`:

- `lua/config/sqlconn.lua` — shared part: picking connection and database,
  running `sqlcmd`.
- `lua/config/sqldeploy.lua` — `:SqlDeploy` (`<leader>dd`): deploy the
  current `.sql` file.
- `lua/config/sqlobject.lua` — `:SqlDef` (`K`), `:SqlRows` (`<leader>dr`),
  `:SqlEnum` (`<leader>de`): inspect an object in the database. Replaces what
  SQLTools used to do in Sublime (`desc table` / `desc function` /
  `show records` / `show enum`).

Connections are not stored in this config but in each project's `.env`
(`DB_UI_*` variables, read by `tpope/vim-dotenv`); credentials come from the
environment (`SQLCMDUSER` etc.).

No Cyrillic in SQL query text passed to `sqlcmd` via `-Q`: the command line
arrives as ANSI and the text gets mangled. Cyrillic in the returned result is
fine.

## Conventions

- Code comments and commit bodies are **in Russian**, and explain *why*
  rather than *what* — a comment here usually documents the non-obvious
  reason behind a decision.
- Commits follow conventional commits; **subject in English**, body in
  Russian.
- Formatting via `stylua` (`stylua.toml`).
