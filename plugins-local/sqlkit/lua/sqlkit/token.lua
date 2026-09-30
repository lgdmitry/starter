-- Токенизатор T-SQL и словари, общие для sqlkit.format и sqlkit.lint.
--
-- Один на двоих, потому что оба решают одно и то же — где слово ключевое, где имя, где
-- `*` умножение, а где «все колонки», — и расхождение между ними значило бы, что
-- форматтер чинит не то, на что ругается линтер.

local M = {}

local function set(words)
  local t = {}
  for w in words:gmatch("%S+") do
    t[w] = true
  end
  return t
end
M.set = set

-- Системные функции — ЗАГЛАВНЫМИ (S6), но только перед `(`: DAY(x) — функция,
-- DATEADD(day, …) — часть даты, left join — соединение.
M.FUNCTIONS = set([[
  abs acos app_name ascii asin atan atn2 avg binary_checksum cast ceiling char charindex
  checksum checksum_agg choose coalesce col_length col_name columnproperty compress concat
  concat_ws context_info convert cos cot count count_big cume_dist cursor_status datalength
  databasepropertyex dateadd datediff datediff_big datefromparts datename datepart
  datetime2fromparts datetimefromparts datetrunc day db_id db_name decompress degrees
  dense_rank difference eomonth error_line error_message error_number error_procedure
  error_severity error_state exp filegroup_name first_value floor format formatmessage
  getdate getutcdate greatest grouping has_perms_by_name hashbytes host_id host_name
  ident_current iif index_col is_member is_srvrolemember isdate isjson isnull isnumeric
  json_array json_modify json_object json_query json_value lag last_value lead least left
  len log log10 lower ltrim max min month nchar newid newsequentialid ntile nullif
  object_id object_name object_schema_name objectproperty objectpropertyex openjson
  openquery openrowset openxml original_login parse parsename patindex percent_rank pi
  power quotename radians rand rank replace replicate reverse right round row_number
  rowcount_big rtrim schema_id schema_name scope_identity serverproperty session_context
  sign sin soundex space sqrt square stdev stdevp str string_agg string_escape
  string_split stuff substring sum suser_id suser_name suser_sname switchoffset
  sysdatetime sysdatetimeoffset sysutcdatetime tan timefromparts todatetimeoffset
  translate trim try_cast try_convert try_parse type_id type_name unicode upper user_id
  user_name var varp xact_state year
]])

-- Типы — строчными, но только там, где это заведомо тип: Date/Text/Time бывают и
-- именами колонок без скобок.
M.TYPES = set([[
  bigint int smallint tinyint bit decimal numeric money smallmoney float real date
  datetime datetime2 smalldatetime time datetimeoffset char varchar nchar nvarchar text
  ntext binary varbinary image uniqueidentifier xml sql_variant timestamp rowversion
  hierarchyid geography geometry sysname cursor table
]])

-- Строчными вне DDL. Только зарезервированные слова и то, что голым именем колонки не
-- бывает: зарезервированное без скобок именем быть не может, значит, это ключевое слово.
M.KEYWORDS = set([[
  add all and any apply as asc begin between break by case catch close collate continue
  cross cursor deallocate declare default delete desc distinct else end escape except
  exec execute exists fetch for from full goto group having holdlock if in index inner
  insert intersect into is join left like matched merge nocheck nolock not of off on
  open option or order out output outer over partition percent pivot readonly readpast
  right rowlock select set some table tablock then throw top try truncate union unique
  unpivot update updlock using values waitfor when where while with xlock
]])

-- ЗАГЛАВНЫМИ внутри DDL (CREATE TABLE / ALTER TABLE / CREATE INDEX / DROP …) и в
-- заголовке процедуры до AS: §13 — «это DDL».
M.DDL = set([[
  create alter drop or table index unique clustered nonclustered on primary key
  constraint default for check nocheck foreign references with fillfactor add column
  identity not null if exists include cascade no action delete update insert set asc
  desc sequence as start increment by minvalue maxvalue cycle cache type rowguidcol
  pad_index statistics_norecompute allow_row_locks allow_page_locks ignore_dup_key
  data_compression online sort_in_tempdb off persisted collate textimage_on sparse
  replication proc procedure function view trigger returns schemabinding encryption
  recompile execute owner caller instead of after nonclustered
]])

M.DATE_FUNCS = set("dateadd datediff datediff_big datepart datename datetrunc")
-- S33: сокращения легко спутать (m — month, mi — minute; y — dayofyear, не year),
-- а ошибка молча меняет результат.
M.DATE_PARTS = {
  yy = "year",
  yyyy = "year",
  year = "year",
  qq = "quarter",
  q = "quarter",
  quarter = "quarter",
  mm = "month",
  m = "month",
  month = "month",
  dy = "dayofyear",
  y = "dayofyear",
  dayofyear = "dayofyear",
  dd = "day",
  d = "day",
  day = "day",
  wk = "week",
  ww = "week",
  week = "week",
  isowk = "iso_week",
  isoww = "iso_week",
  iso_week = "iso_week",
  dw = "weekday",
  w = "weekday",
  weekday = "weekday",
  hh = "hour",
  hour = "hour",
  mi = "minute",
  n = "minute",
  minute = "minute",
  ss = "second",
  s = "second",
  second = "second",
  ms = "millisecond",
  millisecond = "millisecond",
  mcs = "microsecond",
  microsecond = "microsecond",
  ns = "nanosecond",
  nanosecond = "nanosecond",
  tz = "tzoffset",
  tzoffset = "tzoffset",
}

local TWO_CHAR_OPS = set("<> <= >= != !< !> += -= *= /= %= &= |= ^= ::")
-- Бинарные — те, вокруг которых обязателен пробел (S38); ~ и ! только унарные, :: — это
-- SCHEMA::имя.
M.BINARY = set("= < > <> <= >= != !< !> + - * / % & | ^ += -= *= /= %= &= |= ^=")

---------------------------------------------------------------------------------------
-- Токены

local function width(s)
  local tail = s:match("[^\n]*$")
  return vim.api.nvim_strwidth(tail)
end
M.width = width

---Один токен с позиции pos: вид и позиция последнего байта.
local function scan(text, pos)
  local two = text:sub(pos, pos + 1)
  if two == "--" then
    local e = text:find("\n", pos, true)
    return "comment", e and e - 1 or #text
  end
  if two == "/*" then
    -- в T-SQL блочные комментарии вкладываются
    local depth, i = 1, pos + 2
    while depth > 0 do
      local a, b = text:find("/*", i, true), text:find("*/", i, true)
      if not b then
        return "block", #text
      end
      if a and a < b then
        depth, i = depth + 1, a + 2
      else
        depth, i = depth - 1, b + 2
      end
    end
    return "block", i - 1
  end
  local c = text:sub(pos, pos)
  local function quoted(open, close, kind)
    local i = pos + #open
    while true do
      local q = text:find(close, i, true)
      if not q then
        return kind, #text
      end
      if text:sub(q + 1, q + 1) == close then
        i = q + 2
      else
        return kind, q
      end
    end
  end
  if c == "'" then
    return quoted("'", "'", "string")
  end
  if (c == "N" or c == "n") and text:sub(pos + 1, pos + 1) == "'" then
    return quoted("N'", "'", "string")
  end
  if c == "[" then
    return quoted("[", "]", "ident")
  end
  if c == '"' then
    return quoted('"', '"', "ident")
  end
  if c == "@" then
    local _, e = text:find("^@@?[%w_@#$\128-\255]*", pos)
    return "var", e
  end
  if c == "#" then
    local _, e = text:find("^##?[%w_@#$\128-\255]*", pos)
    return "temp", e
  end
  if c:match("%d") then
    local _, e = text:find("^0[xX]%x*", pos)
    if not e then
      _, e = text:find("^%d+%.?%d*", pos)
      local _, x = text:find("^[eE][+-]?%d+", e + 1)
      e = x or e
    end
    return "number", e
  end
  if c:match("[%a_\128-\255]") then
    local _, e = text:find("^[%w_@#$\128-\255]+", pos)
    return "word", e
  end
  if TWO_CHAR_OPS[two] then
    return "op", pos + 1
  end
  if c:match("[=<>+%-*/%%&|^~!]") then
    return "op", pos
  end
  local kinds = { [","] = "comma", ["("] = "lparen", [")"] = "rparen", [";"] = "semi", ["."] = "dot" }
  return kinds[c] or "other", pos
end

---Текст → записи. Запись — физическая строка, а если в ней начинается многострочная
---строка или комментарий, то и все строки, которые он занимает: переформатировать
---середину литерала нельзя. Пробелы хранятся числом (sp — перед токеном), табы
---раскрыты: в отступе таб = один уровень = 2 пробела (S1), внутри строки — до tabstop.
---
---У токена ещё l / c — строка (с 1) и байтовая колонка (с 0) его начала в тексте: по
---ним линтер ставит диагностику. Табы вне токенов — в recs.tabs ({ l, c }), их
---раскрытие в sp уже не видно.
function M.tokenize(text, tabstop)
  local recs, pos, len, ln, bol = {}, 1, #text, 1, 1
  local rec, col, lastcol, at_start
  recs.tabs = {}
  local function new_rec(start)
    rec = { toks = {}, indent = 0, first = ln, last = ln, from = start }
    recs[#recs + 1] = rec
    col, lastcol, at_start = 0, 0, true
  end
  new_rec(1)
  while pos <= len do
    local c = text:sub(pos, pos)
    if c == "\n" then
      rec.to = pos - 1
      ln = ln + 1
      pos = pos + 1
      bol = pos
      new_rec(pos)
    elseif c == " " or c == "\t" or c == "\r" then
      if c == "\t" then
        recs.tabs[#recs.tabs + 1] = { l = ln, c = pos - bol }
        local step = at_start and 2 or tabstop
        col = col + step - col % step
      elseif c == " " then
        col = col + 1
      end
      pos = pos + 1
    else
      local kind, e = scan(text, pos)
      local s = text:sub(pos, e)
      local sp = col - lastcol
      if at_start then
        rec.indent, sp, at_start = col, 0, false
      end
      rec.toks[#rec.toks + 1] = { k = kind, s = s, sp = sp, l = ln, c = pos - bol }
      local _, nl = s:gsub("\n", "")
      if nl > 0 then
        ln = ln + nl
        rec.last, rec.multi = ln, true
        bol = pos + #s:match("^.*\n")
        col = width(s)
      else
        col = col + width(s)
      end
      lastcol = col
      pos = e + 1
    end
  end
  rec.to = len
  return recs
end

function M.lower(t)
  return t and t.k == "word" and t.s:lower() or nil
end
local lower = M.lower

function M.is_comment(t)
  return t.k == "comment" or t.k == "block"
end

---Значимые токены подряд, через все записи. У каждого — ri / ti (запись и место в ней)
---и si (место в этом списке).
function M.flatten(recs)
  local sig = {}
  for ri, rec in ipairs(recs) do
    for ti, t in ipairs(rec.toks) do
      t.ri, t.ti = ri, ti
      if not M.is_comment(t) then
        sig[#sig + 1] = t
        t.si = #sig
      end
    end
  end
  return sig
end

function M.is_keyword(t)
  local w = lower(t)
  return w and w ~= "end" and w ~= "null" and (M.KEYWORDS[w] or M.DDL[w] or w == "return" or w == "raiserror")
end

---Операнд ли перед оператором — то есть бинарный ли он: -1 после `(`, `,`, `=`,
---select, then, RETURN — унарный минус, * после select / `(` / `.` — не умножение.
function M.operand(t)
  if not t then
    return false
  end
  if t.k == "word" then
    return not M.is_keyword(t)
  end
  return t.k == "var" or t.k == "temp" or t.k == "ident" or t.k == "number" or t.k == "string" or t.k == "rparen"
end

return M
