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

## Verifying changes

Headless nvim is good for inspecting state (dump keymaps, walk a plugin's
internal tree, check an option) and useless for anything driven by keypresses:
which-key's `getcharstr()` loop does not run under `--headless`, so a fed
`<leader>` sequence never resolves — even the latin control case fails. Test
key handling interactively instead, or by asking for a one-line `:lua` check.

Two things that will waste time otherwise:

- Pass **Windows paths** to `nvim.exe` (`C:/Users/...`). An MSYS-style
  `/c/Users/...` path is not found, `luafile` fails silently-ish and headless
  nvim then just sits there until it is killed.
- Starting nvim (headless included) can install or update plugins and rewrite
  `lazy-lock.json`. Check `git status` afterwards and don't fold that into an
  unrelated commit.

SQL can be verified for real before shipping it: MCP servers `mssqlclient-*`
(esql/dgsql/crocus dev) execute queries directly. Use them for anything going
into `lua/config/sql*.lua` — e.g. `string_agg`'s separator must be a literal
or variable, which only shows up when the server rejects it.

`stylua` is not in PATH; it lives in
`~/AppData/Local/nvim-data/mason/bin/stylua.cmd`.

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
- `lua/config/sqlquery.lua` — `:SqlQuery` (`<leader>dq`): a scratch query
  buffer bound to the connection and database of the current file;
  `:SqlRun` (`<leader>dx`) runs it, or the visual selection in any sql buffer.

Connections are not stored in this config but in each project's `.env`
(`DB_UI_*` variables, read by `tpope/vim-dotenv`); credentials come from the
environment (`SQLCMDUSER` etc.).

No Cyrillic in SQL query text passed to `sqlcmd` via `-Q`: the command line
arrives as ANSI and the text gets mangled. Cyrillic in the returned result is
fine.

Do not route queries through dadbod's own `:DB` / `<leader>S`: its sqlserver
adapter calls `sqlcmd` with no `-f` at all, so both the query file it writes
and the output it reads back are ANSI — Cyrillic breaks in the *result*, not
just in the query. `sqlcmd`'s own output codepage is not worth relying on
either (`-f i:65001` vs `-f 65001` vs a BOM all behave differently, and it
seems to mirror whatever encoding it detected in the input file); detect the
bytes instead, which is what `sqlconn.output_to_utf8` does.

## Keyboard layout

Not a plugin either: `lua/config/keyboard.lua`, wired from `lua/config/options.lua`
(not from `autocmds.lua` — that one loads on VeryLazy, i.e. after `VimEnter`). It
forces the Windows layout back to English on `InsertLeave` and restores the one you
typed in on `InsertEnter`, by posting `WM_INPUTLANGCHANGEREQUEST` to the foreground
window through LuaJIT's FFI (`user32`). `ActivateKeyboardLayout` would do nothing
here: a console nvim does not read the keyboard, the terminal's window thread does.
The English `HKL` is found by scanning `GetKeyboardLayoutList` for language id
`0x0409` — `LoadKeyboardLayoutA` returns a canonical handle that is not the one
actually loaded, because the installed layouts are substitutes (`a0020409`,
`a0000419`, `a0000422`).

Normal mode is therefore always latin, so **do not add cyrillic duplicates of
mappings**. That is what `langmapper.nvim` used to do, and which-key cannot be made
to work with them: it reads the second key of a sequence through its own
`vim.fn.getcharstr()` and has no extension point for the pressed key, so an unknown
cyrillic key makes it replay the whole sequence through `feedkeys` — with its own
triggers already removed.

`'langmap'` is still set (tables taken off the three installed layouts with
`ToUnicodeEx`), but only as a safety net: `PostMessage` is asynchronous, so keys the
terminal queued in the first milliseconds after `<Esc>` are still translated with the
old layout. It covers built-in commands only, never mappings.

## Conventions

- Code comments and commit bodies are **in Russian**, and explain *why*
  rather than *what* — a comment here usually documents the non-obvious
  reason behind a decision.
- Commits follow conventional commits; **subject in English**, body in
  Russian.
- Formatting via `stylua` (`stylua.toml`).
