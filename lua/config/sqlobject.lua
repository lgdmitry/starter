-- :SqlDef / :SqlRows / :SqlEnum — посмотреть объект прямо в базе, не открывая файл:
-- код процедуры/функции/вьюхи, состав таблицы, первые строки, значения enum,
-- текст сообщения по номеру.
-- Замена тому, что раньше делал SQLTools в Sublime (desc table / desc function /
-- show records / show enum), только сервер и база не спрашиваются, а берутся по тем же
-- правилам, что у :SqlDeploy (см. config.sqltarget).
--
-- В sql-буферах и в окне с ответом:
--   K            — код объекта под курсором или выделенного, а на числе — текст
--                  сообщения с этим номером (в RAISERROR(60003, ...) и THROW) либо
--                  значения enum с таким tvID (в любом другом месте)
--   gK           — то же, но подключение спрашивается (:SqlDef!): посмотреть, как
--                  объект выглядит на другом сервере
--   <leader>dr   — первые строки таблицы/вьюхи
--   <leader>de   — значения enum по tvID под курсором
--   <leader>du   — где в базах файла используется имя под курсором или выделенный
--                  текст, вместо сниппета fit (<leader>dU — выбрав подключение)
--   gf           — открыть файл этого объекта в репозитории (:SqlFile), в отличие
--                  от K, который показывает то, что реально лежит в базе
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

-- Значения того же enum, что и запрошенный tvID (как show enum в SQLTools). Сам запрос
-- спрятан в exec: в базе, где usEnumTypeValues нет, иначе не компилируется весь пакет и
-- вместо '#NOTFOUND#' приезжает ошибка — а с ней lookup не пойдёт искать в следующей базе.
local ENUM = [==[
set nocount on;
if object_id(N'usEnumTypeValues') is null select '#NOTFOUND#';
else exec(N'
if not exists (select 1 from usEnumTypeValues where tvID = %s) select ''#NOTFOUND#'';
else select * from usEnumTypeValues t
  where exists (select 1 from usEnumTypeValues where tyID = t.tyID and tvID = %s)
  order by iif(tvID = %s, 1, 0) desc, tvID asc;');
]==]

-- Где встречается текст: в коде процедур/функций/вьюх/триггеров всех баз файла сразу,
-- одним union all — в отличие от lookup, который останавливается на первой базе, где
-- нашлось: использования ищут как раз во всех. collate нужен из-за union: у баз бывают
-- разные коллации, и без него сервер отказывается склеивать колонки.
local USAGE = [==[
select [db] = N'%s' collate database_default,
  [object] = s.name + N'.' + o.name collate database_default,
  [type] = lower(o.type_desc) collate database_default
from [%s].sys.sql_modules sm
join [%s].sys.objects o on o.object_id = sm.object_id
join [%s].sys.schemas s on s.schema_id = o.schema_id
where sm.definition like N'%%%s%%'
  and o.name <> N'%s']==]

---Слово под курсором вместе с точками и скобками: dbo.usBases, [icsMaster].[dbo].[x].
---@return string? name, integer? col колонка, с которой слово начинается
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
  if name == "" then
    return nil
  end
  return name, s
end

---Строки выделения как есть, если команда вызвана из визуального режима.
local function selected_lines()
  local mode = vim.fn.mode()
  if not mode:match("^[vV\22]") then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  vim.api.nvim_input("<esc>") -- выделение больше не нужно; feedkeys тут вешает nvim намертво
  if not ok or not lines or #lines == 0 then
    return nil
  end
  return lines
end

---Выделенное имя объекта, если команда вызвана из визуального режима.
local function selected_text()
  local lines = selected_lines()
  if not lines then
    return nil
  end
  -- из "dbo.usBases u" берём только имя: выделяют обычно вместе с алиасом
  return vim.trim(table.concat(lines, " ")):match("^[%w_@#%$%.%[%]]+")
end

---Имя из аргумента команды, из выделения или из-под курсора.
---@return string? name, integer? col колонка начала слова — только когда оно взято
---из-под курсора: по тому, что стоит перед числом, отличается номер сообщения от tvID
local function wanted_object(fargs)
  local explicit = (fargs and fargs[1]) or selected_text()
  if explicit then
    return explicit
  end
  return object_under_cursor()
end

---Число под курсором — номер сообщения или значение enum? Решает то, что стоит перед
---ним: в RAISERROR(60003, ...) и THROW 60003, ... это сообщение, в любом другом месте
---(where tvID = 1080, @state = 1080) — tvID из usEnumTypeValues.
---@param col integer? колонка начала числа; nil — имя назвали явно или выделили,
---контекста нет, и сообщение вероятнее: аргументом обычно спрашивают именно про него
local function message_context(col)
  if not col then
    return true
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  -- RAISERROR часто переносят, и открывающая скобка остаётся на предыдущей строке
  local lines = vim.api.nvim_buf_get_lines(0, math.max(row - 3, 0), row, false)
  if #lines == 0 then
    return true
  end
  lines[#lines] = vim.api.nvim_get_current_line():sub(1, col - 1)
  local before = table.concat(lines, "\n"):lower():gsub("%s+$", "")
  return before:match("%f[%w_]raiserror%s*%(?$") ~= nil or before:match("%f[%w_]throw$") ~= nil
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
    url_fallback = true,
  }, cb)
end

---Маркер «не нашлось» ищем отдельной строкой, а не сравнением всего ответа: при -y 0
---sqlcmd печатает одно значение, а при -y N — ещё и пустую шапку со строкой дефисов.
local function not_found(text)
  for _, line in ipairs(vim.split(text, "\n")) do
    if vim.trim(line) == "#NOTFOUND#" then
      return true
    end
  end
  return false
end

---Гоняет запрос по базам подряд, пока объект не найдётся: файл лежит в ics_ua97, а
---объект рядом с ним вполне может жить в icsMaster.
---@param o table conn, dbs, title, args, ctx и всё, что нужно окну: kind, filetype, bottom;
---on_missing — что делать, когда базы кончились (по умолчанию сказать, что не нашли)
local function lookup(o, i)
  local db = o.dbs[i]
  if not db then
    if o.on_missing then
      return o.on_missing()
    end
    return notify(o.title .. ": не найден в " .. table.concat(o.dbs, ", "), vim.log.levels.WARN)
  end
  sql.sqlcmd(o.conn, db, o.args, function(code, text)
    vim.schedule(function()
      if not_found(text) then
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

---Текст сообщения по номеру — в первой же базе: сообщения общие для сервера.
local function message_job(conn, dbs, file, id)
  return {
    conn = conn,
    dbs = { dbs[1] },
    file = file,
    title = "message " .. id,
    args = sql.args({ query = MESSAGE:format(id), trunc = 0 }),
    kind = "message",
    filetype = "",
    bottom = true,
  }
end

---Значения enum по tvID — тем же окном, что и состав объекта.
local function enum_job(conn, dbs, file, id)
  return {
    conn = conn,
    dbs = dbs,
    file = file,
    title = "enum " .. id,
    args = sql.args({ query = ENUM:format(id, id, id), width = 8000, trunc = 50 }),
    filetype = "",
  }
end

---:SqlDef — код объекта (процедура/функция/вьюха/триггер), состав таблицы, а на числе —
---текст сообщения (K прямо на номере внутри RAISERROR(60003, ...)) или значения enum.
function M.define(opts)
  -- При нескольких курсорах multicursor повторяет нажатие K через feedkeys на каждом
  -- из них — это был бы один sqlcmd на курсор. Смотрим package.loaded, а не require:
  -- плагин может быть ещё не загружен, а тянуть его сюда ради проверки незачем.
  local mc = package.loaded["multicursor-nvim"]
  if mc and mc.hasCursors() then
    return
  end
  local name, col = wanted_object(opts.fargs)
  if not name then
    return notify("не понял, какой объект смотреть", vim.log.levels.ERROR)
  end
  pick(opts.bang, function(conn, dbs, file)
    -- число объектом быть не может: это либо номер сообщения из RAISERROR/THROW, либо
    -- tvID. Что именно — видно по соседям числа, но номера сообщений и tvID лежат в
    -- пересекающихся диапазонах, да и контекст можно не угадать: не нашлось одного —
    -- показываем другое
    local id = name:match("^%d+$")
    if id then
      local first, second = message_job(conn, dbs, file, id), enum_job(conn, dbs, file, id)
      if not message_context(col) then
        first, second = second, first
      end
      first.on_missing = function()
        lookup(second, 1)
      end
      second.on_missing = function()
        notify(
          id .. ": нет ни сообщения с таким номером, ни enum с таким tvID",
          vim.log.levels.WARN
        )
      end
      return lookup(first, 1)
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
    lookup(enum_job(conn, dbs, file, id), 1)
  end)
end

---:SqlUsages — где в базе используется процедура, таблица, номер сообщения или любой
---кусок текста (как сниппет fit, только без черновика и копирования).
---Под курсором берётся само имя без базы и схемы: в коде его пишут и как dbo.x, и как
---[x], и просто x. Выделение ищется как есть — это может быть и текст сообщения.
function M.usages(opts)
  local text
  if opts.args ~= "" then
    text = opts.args
  else
    local lines = selected_lines()
    if lines then
      -- переводы строк в коде бывают и CRLF, и LF — через границу строки ищем по %
      text = table.concat(vim.tbl_map(vim.trim, lines), "%")
    else
      local name = object_under_cursor()
      text = name and name:gsub("[%[%]]", ""):match("[^.]+$")
    end
  end
  if not text or vim.trim(text) == "" then
    return notify("не понял, что искать", vim.log.levels.ERROR)
  end
  -- _ и [ в like — метасимволы, а подчёркивание есть почти в каждом имени процедуры.
  -- % из многострочного выделения оставляем: он там и нужен как «что угодно»
  local quoted = text:gsub("'", "''")
  local pattern = quoted:gsub("%[", "[[]"):gsub("_", "[_]")
  pick(opts.bang, function(conn, dbs, file)
    local parts = {}
    for _, db in ipairs(dbs) do
      local b = db:gsub("%]", "]]")
      -- сам искомый объект в списке не нужен: его имя в собственном create procedure
      -- находится всегда, а спрашивают, кто его вызывает
      parts[#parts + 1] = USAGE:format((db:gsub("'", "''")), b, b, b, pattern, quoted)
    end
    -- через файл, а не -Q: выделенный текст сообщения бывает кириллическим, а
    -- командная строка приезжает в sqlcmd в ANSI
    local input = vim.fn.tempname() .. ".sql"
    local query = "set nocount on;\n" .. table.concat(parts, "\nunion all\n") .. "\norder by 1, 2;"
    vim.fn.writefile(vim.split(query, "\n"), input)
    local title = "usages of " .. text
    local where = table.concat(dbs, ",")
    local done = sql.progress(("ищу %s в %s/%s…"):format(text, conn.name, where), "SqlObject")
    local args = sql.args({ input = input, width = 8000, trunc = 128 })
    local started = sql.sqlcmd(conn, dbs[1], args, function(code, out, cancelled)
      vim.schedule(function()
        done()
        os.remove(input)
        if cancelled then
          return
        end
        if code ~= 0 then
          notify(title .. " @ " .. conn.name .. ": sqlcmd вернул " .. code, vim.log.levels.ERROR)
        end
        sqlwin.show({
          kind = "usages",
          title = ("%s @ %s/%s"):format(title, conn.name, where),
          text = out,
          -- K на имени из списка спросит первую базу — объекты из остальных баз
          -- смотреть через :SqlDef база.dbo.имя
          ctx = { file = file, conn = conn.name, db = dbs[1] },
          filetype = "",
          bottom = true,
        })
      end)
    end)
    if not started then
      done() -- процесс не запустился, ответа не будет — гасим сами
      os.remove(input)
    end
  end)
end

---:SqlFile (gf) — открыть файл объекта под курсором прямо из репозитория.
---Объекты лежат по одному в файле <имя>_PRC|TAB|VIW|TRG|FNC|FK.sql, поэтому имени
---хватает, чтобы найти файл точным glob'ом: одно совпадение открывается сразу, без
---пикера. Регистр не важен — в репозитории попадается и .SQL.
---С ! (:SqlFile!) пикер показывается всегда, даже когда файл ровно один.
function M.file(opts)
  local name = wanted_object(opts.fargs)
  if not name then
    return notify("не понял, какой файл искать", vim.log.levels.ERROR)
  end
  -- в имени файла ни базы, ни схемы: [icsMaster].[dbo].[usBases] -> usBases
  local object = name:gsub("[%[%]]", ""):match("[%w_@#%$]+$")
  if not object then
    return notify("не понял, какой файл искать: " .. name, vim.log.levels.ERROR)
  end
  -- у безымянного буфера (черновик запроса, окно с ответом) репозитория нет — берём
  -- файл, откуда он пришёл (b:sqlctx), а без него ищем от текущего каталога, как это
  -- делает Find Files
  local ctx = vim.b.sqlctx
  local file = (ctx and ctx.file) or vim.api.nvim_buf_get_name(0)
  if file:match("^sql://") then
    file = ""
  end
  local root = vim.fs.normalize((file ~= "" and vim.fs.root(file, ".git")) or vim.fn.getcwd())
  local glob = object .. "_*.sql"
  -- fd берём тот же, что и пикер: там он уже найден и проверен
  local cmd, args = require("snacks.picker.source.files").get_fd()
  if not cmd then
    return
  end
  vim.list_extend(args, { "--ignore-case", "--glob", glob, root })
  table.insert(args, 1, cmd)
  -- запоминаем сразу: пока fd ищет, курсор может уйти в другое окно
  local from = vim.b.sqlwin and vim.b.sqlwin.from
  -- асинхронно: по холодному кэшу fd бегает по репозиторию до секунды, а клавиша
  -- нажимается посреди чтения кода
  vim.system(args, { text = true }, function(res)
    local files = vim.split((res.stdout or ""):gsub("\r", ""), "\n", { trimempty = true })
    vim.schedule(function()
      if #files == 1 and not opts.bang then
        -- из окна ответа файл открывается в окне, откуда пришёл ответ, а не поверх
        -- ответа: пикер (ниже) поступает так же — окна nofile он для файлов не берёт
        if from and vim.api.nvim_win_is_valid(from) then
          vim.api.nvim_set_current_win(from)
        end
        return vim.cmd.edit(vim.fn.fnameescape(files[1]))
      end
      -- нашлось несколько (_TAB и _VIW, копия в соседней базе) — выбрать из них;
      -- не нашлось ничего — фаззи по имени: имя объекта не обязано совпадать с именем
      -- файла (Alter-скрипты, объект из другого репозитория)
      Snacks.picker.files(#files > 0 and {
        cwd = root,
        search = glob,
        args = { "--ignore-case", "--glob" },
        title = object,
      } or {
        cwd = root,
        pattern = object,
        title = object,
      })
    end)
  end)
end

---K, gK и gf — общие для sql-буферов и окон с ответом (их ставит config.sqlwin: там
---filetype бывает и пустой, так что по FileType они бы туда не попали).
function M.map_def_keys(buf)
  vim.keymap.set({ "n", "x" }, "K", "<cmd>SqlDef<cr>", { buffer = buf, desc = "Код объекта в базе" })
  vim.keymap.set(
    { "n", "x" },
    "gK",
    "<cmd>SqlDef!<cr>",
    { buffer = buf, desc = "Код объекта на другом сервере" }
  )
  -- gf только здесь, а не глобально: в остальных буферах это встроенный переход по пути,
  -- а в .sql путей не бывает — зато бывают имена объектов, у каждого свой файл
  vim.keymap.set(
    { "n", "x" },
    "gf",
    "<cmd>SqlFile<cr>",
    { buffer = buf, desc = "Файл объекта в репозитории" }
  )
end

function M.setup()
  -- K в sql-буферах не перебивается hover-маппингом LazyVim: тот отключён для
  -- filetype sql в спеке nvim-lspconfig (см. lua/plugins/dadbod.lua). Глобальным K
  -- быть не может — везде, кроме sql, это hover от LSP. В окнах с ответом его вешает
  -- config.sqlwin: там filetype бывает и пустой.
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("sqlobject_keys", { clear = true }),
    pattern = "sql",
    desc = "Клавиши просмотра объектов в sql-буферах",
    callback = function(ev)
      M.map_def_keys(ev.buf)
    end,
  })
  -- Автокоманды мало: buffer-local маппинг ставится только на будущие sql-буферы, а
  -- FileType в уже открытых мог случиться раньше этого setup() — тогда :SqlDeploy
  -- (клавиша глобальная) работает, а K в буфере просто нет. Так же поступает
  -- Snacks.keymap с ft-маппингами: заводит их и в уже загруженных буферах.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "sql" then
      M.map_def_keys(buf)
    end
  end

  -- Глобально, чтобы группа <leader>d была видна в which-key из любого буфера, а не
  -- только после открытия .sql. Имя объекта берётся из-под курсора, так что осмысленно
  -- это и в чужом файле — например, на имени процедуры в логе или в коде на другом языке.
  vim.keymap.set({ "n", "x" }, "<leader>dr", "<cmd>SqlRows<cr>", { desc = "Первые строки таблицы" })
  vim.keymap.set({ "n", "x" }, "<leader>de", "<cmd>SqlEnum<cr>", { desc = "Значения enum по tvID" })
  vim.keymap.set(
    { "n", "x" },
    "<leader>du",
    "<cmd>SqlUsages<cr>",
    { desc = "Где используется в базе" }
  )
  vim.keymap.set(
    { "n", "x" },
    "<leader>dU",
    "<cmd>SqlUsages!<cr>",
    { desc = "Где используется, выбрав подключение" }
  )

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
  command(
    "SqlUsages",
    M.usages,
    "Где в коде объектов баз встречается текст (! — выбрать подключение)"
  )
  command(
    "SqlFile",
    M.file,
    "Открыть файл объекта в репозитории (! — всегда через пикер)"
  )
end

return M
