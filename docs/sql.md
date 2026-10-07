# Custom MS SQL layer

Two local plugins on top of vim-dadbod. The commands — deploy, object lookup,
queries, completion — are `plugins-local/mssql` (spec `lua/plugins/mssql.lua`,
modules `mssql.*`, specs in `plugins-local/mssql/tests/`; how to run them:
`CLAUDE.md`). The connection list stays in the config (`lua/config/sqldbs.lua`,
loaded from `lua/plugins/dadbod.lua`): it describes this machine, not the plugin.
`docs/sql-refactor.md` records why the layer is split this way.

The pure part — tokenizer, formatter, linter, indent — is the local plugin
`plugins-local/sqlkit` (spec `lua/plugins/sqlkit.lua`, modules `sqlkit.*`). It
knows nothing about dadbod, `sqlcmd` or connections, and has its own specs in
`plugins-local/sqlkit/tests/` (`run.lua` there).

## Modules

- `plugins-local/mssql/lua/mssql/conn.lua` — transport: connections (`g:dbs` from
  `lua/config/sqldbs.lua`, plus `DB_UI_*` from a project `.env`), auth,
  encodings, running `sqlcmd` asynchronously with a progress spinner;
  `:SqlCancel` (`<leader>dc`) kills a running one.
- `plugins-local/mssql/lua/mssql/target.lua` — *where* to go for a given file: which
  connection and which databases (see "Target resolution" below).
  `:SqlCacheClear` forgets what it cached. `:SqlWhere` (`<leader>di`) shows the
  resolved target; the lualine component (from `lua/plugins/dadbod.lua`) shows
  it only once known (`b:sqltarget`), because resolving queries the server
  synchronously. Viewing commands (`url_fallback`) also look in the
  connection's own URL database — first when the connection was picked by hand
  (`gK`), last otherwise; deploy stays strict.
- `plugins-local/mssql/lua/mssql/win.lua` — the result windows: one vertical split for object
  code, one bottom split for everything read as output; the next answer
  reuses the window. `b:sqlctx` in them keeps file/conn/db, so `K`,
  `:SqlRows`, `:SqlRun` inside a result window go where the result came from.
  A focused result window always starts in normal mode, even when `<F5>` was
  pressed in insert.
- `plugins-local/mssql/lua/mssql/deploy.lua` — `:SqlDeploy` (`<leader>dd`,
  `<F5>` in normal/insert): deploy the current `.sql` file; `:SqlDeployFiles` (and `<leader>dd` on Tab-selected
  entries in a snacks picker / explorer, action in `lua/plugins/snacks.lua`)
  deploys several at once. A file going into `icsMaster` is deployed to every
  server of the repo that has that database (dgsql: datagroup *and* billing/
  crocus) — `mssql.target.other_servers`; only when the connection came from the
  rules, not with `!` or an explicit connection name. In a persistent query
  (`<leader>dt`) the connection and database come from its `b:sqlctx` (the
  `-- sqlquery:` line), not from the rules: the file lives outside any repo,
  and the rules would just ask.
- `plugins-local/mssql/lua/mssql/object.lua` — `:SqlDef` (`K`), `:SqlRows` (`<leader>dr`),
  `:SqlEnum` (`<leader>de`), `:SqlUsages` (`<leader>du`), `:SqlFile` (`gf`):
  inspect an object in the database, find where a name is used, open the
  object's file in the repo. Replaces what SQLTools used to do in Sublime
  (`desc table` / `desc function` / `show records` / `show enum`).
- `plugins-local/mssql/lua/mssql/query.lua` — `:SqlQuery` (`<leader>dq`): a scratch query
  buffer bound to the connection and database of the current file;
  `:SqlQueryFile [name]` (`<leader>dt`; not `<leader>dp` — that is LazyVim's
  profiler group): a new persistent one every time, opened in the current
  window — a file `stdpath("data")/sqlquery/conn@db.sql` (`conn@db~N.sql` when
  taken; older ones are reopened by name, `:SqlQueryFile <Tab>`) whose first line
  `-- sqlquery: conn/db` holds the binding (re-read on
  `BufReadPost`/`BufWritePost`, so it survives restarts and sessions);
  `:SqlConn` (`<leader>ds`, query buffers only) picks another connection and
  database for the current query buffer and renames an auto-named file.
  `q` in a query buffer goes back to the previous buffer; a scratch query stays
  hidden for the next `<leader>dq`, a persistent one is saved and deleted.
  Auto-named persistent files (`conn@db`, `conn@db~N`) last only for the day:
  `setup()` removes those not modified since the start of today (open ones
  excepted); files named by hand stay until removed.
  Both kinds carry `b:sqlctx`, so a query buffer opened from a query buffer
  inherits its connection instead of the rules.
  `:SqlRun` (`<leader>dx`, or `<F5>` in any mode, insert included — it
  overrides the deploy `<F5>` in query buffers) runs it, or the visual
  selection in any sql buffer.
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
  DEFAULT, column types) are out of scope.
  Hygiene rules port `hygiene.awk` from skill `mssql-repo-skills:task-blockers`
  (anchors are its sections): `A2` — a declared variable that is never used or
  only written, `A6` — read but never assigned, or read before the first write
  (the finding sits on the read), `B1` — an alias nobody references (an outer
  join referenced only in its own ON, too; an inner join used as a filter is
  fine, and single-source queries are skipped). They work on tokens: exec
  out-arguments, `@ret =`, the callee's parameter names, `fetch … into` over
  several lines, `insert`/`update`/`delete` of a table variable, comments and
  strings are all told apart, which the awk regexps get wrong. A finding on
  `declare` can be caused by an edit elsewhere (the last read removed), so
  these carry the batch's line `span` and are shown when *any* line of the
  batch (procedure) changed, not only on changed lines. What `:SqlFormat` fixes by itself
  (case, spacing, alignment) has no rules of its own: the changed lines are run
  through the formatter dry (`sqlkit.format.format_lines`), and a line it would
  rewrite gets a WARN `SqlFormat: … → <how it should look>` — so the two can't
  diverge. A rewrite that only changes the *amount* of whitespace (indent,
  column alignment, doubled spaces) is not reported — it was more noise than
  help; a missing space (`@a=1`) still is. The tokenizer and word lists are shared with the formatter in
  `plugins-local/sqlkit/lua/sqlkit/token.lua`.
- `plugins-local/sqlkit/lua/sqlkit/indent.lua` — `indentexpr` for sql buffers, set from
  `plugins-local/sqlkit/indent/sql.lua` (plugin dir is ahead of `$VIMRUNTIME` in rtp, and
  `LazyVim.set_default` doesn't override an option set outside `$VIMRUNTIME`).
  Treesitter's sql `indents.scm` gives 0 for almost every T-SQL line and the
  runtime `indent/sql.vim` is for another dialect. Keeps the previous line's
  indent; +2 after `begin`/`(`; +3 after a lone `select`/`declare` and a
  procedure header; `end`/`)`/`AS`/`from`/`where`/leading comma snap to their
  pair when typed (`indentkeys`; a comma there is `0\,`, `0<,>` doesn't work).
- `plugins-local/mssql/lua/mssql/complete.lua` — sets `b:db` in ordinary `.sql` files (on the
  first `InsertEnter`, by the `mssql.target` rules, never prompting), so that
  vim-dadbod-completion completes tables and columns by alias there too —
  without `b:db` it completes nothing from the database.

Every command takes `!` (and has an uppercase-key twin: `<leader>dD`,
`<leader>dQ`, `<leader>dU`, `gK`) to pick the connection by hand instead of
by the rules.

## Target resolution

Target server and databases are resolved by `mssql.target` from the repo's
`.claude/repo-conventions.json` (the same rules the `deploy-commit` skill
uses): server by the top folder's environment, address from
`.mcp.environments.json`; databases from the file's own `usBases ... OptionsDB`
guard if present (the mask is resolved against the `icsMaster.dbo.usBases`
of the *target* server — each server has its own registry, and `Crocus` is
only in crocus's; default's registry is used only when the target has no
`icsMaster`), otherwise by path rules; files under `Alter/**` take them only
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
bytes instead, which is what `mssql.conn.output_to_utf8` does.

`:SqlExport` (`<leader>do`) writes the result to `<name>.json` next to the
file, or to `<name>.txt` (a plain table) when the query has no `FOR JSON`
outside comments and string literals. The decision is made from the query
text, not the output: the `sqlcmd` flags (no headers, no truncation for JSON)
must be chosen before it runs. An explicit path picks the mode by its
extension instead. Three things it has to undo: a file's BOM stays in the first buffer line
as text (`fileencodings` has no `ucs-bom`, proc-test files may even carry two),
and once `SET NOCOUNT ON;` is prepended the server sees it as `Incorrect syntax
near '?'` — so leading BOMs are stripped; `FOR JSON` comes back in 2033-char
rows that `sqlcmd` prints one per line — consecutive lines are joined until
they parse; server messages (`Warning: Null value is eliminated…`, `print`)
share stdout — they go to a notification, not the file. Note that the dgsql
dev server reports itself as `EXPRESS-DEV\SNICKERS` (`@@servername`) — that
is not the esql box (`tank22`).
