-- :SqlDef / :SqlRows / :SqlEnum — посмотреть объект прямо в базе, не открывая файл:
-- код процедуры/функции/вьюхи, состав таблицы, первые строки, значения enum,
-- текст сообщения по номеру.
-- Замена тому, что раньше делал SQLTools в Sublime (desc table / desc function /
-- show records / show enum), только сервер и база не спрашиваются, а берутся по тем же
-- правилам, что у :SqlDeploy (см. config.sqltarget).
--
-- В sql-буферах и в окне с ответом:
--   K            — код объекта под курсором или выделенного, а на числе — текст
--                  сообщения с этим номером (K прямо на номере в RAISERROR(60003, ...))
--   <leader>dr   — первые строки таблицы/вьюхи
--   <leader>de   — значения enum по tvID под курсором
--   q            — закрыть окно с ответом
-- Имя можно назвать явно: :SqlDef dbo.dc_UpdDocument, :SqlDef icsMaster.dbo.usBases,
-- :50SqlRows tEmploy. С ! (:SqlDef!) подключение спрашивается.

local sql = require("config.sqlconn")
local target = require("config.sqltarget")
local sqlwin = require("config.sqlwin")

local M = {}

---Сколько строк показывает :SqlRows без явного счётчика (как show_records.limit в SQLTools).
M.rows_limit = 1000

local notify = sql.notifier("SqlObject")

-- Одним запросом: у процедур/функций/вьюх/триггеров — исходник как есть, у таблиц —
-- колонки, индексы и внешние ключи. Всё склеивается в одно значение, чтобы sqlcmd
-- отдал его без заголовков и обрезки (-y0). Кириллицы в тексте запроса быть не
-- должно: -Q приезжает в sqlcmd через ANSI-командную строку и там бы побилось.
local DESCRIBE = [==[
set nocount on;
declare @o int = object_id(N'%s');
declare @nl nvarchar(2) = char(13) + char(10);
if @o is null select '#NOTFOUND#';
else if object_definition(@o) is not null select object_definition(@o);
else select concat(
  '-- ', quotename(object_schema_name(@o)), '.', quotename(object_name(@o)), ' ',
  (select lower(replace(type_desc, '_', ' ')) from sys.objects where object_id = @o), @nl,
  (select string_agg(cast(concat('  ',
      left(c.name + space(34), 34), left(t.decl + space(18), 18),
      iif(c.is_nullable = 0, 'not null', 'null'),
      iif(c.is_identity = 1, ' identity', ''),
      isnull(' default ' + d.definition, ''),
      isnull(' as ' + cc.definition, '')) as nvarchar(max)) collate database_default, @nl)
      within group (order by c.column_id)
   from sys.columns c
   cross apply (select decl = type_name(c.user_type_id) +
       case when type_name(c.user_type_id) in ('nvarchar', 'nchar')
              then '(' + iif(c.max_length = -1, 'max', cast(c.max_length / 2 as varchar(11))) + ')'
            when type_name(c.user_type_id) in ('varchar', 'char', 'varbinary', 'binary')
              then '(' + iif(c.max_length = -1, 'max', cast(c.max_length as varchar(11))) + ')'
            when type_name(c.user_type_id) in ('decimal', 'numeric')
              then '(' + cast(c.precision as varchar(11)) + ',' + cast(c.scale as varchar(11)) + ')'
            else '' end) t
   left join sys.default_constraints d on d.object_id = c.default_object_id
   left join sys.computed_columns cc on cc.object_id = c.object_id and cc.column_id = c.column_id
   where c.object_id = @o),
  isnull((select @nl + @nl + '-- indexes' + @nl + string_agg(cast(concat('  ',
      left(isnull(i.name, '') + space(34), 34),
      iif(i.is_primary_key = 1, 'pk ', iif(i.is_unique = 1, 'unique ', '')),
      lower(i.type_desc), ' (', k.cols, ')', isnull(' include (' + k.inc + ')', ''))
      as nvarchar(max)) collate database_default, @nl) within group (order by i.index_id)
   from sys.indexes i
   cross apply (select cols = (select string_agg(cast(col_name(ic.object_id, ic.column_id)
                                     + iif(ic.is_descending_key = 1, ' desc', '') as nvarchar(max))
                                     collate database_default, ', ') within group (order by ic.key_ordinal)
                                from sys.index_columns ic
                               where ic.object_id = i.object_id and ic.index_id = i.index_id
                                 and ic.is_included_column = 0),
                       inc  = (select string_agg(cast(col_name(ic.object_id, ic.column_id) as nvarchar(max))
                                     collate database_default, ', ')
                                from sys.index_columns ic
                               where ic.object_id = i.object_id and ic.index_id = i.index_id
                                 and ic.is_included_column = 1)) k
   where i.object_id = @o and i.type > 0), ''),
  isnull((select @nl + @nl + '-- foreign keys' + @nl + string_agg(cast(concat('  ',
      left(fk.name + space(34), 34), c.src, ' -> ',
      quotename(object_schema_name(fk.referenced_object_id)), '.',
      quotename(object_name(fk.referenced_object_id)), '(', c.dst, ')')
      as nvarchar(max)) collate database_default, @nl) within group (order by fk.name)
   from sys.foreign_keys fk
   cross apply (select src = (select string_agg(cast(col_name(fc.parent_object_id, fc.parent_column_id)
                                     as nvarchar(max)) collate database_default, ', ')
                                from sys.foreign_key_columns fc where fc.constraint_object_id = fk.object_id),
                       dst = (select string_agg(cast(col_name(fc.referenced_object_id, fc.referenced_column_id)
                                     as nvarchar(max)) collate database_default, ', ')
                                from sys.foreign_key_columns fc where fc.constraint_object_id = fk.object_id)) c
   where fk.parent_object_id = @o), ''));
]==]

-- Текст сообщения по номеру из RAISERROR/THROW — только сам текст, без служебных
-- полей: его читают как сообщение, а не как объект. Сообщения живут на сервере, а не
-- в базе, поэтому базы перебирать не нужно — хватает первой. Если номер заведён на
-- нескольких языках, показываем все через пустую строку.
local MESSAGE = [==[
set nocount on;
declare @id int = %s;
-- разделителем string_agg может быть только литерал или переменная, но не выражение
declare @sep nvarchar(4) = char(13) + char(10) + char(13) + char(10);
if not exists (select 1 from sys.messages where message_id = @id) select '#NOTFOUND#';
else select string_agg(cast(text as nvarchar(max)) collate database_default, @sep)
    within group (order by language_id)
  from sys.messages where message_id = @id;
]==]

---Слово под курсором вместе с точками и скобками: dbo.usBases, [icsMaster].[dbo].[x].
local function object_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local function part(i)
    return line:sub(i, i):match("[%w_@#%$%.%[%]]") ~= nil
  end
  if col > #line or not part(col) then
    return nil
  end
  local s, e = col, col
  while s > 1 and part(s - 1) do
    s = s - 1
  end
  while e < #line and part(e + 1) do
    e = e + 1
  end
  local name = line:sub(s, e):gsub("^%.+", ""):gsub("%.+$", "")
  return name ~= "" and name or nil
end

---Выделенный текст, если команда вызвана из визуального режима.
local function selected_text()
  local mode = vim.fn.mode()
  if not mode:match("^[vV\22]") then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  vim.api.nvim_input("<esc>") -- выделение больше не нужно; feedkeys тут вешает nvim намертво
  if not ok or not lines or #lines == 0 then
    return nil
  end
  -- из "dbo.usBases u" берём только имя: выделяют обычно вместе с алиасом
  return vim.trim(table.concat(lines, " ")):match("^[%w_@#%$%.%[%]]+")
end

---Имя из аргумента команды, из выделения или из-под курсора.
local function wanted_object(fargs)
  return (fargs and fargs[1]) or selected_text() or object_under_cursor()
end

---Разбирает [база].[схема].[объект]: базу отдаёт отдельно, остальное — в скобках,
---чтобы не спотыкаться об имена вроде dbo.[Order].
---@return string? database, string object
local function split_name(name)
  local parts = {}
  for _, p in ipairs(vim.split(name, ".", { plain = true })) do
    parts[#parts + 1] = (p:gsub("^%[", ""):gsub("%]$", ""))
  end
  local database
  if #parts > 2 then
    database = parts[1]
    table.remove(parts, 1)
  end
  local quoted = {}
  for _, p in ipairs(parts) do
    if p ~= "" then
      quoted[#quoted + 1] = "[" .. p .. "]"
    end
  end
  return database, table.concat(quoted, ".")
end

---Откуда смотреть: в окне с ответом и в черновике запроса — то же подключение и база,
---иначе по файлу и правилам репозитория.
local function pick(bang, cb)
  target.pick({
    ctx = vim.b.sqlctx,
    file = vim.api.nvim_buf_get_name(0),
    bang = bang,
    prompt = "Смотреть в:",
    title = "SqlObject",
  }, cb)
end

---Гоняет запрос по базам подряд, пока объект не найдётся: файл лежит в ics_ua97, а
---объект рядом с ним вполне может жить в icsMaster.
---@param o table conn, dbs, title, args, ctx и всё, что нужно окну: kind, filetype, bottom
local function lookup(o, i)
  local db = o.dbs[i]
  if not db then
    return notify(o.title .. ": не найден в " .. table.concat(o.dbs, ", "), vim.log.levels.WARN)
  end
  sql.sqlcmd(o.conn, db, o.args, function(code, text)
    vim.schedule(function()
      if vim.trim(text) == "#NOTFOUND#" then
        return lookup(o, i + 1)
      end
      if code ~= 0 then
        notify(o.title .. " @ " .. o.conn.name .. "/" .. db .. ": sqlcmd вернул " .. code, vim.log.levels.ERROR)
      end
      sqlwin.show({
        kind = o.kind or "object",
        title = ("%s @ %s/%s"):format(o.title, o.conn.name, db),
        text = text,
        ctx = { file = o.file, conn = o.conn.name, db = db },
        filetype = o.filetype,
        bottom = o.bottom,
      })
    end)
  end)
end

---:SqlDef — код объекта (процедура/функция/вьюха/триггер), состав таблицы, а на числе —
---текст сообщения с этим номером: K прямо на номере внутри RAISERROR(60003, ...).
function M.define(opts)
  local name = wanted_object(opts.fargs)
  if not name then
    return notify("не понял, какой объект смотреть", vim.log.levels.ERROR)
  end
  pick(opts.bang, function(conn, dbs, file)
    -- число объектом быть не может, зато это номер сообщения из RAISERROR/THROW
    local id = name:match("^%d+$")
    if id then
      return lookup({
        conn = conn,
        dbs = { dbs[1] },
        file = file,
        title = "message " .. id,
        args = sql.args({ query = MESSAGE:format(id), trunc = 0 }),
        kind = "message",
        filetype = "",
        bottom = true,
      }, 1)
    end
    local db, object = split_name(name)
    lookup({
      conn = conn,
      dbs = db and { db } or dbs,
      file = file,
      title = object,
      args = sql.args({ query = DESCRIBE:format((object:gsub("'", "''"))), trunc = 0 }),
    }, 1)
  end)
end

---:SqlRows — первые строки таблицы или вьюхи (:50SqlRows — пятьдесят).
function M.rows(opts)
  local name = wanted_object(opts.fargs)
  if not name then
    return notify("не понял, из чего показывать строки", vim.log.levels.ERROR)
  end
  local limit = (opts.count and opts.count > 0) and opts.count or M.rows_limit
  pick(opts.bang, function(conn, dbs, file)
    local db, object = split_name(name)
    lookup({
      conn = conn,
      dbs = db and { db } or dbs,
      file = file,
      title = object .. " (" .. limit .. ")",
      args = sql.args({
        query = ("set nocount on; select top %d * from %s;"):format(limit, object),
        width = 8000,
        trunc = 30,
      }),
      filetype = "",
    }, 1)
  end)
end

---:SqlEnum — значения того же enum, что и tvID под курсором (как show enum в SQLTools).
function M.enum(opts)
  local id = (opts.fargs and opts.fargs[1]) or selected_text() or vim.fn.expand("<cword>")
  if not tostring(id):match("^%-?%d+$") then
    return notify("нужен числовой tvID, а не " .. tostring(id), vim.log.levels.ERROR)
  end
  pick(opts.bang, function(conn, dbs, file)
    local query = ([[set nocount on;
select * from usEnumTypeValues t
 where exists (select 1 from usEnumTypeValues where tyID = t.tyID and tvID = %s)
 order by iif(tvID = %s, 1, 0) desc, tvID asc;]]):format(id, id)
    lookup({
      conn = conn,
      dbs = dbs,
      file = file,
      title = "enum " .. id,
      args = sql.args({ query = query, width = 8000, trunc = 50 }),
      filetype = "",
    }, 1)
  end)
end

function M.setup()
  -- K в sql-буферах не перебивается hover-маппингом LazyVim: тот отключён для
  -- filetype sql в спеке nvim-lspconfig (см. lua/plugins/dadbod.lua). Глобальным K
  -- быть не может — везде, кроме sql, это hover от LSP. В окнах с ответом его вешает
  -- config.sqlwin: там filetype бывает и пустой.
  local function map_key(buf)
    vim.keymap.set({ "n", "x" }, "K", "<cmd>SqlDef<cr>", { buffer = buf, desc = "Код объекта в базе" })
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("sqlobject_keys", { clear = true }),
    pattern = "sql",
    desc = "Клавиши просмотра объектов в sql-буферах",
    callback = function(ev)
      map_key(ev.buf)
    end,
  })
  -- Автокоманды мало: buffer-local маппинг ставится только на будущие sql-буферы, а
  -- FileType в уже открытых мог случиться раньше этого setup() — тогда :SqlDeploy
  -- (клавиша глобальная) работает, а K в буфере просто нет. Так же поступает
  -- Snacks.keymap с ft-маппингами: заводит их и в уже загруженных буферах.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "sql" then
      map_key(buf)
    end
  end

  -- Глобально, чтобы группа <leader>d была видна в which-key из любого буфера, а не
  -- только после открытия .sql. Имя объекта берётся из-под курсора, так что осмысленно
  -- это и в чужом файле — например, на имени процедуры в логе или в коде на другом языке.
  vim.keymap.set({ "n", "x" }, "<leader>dr", "<cmd>SqlRows<cr>", { desc = "Первые строки таблицы" })
  vim.keymap.set({ "n", "x" }, "<leader>de", "<cmd>SqlEnum<cr>", { desc = "Значения enum по tvID" })

  local function command(name, fn, desc, count)
    vim.api.nvim_create_user_command(name, fn, { nargs = "?", bang = true, count = count, desc = desc })
  end
  command(
    "SqlDef",
    M.define,
    "Показать код объекта из базы, на числе — текст сообщения (! — выбрать подключение)"
  )
  command(
    "SqlRows",
    M.rows,
    "Показать первые строки таблицы (:50SqlRows — 50 строк)",
    0
  )
  command("SqlEnum", M.enum, "Показать значения enum по tvID")
end

return M
