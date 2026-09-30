# CLAUDE.md

Neovim config built on **LazyVim** (`lua/config/lazy.lua`:
`import = "lazyvim.plugins"`). Own plugin specs and overrides live in
`lua/plugins/*.lua`, own code in `lua/config/*.lua`.

## Where to read more

Details are in `docs/`; read the file when you work on its topic. When you
change a module, update its document **in the same commit**.

| Topic | File |
| --- | --- |
| Custom MS SQL layer: `lua/config/sql*.lua`, target resolution, `sqlcmd` encodings | `docs/sql.md` |
| Why the SQL layer is split the way it is | `docs/sql-refactor.md` |
| Keyboard layout switching, why no cyrillic mappings | `docs/keyboard.md` |

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

The SQL layer has specs in `tests/sql/` (own tiny runner, no plugins, fake
server and repo from `tests/fixtures.lua`). Run them after any change to
`lua/config/sql*.lua`; `-u NONE` keeps lazy from touching `lazy-lock.json`:

```bash
"/c/Program Files/Neovim/bin/nvim.exe" --headless -u NONE \
  -l C:/Users/pesotskiydmi/AppData/Local/nvim/tests/run.lua [filter]
```

SQL can be verified for real before shipping it: MCP servers `mssqlclient-*`
(esql/dgsql/crocus dev) execute queries directly. Use them for anything going
into `lua/config/sql*.lua` — e.g. `string_agg`'s separator must be a literal
or variable, which only shows up when the server rejects it.

`stylua` is not in PATH; it lives in
`~/AppData/Local/nvim-data/mason/bin/stylua.cmd`.

## Other own modules

- `lua/config/session.lua` (wired from `lua/plugins/persistence.lua`) — start
  in the session of the current folder instead of the dashboard, never
  falling back to another project's session (`NVIM_RESTORE_LAST=1` forces the
  latest one). On a session switch it saves the old project on
  `DirChangedPre` and wipes its file buffers on `PersistenceLoadPre` —
  `:mksession` alone leaves them behind.
- `lua/config/neovide.lua` (wired from `lua/config/options.lua`) — GUI
  settings, no-op outside Neovide. All animations are off on purpose, and
  `background` is forced dark: Neovide would take it from the (light) Windows
  theme.

## Conventions

- Code comments and commit bodies are **in Russian**, and explain *why*
  rather than *what* — a comment here usually documents the non-obvious
  reason behind a decision.
- Commits follow conventional commits; **subject in English**, body in
  Russian.
- Formatting via `stylua` (`stylua.toml`).
