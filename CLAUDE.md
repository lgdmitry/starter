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

## Custom MS SQL layer

Not a plugin — own code on top of vim-dadbod, wired up from
`lua/plugins/dadbod.lua`:

- `lua/config/sqlconn.lua` — transport: connections (`g:dbs` from
  `lua/config/sqldbs.lua`, plus `DB_UI_*` from a project `.env`), auth,
  encodings, running `sqlcmd` asynchronously with a progress spinner;
  `:SqlCancel` (`<leader>dc`) kills a running one.
- `lua/config/sqltarget.lua` — *where* to go for a given file: which
  connection and which databases (see below). `:SqlCacheClear` forgets what
  it cached. `:SqlWhere` (`<leader>di`) shows the resolved target; the
  lualine component (from `lua/plugins/dadbod.lua`) shows it only once known
  (`b:sqltarget`), because resolving queries the server synchronously.
  Viewing commands (`url_fallback`) also look in the connection's own URL
  database — first when the connection was picked by hand (`gK`), last
  otherwise; deploy stays strict.
- `lua/config/sqlwin.lua` — the result windows: one vertical split for object
  code, one bottom split for everything read as output; the next answer
  reuses the window. `b:sqlctx` in them keeps file/conn/db, so `K`,
  `:SqlRows`, `:SqlRun` inside a result window go where the result came from.
- `lua/config/sqldeploy.lua` — `:SqlDeploy` (`<leader>dd`): deploy the
  current `.sql` file; `:SqlDeployFiles` (and `<leader>dd` on Tab-selected
  entries in a snacks picker / explorer, action in `lua/plugins/snacks.lua`)
  deploys several at once. A file going into `icsMaster` is deployed to every
  server of the repo that has that database (dgsql: datagroup *and* billing/
  crocus) — `sqltarget.other_servers`; only when the connection came from the
  rules, not with `!` or an explicit connection name.
- `lua/config/sqlobject.lua` — `:SqlDef` (`K`), `:SqlRows` (`<leader>dr`),
  `:SqlEnum` (`<leader>de`), `:SqlUsages` (`<leader>du`), `:SqlFile` (`gf`):
  inspect an object in the database, find where a name is used, open the
  object's file in the repo. Replaces what SQLTools used to do in Sublime
  (`desc table` / `desc function` / `show records` / `show enum`).
- `lua/config/sqlquery.lua` — `:SqlQuery` (`<leader>dq`): a scratch query
  buffer bound to the connection and database of the current file;
  `:SqlQueryFile [name]` (`<leader>dt`; not `<leader>dp` — that is LazyVim's
  profiler group): a persistent one, opened in the current window — a file
  `stdpath("data")/sqlquery/conn@db.sql` whose first line
  `-- sqlquery: conn/db` holds the binding (re-read on
  `BufReadPost`/`BufWritePost`, so it survives restarts and sessions);
  `:SqlConn` (`<leader>ds`, query buffers only) picks another connection and
  database for the current query buffer and renames an auto-named file.
  Both kinds carry `b:sqlctx`, so a query buffer opened from a query buffer
  inherits its connection instead of the rules.
  `:SqlRun` (`<leader>dx`) runs it, or the visual selection in any sql buffer.
- `lua/config/sqlformat.lua` — `:SqlFormat` (`<leader>df`, operator in normal
  mode, selection in visual; sql buffers only): format T-SQL by the dgsql/esql
  standard (skill `mssql-repo-skills:sql-standards`, `tsql-style.md`; rules as of 1.5.9). Only the
  range, never the whole file on save — the standard applies to new/changed
  lines. Token level strictly inside the range (case per §13, operator/comma/
  bracket spacing, `exists (`, `UNION ALL`, full date parts); block level (leading commas and
  their indent from the introducing line, aligned `=`, type/NULL/comment
  columns) for every block the range touches. Columns come from the rules
  alone (longest element), not from how neighbouring legacy lines are aligned.
  Does not re-layout statements (clauses, `case`, `begin`/`end`). Line count
  never changes. `sqlfluff` from the `lang.sql` extra is removed entirely
  (mason, nvim-lint, conform — `lua/plugins/dadbod.lua`): as a format-on-save
  formatter it rewrote whole legacy files.
- `lua/config/sqllint.lua` — `:SqlLint`: `vim.diagnostic` (source `sqllint`,
  message starts with the rule anchor `S20: …`) by the same standard, only on
  lines changed vs git — gitsigns hunks, re-run on `User GitSignsUpdate`; a
  file not yet added to git counts as new entirely (gitsigns doesn't attach
  to untracked files, so `git ls-files` is asked once per buffer). `:SqlLint!`
  switches the buffer to the whole file, `:SqlLint` back. Token rules are
  WARN (S1, S3, S4, S8, S12, S20, S29, S33, S42, S43, S52, S54, and P14/P16
  from `create-procedure.md`); structural ones are HINT (S7, S9, S22, S24,
  S32, S34, S51, S55, S64, S65) — heuristics over a
  pre-pass (`annotate`: paren depth, GO batches, the procedure and its END,
  begin/try/case stack), since T-SQL without semicolons only parses roughly
  from tokens. Rules that need the schema (FK, DEFAULT, column types) are
  out of scope. What `:SqlFormat` fixes by itself (case, spacing,
  alignment) has no rules of its own: the changed lines are run through the
  formatter dry (`sqlformat.format_lines`), and a line it would rewrite gets
  a WARN `SqlFormat: … → <how it should look>` — so the two can't diverge.
  The tokenizer and word lists are shared with the formatter in
  `lua/config/sqltoken.lua`.
- `lua/config/sqlindent.lua` — `indentexpr` for sql buffers, set from
  `indent/sql.lua` (config dir is ahead of `$VIMRUNTIME` in rtp, and
  `LazyVim.set_default` doesn't override an option set outside `$VIMRUNTIME`).
  Treesitter's sql `indents.scm` gives 0 for almost every T-SQL line and the
  runtime `indent/sql.vim` is for another dialect. Keeps the previous line's
  indent; +2 after `begin`/`(`; +3 after a lone `select`/`declare` and a
  procedure header; `end`/`)`/`AS`/`from`/`where`/leading comma snap to their
  pair when typed (`indentkeys`; a comma there is `0\,`, `0<,>` doesn't work).
- `lua/config/sqlcomplete.lua` — sets `b:db` in ordinary `.sql` files (on the
  first `InsertEnter`, by the `sqltarget` rules, never prompting), so that
  vim-dadbod-completion completes tables and columns by alias there too —
  without `b:db` it completes nothing from the database.

Every command takes `!` (and has an uppercase-key twin: `<leader>dD`,
`<leader>dQ`, `<leader>dU`, `gK`) to pick the connection by hand instead of
by the rules. `docs/sql-refactor.md` records why the layer is split this way.

Target server and databases are resolved by `sqltarget` from the repo's
`.claude/repo-conventions.json` (the same rules the `deploy-commit` skill
uses): server by the top folder's environment, address from
`.mcp.environments.json`; databases from the file's own `usBases ... OptionsDB`
guard if present, otherwise by path rules; files under `Alter/**` take them only
from their first line (`-- ua` / `master` / `buh` / `crocus` / `dev` / `DUP_Old_Data`,
comma-separated),
an unknown name refuses rather than falling back. Without `repo-conventions.json`
there are fallback rules (dev connection by name/host, database from the first
path folder or the URL). Login/password always come from the connection with
the same host: `g:dbs` in `lua/config/sqldbs.lua` — one connection per server
(several per host, differing only in the database, made the host lookup pick
the alphabetically first one) with `${VAR}` expanded from the environment
(`SQLCMDUSER` etc.); a project `.env` (`DB_UI_*`, `tpope/vim-dotenv`) is still
read, but `g:dbs` wins on a name clash.

`multicursor.nvim` replays keys on every cursor; `:SqlDef` itself bails out
when there are extra cursors, rather than the multicursor layer overriding
`K` — that override deleted the buffer-local `K` for good on exit.

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
