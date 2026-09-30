# Custom MS SQL layer

Not a plugin — own code on top of vim-dadbod, wired up from
`lua/plugins/dadbod.lua`. `docs/sql-refactor.md` records why the layer is split
this way. Specs live in `tests/sql/` (how to run them: `CLAUDE.md`).

The pure part — tokenizer, formatter, linter, indent — is the local plugin
`plugins-local/sqlkit` (spec `lua/plugins/sqlkit.lua`, modules `sqlkit.*`). It
knows nothing about dadbod, `sqlcmd` or connections, and has its own specs in
`plugins-local/sqlkit/tests/` (`run.lua` there).

## Modules

- `lua/config/sqlconn.lua` — transport: connections (`g:dbs` from
  `lua/config/sqldbs.lua`, plus `DB_UI_*` from a project `.env`), auth,
  encodings, running `sqlcmd` asynchronously with a progress spinner;
  `:SqlCancel` (`<leader>dc`) kills a running one.
- `lua/config/sqltarget.lua` — *where* to go for a given file: which
  connection and which databases (see "Target resolution" below).
  `:SqlCacheClear` forgets what it cached. `:SqlWhere` (`<leader>di`) shows the
  resolved target; the lualine component (from `lua/plugins/dadbod.lua`) shows
  it only once known (`b:sqltarget`), because resolving queries the server
  synchronously. Viewing commands (`url_fallback`) also look in the
  connection's own URL database — first when the connection was picked by hand
  (`gK`), last otherwise; deploy stays strict.
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
- `plugins-local/sqlkit/lua/sqlkit/format.lua` — `:SqlFormat` (`<leader>df`, operator in normal
  mode, selection in visual; sql buffers only): format T-SQL by the dgsql/esql
  standard (skill `mssql-repo-skills:sql-standards`, `tsql-style.md`). Only the
  range, never the whole file on save — the standard applies to new/changed
  lines. Token level strictly inside the range (case, operator/comma/bracket
  spacing, `exists (`, `UNION ALL`, full date parts); block level (leading
  commas and their indent from the introducing line, aligned `=`, type/NULL/
  comment columns) for every block the range touches. Columns come from the
  rules alone (longest element), not from how neighbouring legacy lines are
  aligned. Does not re-layout statements (clauses, `case`, `begin`/`end`).
  Line count never changes. `sqlfluff` from the `lang.sql` extra is removed
  entirely (mason, nvim-lint, conform — `lua/plugins/dadbod.lua`): as a
  format-on-save formatter it rewrote whole legacy files.
- `plugins-local/sqlkit/lua/sqlkit/lint.lua` — `:SqlLint`: `vim.diagnostic` (source `sqllint`,
  message starts with the rule anchor `S20: …`) by the same standard, only on
  lines changed vs git — gitsigns hunks, re-run on `User GitSignsUpdate`; a
  file not yet added to git counts as new entirely (gitsigns doesn't attach
  to untracked files, so `git ls-files` is asked once per buffer). `:SqlLint!`
  switches the buffer to the whole file, `:SqlLint` back. Token rules are
  WARN, structural ones are HINT — heuristics over a pre-pass (`annotate`:
  paren depth, GO batches, the procedure and its END, begin/try/case stack),
  since T-SQL without semicolons only parses roughly from tokens. The current
  rule list is in `lint.lua` itself. Rules that need the schema (FK,
  DEFAULT, column types) are out of scope. What `:SqlFormat` fixes by itself
  (case, spacing, alignment) has no rules of its own: the changed lines are run
  through the formatter dry (`sqlkit.format.format_lines`), and a line it would
  rewrite gets a WARN `SqlFormat: … → <how it should look>` — so the two can't
  diverge. The tokenizer and word lists are shared with the formatter in
  `plugins-local/sqlkit/lua/sqlkit/token.lua`.
- `plugins-local/sqlkit/lua/sqlkit/indent.lua` — `indentexpr` for sql buffers, set from
  `plugins-local/sqlkit/indent/sql.lua` (plugin dir is ahead of `$VIMRUNTIME` in rtp, and
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
by the rules.

## Target resolution

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

## Gotchas

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
