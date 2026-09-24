-- :SqlFormat (<leader>df) — форматирование T-SQL по стандарту dgsql/esql
-- (скилл mssql-repo-skills:sql-standards, references/tsql-style.md; S<n> ниже — его якоря).
--
-- Почему своё, а не sqlfluff / sql-formatter: ни один из них не умеет того, на чём
-- стандарт стоит — ведущие запятые «3 пробела у первого элемента, 2 + запятая у
-- остальных», выровненные `=` в select, NULL под NULL от NOT NULL, закрытый список
-- того, что пишется ЗАГЛАВНЫМИ (§13).
--
-- Почему только диапазон, а не весь файл при сохранении: стандарт применяется к новым и
-- изменённым строкам, легаси ради него не переписывают. Поэтому <leader>df — оператор
-- (<leader>dfip, <leader>df} …) и действие на выделение, :SqlFormat — с диапазоном.
--
-- Что делается — два уровня, строки не переразбиваются (кроме переноса висячей запятой
-- в начало следующей строки):
--   1. токены, строго внутри диапазона: регистр (S5, S6, §13), пробелы вокруг операторов
--      (S38), после запятой в строке (S35), без пробелов у скобок (S37), `exists(` (S29),
--      табы (S1), полные имена частей даты (S33);
--   2. блоки, целиком, если диапазон их задел: ведущие запятые (S2) и их отступ от
--      вводящей строки, выровненные `=` в списках (S11), колонки типов / NULL /
--      комментариев в объявлениях (S21). Целиком — потому что стандарт сам требует
--      переформатировать весь блок, когда добавленная строка длиннее прежних.
-- Разметку запроса (клаузы в одну колонку, case, begin/end, подзапросы) не трогает.
--
-- Строки, комментарии и [идентификаторы] не меняются никогда. Слова, про которые нет
-- уверенности, что это ключевое слово (Name, Type, Date как имя колонки), тоже: имена
-- объектов пишутся так, как созданы в базе.

local M = {}

local tok = require("config.sqltoken")
local set, lower, is_comment, is_keyword, operand = tok.set, tok.lower, tok.is_comment, tok.is_keyword, tok.operand
local FUNCTIONS, TYPES, KEYWORDS, DDL = tok.FUNCTIONS, tok.TYPES, tok.KEYWORDS, tok.DDL
local DATE_FUNCS, DATE_PARTS, BINARY, width = tok.DATE_FUNCS, tok.DATE_PARTS, tok.BINARY, tok.width

local HEADER_OBJECTS = set("proc procedure function view trigger")

local SET_OPTIONS = set([[
  nocount ansi_nulls quoted_identifier dateformat datefirst xact_abort transaction
  ansi_warnings arithabort concat_null_yields_null ansi_padding numeric_roundabort
  lock_timeout deadlock_priority rowcount identity_insert noexec fmtonly language
  statistics ansi_null_dflt_on implicit_transactions textsize cursor_close_on_commit
]])
local SET_WORDS = vim.tbl_extend(
  "force",
  SET_OPTIONS,
  set([[
  on off isolation level read uncommitted committed repeatable serializable snapshot
]])
)

-- Строка, начинающаяся с такого слова, — уже следующая инструкция: DDL кончился.
local STARTERS = set([[
  select insert update delete merge if while set declare exec execute print begin end
  return raiserror truncate else fetch open close deallocate goto waitfor use grant deny
  revoke
]])

-- Слово перед `(` после них — имя объекта, а не функция: insert into Format (…).
local OBJECT_BEFORE = set("into table update join from exec execute procedure proc function view references")

-- Строка, начинающаяся с них, сама вводит список и может нести его первый элемент.
local INTRODUCERS = set([[
  select set update declare values insert exec execute group order create alter with
  merge using returns output
]])

local function rebuild(rec)
  local out = { string.rep(" ", rec.indent) }
  for i, t in ipairs(rec.toks) do
    out[#out + 1] = (i > 1 and string.rep(" ", t.sp) or "") .. t.s
  end
  return #rec.toks == 0 and "" or table.concat(out)
end

---------------------------------------------------------------------------------------
-- Уровень 1: регистр и пробелы. Состояние (DDL, заголовок процедуры, begin/end)
-- считается по всему тексту, чтобы фрагмент из середины понимал, где он; меняются
-- только токены выбранных записей.

local function case_pass(recs, sig)
  local function edit(t, s)
    if recs[t.ri].sel then
      t.s = s
    end
  end
  local ddl -- nil | "ddl" | "header"
  local parens = {} -- режим внутри каждой открытой скобки
  local blocks = {} -- begin/case, чтобы найти END процедуры
  local proc_begin, set_rec, header_depth = false, nil, 0
  local converts = set("convert try_convert")

  for i, t in ipairs(sig) do
    local prev, prev2, nxt = sig[i - 1], sig[i - 2], sig[i + 1]
    local w = lower(t)
    local mode = parens[#parens] or ddl
    if t.k == "lparen" then
      local pw = lower(prev)
      if mode and pw == "check" then
        parens[#parens + 1] = false -- выражение CHECK — строчными (§13)
      elseif not mode and pw == "table" then
        parens[#parens + 1] = "ddl" -- declare @t table (…) — определение таблицы
      else
        parens[#parens + 1] = mode or false
      end
    elseif t.k == "rparen" then
      parens[#parens] = nil
    elseif t.k == "semi" and #parens == 0 and ddl == "ddl" then
      ddl = nil
    elseif w then
      local first_in_rec = recs[t.ri].toks[1] == t
      if ddl == "ddl" and #parens == 0 and first_in_rec and STARTERS[w] then
        ddl, mode = nil, nil
      end
      local nw = lower(nxt)
      local pw = lower(prev)
      local is_func = nxt
        and nxt.k == "lparen"
        and FUNCTIONS[w]
        and not (prev and prev.k == "dot")
        and not OBJECT_BEFORE[pw or ""]
      if is_func then
        edit(t, t.s:upper())
      elseif w == "null" then
        edit(t, "NULL")
      elseif w == "not" and nw == "null" then
        edit(t, "NOT")
      elseif w == "go" and first_in_rec and #recs[t.ri].toks == 1 then
        edit(t, "GO")
        ddl, parens, blocks, proc_begin = nil, {}, {}, false
      elseif w == "return" or w == "raiserror" then
        edit(t, t.s:upper())
      elseif (w == "create" or w == "alter" or w == "drop") and not (prev and prev.k == "dot") then
        edit(t, t.s:upper())
        if not ddl then
          local j = i + 1
          if lower(sig[j]) == "or" then
            j = j + 2
          end
          ddl = (w ~= "drop" and HEADER_OBJECTS[lower(sig[j]) or ""]) and "header" or "ddl"
          header_depth = #parens
        end
      elseif mode and DDL[w] then
        edit(t, t.s:upper())
        if ddl == "header" and w == "as" and #parens == header_depth and pw ~= "execute" and pw ~= "exec" then
          ddl, proc_begin = nil, nw == "begin"
        end
      elseif mode and w == "where" then
        edit(t, "where") -- фильтр индекса — выражение, дальше строчными
        ddl = nil
      elseif
        TYPES[w]
        and (
          prev and prev.k == "var"
          or (prev and prev.k == "lparen" and converts[lower(prev2) or ""])
          or (mode and prev and (prev.k == "ident" or prev.k == "word"))
        )
      then
        edit(t, w)
      elseif w == "max" and prev and prev.k == "lparen" then
        edit(t, "max") -- varchar(max)
      elseif w == "begin" then
        if nw == "tran" or nw == "transaction" or nw == "distributed" then
          edit(t, "BEGIN")
        elseif proc_begin then
          edit(t, "BEGIN")
          blocks[#blocks + 1] = "proc"
        else
          edit(t, "begin")
          blocks[#blocks + 1] = "begin"
        end
        proc_begin = false
      elseif
        (w == "tran" or w == "transaction" or w == "distributed")
        and (pw == "begin" or pw == "commit" or pw == "rollback" or pw == "distributed")
      then
        edit(t, t.s:upper())
      elseif w == "commit" or w == "rollback" then
        edit(t, t.s:upper())
      elseif w == "case" then
        edit(t, "case")
        blocks[#blocks + 1] = "case"
      elseif w == "end" then
        -- END без пары во фрагменте не трогаем: неизвестно, чей он
        local top = table.remove(blocks)
        if top == "proc" then
          edit(t, "END")
        elseif top then
          edit(t, "end")
        end
      elseif w == "set" and SET_OPTIONS[nw or ""] then
        edit(t, "SET")
        set_rec = t.ri
      elseif set_rec == t.ri and SET_WORDS[w] then
        edit(t, t.s:upper())
      elseif w == "seterror" or w == "nowait" or (w == "log" and pw == "with") then
        edit(t, t.s:upper())
      elseif w == "with" and (nw == "seterror" or nw == "nowait" or nw == "log") then
        edit(t, "WITH")
      elseif (w == "source" or w == "target") and pw == "by" then
        edit(t, w)
      elseif KEYWORDS[w] then
        edit(t, w)
      end
    end
  end
end

---Скобка из серии в три и больше подряд — исключение S37, пробелы там оставляем.
local function in_run(toks, i)
  local k = toks[i].k
  local a, b = i, i
  while a > 1 and toks[a - 1].k == k do
    a = a - 1
  end
  while b < #toks and toks[b + 1].k == k do
    b = b + 1
  end
  return b - a + 1 >= 3
end

local function space_pass(recs, sig)
  for _, rec in ipairs(recs) do
    if rec.sel then
      local toks = rec.toks
      for i, t in ipairs(toks) do
        local nxt = toks[i + 1]
        local next_code = nxt and not is_comment(nxt)
        if t.k == "comma" then
          if i > 1 then
            t.sp = 0
          end
          if next_code then
            -- ведущая запятая прижата к элементу (S2), в строке — один пробел (S35)
            nxt.sp = i == 1 and 0 or 1
          end
        elseif t.k == "lparen" and not in_run(toks, i) then
          if next_code then
            nxt.sp = 0
          end
          local p = i > 1 and toks[i - 1]
          local pw = p and lower(p)
          if pw == "exists" or (pw and FUNCTIONS[pw] and p.s == p.s:upper()) then
            t.sp = 0 -- exists( (S29), ISNULL( без пробела
          end
        elseif t.k == "rparen" and i > 1 and not in_run(toks, i) then
          t.sp = 0
        elseif t.k == "op" and BINARY[t.s] and (t.s == "=" or operand(sig[t.si - 1])) then
          if i > 1 then
            t.sp = math.max(t.sp, 1)
          end
          if next_code then
            nxt.sp = math.max(nxt.sp, 1)
          end
        end
      end
    end
  end
end

local function date_parts(recs, sig)
  for i, t in ipairs(sig) do
    local part = sig[i + 2]
    if DATE_FUNCS[lower(t) or ""] and sig[i + 1] and sig[i + 1].k == "lparen" and part and part.k == "word" then
      local full = DATE_PARTS[part.s:lower()]
      if full and recs[part.ri].sel then
        part.s = full
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Уровень 2: блоки.

local function is_blank(rec)
  return #rec.toks == 0
end

local function comment_only(rec)
  return #rec.toks == 1 and is_comment(rec.toks[1])
end

local function comma_line(rec)
  return rec.toks[1] ~= nil and rec.toks[1].k == "comma"
end

local function col_before(rec, i)
  local c = rec.indent
  for k = 1, i - 1 do
    c = c + width(rec.toks[k].s) + rec.toks[k + 1].sp
  end
  return c
end

local function col_after(rec, i)
  return col_before(rec, i) + width(rec.toks[i].s)
end

---Висячая запятая в конце строки → в начало следующей (S2).
local function lead_commas(recs)
  for ri, rec in ipairs(recs) do
    local toks = rec.toks
    local last = #toks
    if last > 0 and is_comment(toks[last]) then
      last = last - 1
    end
    if rec.sel and last > 1 and toks[last].k == "comma" then
      local j = ri + 1
      while recs[j] and comment_only(recs[j]) do
        j = j + 1
      end
      local nxt = recs[j]
      if nxt and not is_blank(nxt) and not comma_line(nxt) and nxt.toks[1].k ~= "rparen" then
        table.remove(toks, last)
        table.insert(nxt.toks, 1, { k = "comma", s = ",", sp = 0 })
        nxt.toks[2].sp = 0
        nxt.dirty = true
      end
    end
  end
end

---Элемент списка «имя = …»: конец имени и индекс `=`.
local function named(rec)
  local toks, i = rec.toks, comma_line(rec) and 2 or 1
  local j = i
  while toks[j] and (toks[j].k == "word" or toks[j].k == "ident" or toks[j].k == "var" or toks[j].k == "temp") do
    if toks[j + 1] and toks[j + 1].k == "dot" and toks[j + 2] and toks[j + 2].sp == 0 then
      j = j + 2
    else
      break
    end
  end
  if j < i or not toks[j] or toks[j].k == "op" then
    return nil
  end
  local eq = toks[j + 1]
  if not (eq and eq.k == "op" and eq.s == "=") or is_keyword(toks[i]) then
    return nil
  end
  return col_after(rec, j), j + 1
end

local function align_equals(recs, heads)
  local items, ends = {}, {}
  for _, ri in ipairs(heads) do
    local rec = recs[ri]
    local e, eq = named(rec)
    if e and not rec.multi then
      items[#items + 1] = { rec = rec, e = e, eq = eq }
      ends[#ends + 1] = e
    end
  end
  if #items < 2 then
    return
  end
  -- ширину колонки задаёт самое длинное имя (§7 п.2), а не то, как выровнено было
  local target = math.max(unpack(ends)) + 1
  for _, it in ipairs(items) do
    local sp = target - it.e
    if it.rec.toks[it.eq].sp ~= sp then
      it.rec.toks[it.eq].sp = sp
      it.rec.dirty = true
    end
  end
end

---Список с ведущими запятыми, найденный по первой из них (j): первый элемент,
---вводящая строка и все элементы с их строками-продолжениями.
local function comma_block(recs, j)
  local c = recs[j].indent
  local k = j - 1
  while k >= 1 and (comment_only(recs[k]) or (not is_blank(recs[k]) and recs[k].indent > c)) do
    k = k - 1
  end
  local f = k + 1
  while f < j and comment_only(recs[f]) do
    f = f + 1
  end
  local parent, shared
  if f < j then
    parent = k >= 1 and not is_blank(recs[k]) and k or nil
  elseif k >= 1 and not is_blank(recs[k]) then
    -- перед первой запятой сразу строка не глубже запятых: либо это первый элемент на
    -- том же отступе (после переноса висячей запятой), либо «select a» — вводящее
    -- слово вместе с первым элементом
    f = k
    local w = lower(recs[k].toks[1])
    if recs[k].indent == c and not comma_line(recs[k]) and not INTRODUCERS[w or ""] then
      local p = k - 1
      while p >= 1 and comment_only(recs[p]) do
        p = p - 1
      end
      parent = p >= 1 and not is_blank(recs[p]) and p or nil
    else
      shared = true
    end
  else
    return nil
  end

  local elems = { { head = f, lines = {} } }
  for r = f, j - 1 do
    table.insert(elems[1].lines, r)
  end
  local i = j
  while true do
    local e = { head = i, lines = { i } }
    elems[#elems + 1] = e
    i = i + 1
    while recs[i] and not is_blank(recs[i]) do
      local r = recs[i]
      if comma_line(r) and r.indent == c then
        break
      elseif r.indent > c or (comment_only(r) and r.indent > c) then
        table.insert(e.lines, i)
      elseif comment_only(r) then
        -- комментарий между элементами на уровне запятых: не сдвигаем, но и список
        -- им не кончается, если дальше снова запятая
        local q = i
        while recs[q] and comment_only(recs[q]) do
          q = q + 1
        end
        if not (recs[q] and comma_line(recs[q]) and recs[q].indent == c) then
          break
        end
      else
        break
      end
      i = i + 1
    end
    if not (recs[i] and comma_line(recs[i]) and recs[i].indent == c) then
      break
    end
  end
  return { elems = elems, parent = parent, shared = shared, first = f, last = i - 1 }
end

---Колонка, от которой считается отступ списка: первое слово вводящей строки,
---а у «(select» — select, а не скобка.
local function parent_col(rec)
  local i = 1
  while rec.toks[i] and rec.toks[i].k == "lparen" and rec.toks[i + 1] do
    i = i + 1
  end
  return col_before(rec, i)
end

local function shift(recs, lines, delta)
  if delta == 0 then
    return
  end
  for _, r in ipairs(lines) do
    local rec = recs[r]
    if not is_blank(rec) then
      rec.indent = math.max(0, rec.indent + delta)
      rec.dirty = true
    end
  end
end

local function touched(recs, a, b)
  for r = a, b do
    if recs[r].sel then
      return true
    end
  end
  return false
end

local function comma_blocks(recs)
  local done = {}
  for j, rec in ipairs(recs) do
    if comma_line(rec) and not done[j] then
      local b = comma_block(recs, j)
      if b then
        for _, e in ipairs(b.elems) do
          done[e.head] = true
        end
        if touched(recs, b.first, b.last) then
          -- S2: первый элемент на 3 от вводящей строки, запятые — на 2
          if b.parent and not b.shared then
            local ct = parent_col(recs[b.parent]) + 2
            for n, e in ipairs(b.elems) do
              shift(recs, e.lines, (n == 1 and ct + 1 or ct) - recs[e.head].indent)
            end
          end
          local heads = {}
          for n, e in ipairs(b.elems) do
            if not (n == 1 and b.shared) then
              heads[#heads + 1] = e.head
            end
          end
          align_equals(recs, heads)
        end
      end
    end
  end
end

---Строка объявления (S21): [,][declare] имя тип [прочее] [-- комментарий].
local function parse_decl(rec)
  if rec.multi then
    return nil
  end
  local t, i = rec.toks, 1
  if t[i] and t[i].k == "comma" then
    i = i + 1
  end
  if lower(t[i]) == "declare" then
    i = i + 1
  end
  local name, ty = t[i], t[i + 1]
  if not name or not ty or ty.k ~= "word" then
    return nil
  end
  if not (name.k == "var" or name.k == "ident" or (name.k == "word" and not is_keyword(name))) then
    return nil
  end
  local j = i + 1
  if name.k == "var" and t[j + 1] and t[j + 1].k == "dot" and t[j + 2] and t[j + 2].k == "word" then
    j = j + 2 -- пользовательский тип: dbo.IDList
  elseif not TYPES[ty.s:lower()] then
    return nil
  end
  if t[j + 1] and t[j + 1].k == "lparen" then
    local depth = 0
    repeat
      j = j + 1
      if not t[j] then
        return nil
      end
      depth = depth + (t[j].k == "lparen" and 1 or t[j].k == "rparen" and -1 or 0)
    until depth == 0
  end
  local last, cmt = #t, nil
  if t[last].k == "comment" then
    cmt, last = last, last - 1
  end
  local depth = 0
  for r = j + 1, last do
    depth = depth + (t[r].k == "lparen" and 1 or t[r].k == "rparen" and -1 or 0)
    if depth == 0 and t[r].k == "comma" then
      return nil -- declare @a int, @b int — не столбик
    end
  end
  local rest = j < last and j + 1 or nil
  local words = {}
  for r = j + 1, last do
    words[#words + 1] = t[r].s:upper()
  end
  local tail = table.concat(words, " ")
  return {
    rec = rec,
    name = i,
    type = i + 1,
    type_end = j,
    rest = rest,
    rest_end = last,
    cmt = cmt,
    null = tail == "NULL" and "null" or tail == "NOT NULL" and "notnull" or nil,
  }
end

local function set_col(d, i, target)
  local rec = d.rec
  local sp = rec.toks[i].sp + target - col_before(rec, i)
  if sp ~= rec.toks[i].sp then
    rec.toks[i].sp = math.max(1, sp)
    rec.dirty = true
  end
end

local function align_decls(decls)
  -- Колонки — только от самого длинного элемента блока (§1, S21): тип — через 2 пробела
  -- после имени, NOT NULL — через 1 после типа, комментарий — через 1 после NULL.
  -- На то, как блок был выровнен раньше, не смотрим: легаси выровнено как попало.
  local ends = {}
  for _, d in ipairs(decls) do
    ends[#ends + 1] = col_after(d.rec, d.name)
  end
  local T = math.max(unpack(ends)) + 2
  for _, d in ipairs(decls) do
    set_col(d, d.type, T)
  end

  -- NULL прижат вправо, под NULL от NOT NULL; прочее (= 0, out, IDENTITY) — с той же
  -- колонки, что NOT
  local tends, any_rest = {}, false
  for _, d in ipairs(decls) do
    tends[#tends + 1] = col_after(d.rec, d.type_end)
    any_rest = any_rest or d.rest ~= nil
  end
  if any_rest then
    local N = math.max(unpack(tends)) + 1
    for _, d in ipairs(decls) do
      if d.rest then
        set_col(d, d.rest, d.null == "null" and N + 4 or N)
      end
    end
  end

  local bodies, any_cmt = {}, false
  for _, d in ipairs(decls) do
    bodies[#bodies + 1] = col_after(d.rec, d.rest and d.rest_end or d.type_end)
    any_cmt = any_cmt or d.cmt ~= nil
  end
  if any_cmt then
    local C = math.max(unpack(bodies)) + 1
    for _, d in ipairs(decls) do
      if d.cmt then
        set_col(d, d.cmt, C)
      end
    end
  end
end

local function decl_blocks(recs)
  local run, sel = {}, false
  local function flush()
    if #run > 0 and sel then
      align_decls(run)
    end
    run, sel = {}, false
  end
  for _, rec in ipairs(recs) do
    local d = parse_decl(rec)
    if d then
      run[#run + 1] = d
      sel = sel or rec.sel
    else
      flush()
    end
  end
  flush()
end

---------------------------------------------------------------------------------------

---Отформатировать строки l1..l2 (1-based, включительно). Возвращает новый список строк
---той же длины: строки не добавляются и не удаляются.
---@param lines string[]
---@param l1 integer
---@param l2 integer
---@param opts? { tabstop?: integer }
---@return string[]
function M.format(lines, l1, l2, opts)
  opts = opts or {}
  local text = table.concat(lines, "\n")
  local recs = tok.tokenize(text, opts.tabstop or 4)
  for _, rec in ipairs(recs) do
    rec.sel = rec.last >= l1 and rec.first <= l2
  end
  local sig = tok.flatten(recs)
  case_pass(recs, sig)
  date_parts(recs, sig)
  space_pass(recs, sig)
  lead_commas(recs)
  comma_blocks(recs)
  decl_blocks(recs)

  local out = {}
  for _, rec in ipairs(recs) do
    out[#out + 1] = (rec.sel or rec.dirty) and rebuild(rec) or text:sub(rec.from, rec.to)
  end
  return vim.split(table.concat(out, "\n"), "\n", { plain = true })
end

---Отформатировать диапазон буфера, заменив только реально изменившиеся строки: так
---undo и метки за пределами правки остаются на месте.
function M.format_range(buf, l1, l2)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = M.format(lines, l1, l2, { tabstop = vim.bo[buf].tabstop })
  local a = 1
  while a <= #lines and lines[a] == out[a] do
    a = a + 1
  end
  if a > #lines then
    return
  end
  local b = #lines
  while b > a and lines[b] == out[b] do
    b = b - 1
  end
  vim.api.nvim_buf_set_lines(buf, a - 1, b, false, vim.list_slice(out, a, b))
end

---operatorfunc для <leader>df: без аргумента ставит себя и возвращает g@.
function M.operator(kind)
  if kind == nil then
    vim.o.operatorfunc = "v:lua.require'config.sqlformat'.operator"
    return "g@"
  end
  local view = vim.fn.winsaveview()
  M.format_range(0, vim.fn.line("'["), vim.fn.line("']"))
  vim.fn.winrestview(view)
end

local function map_keys(buf)
  vim.keymap.set(
    "n",
    "<leader>df",
    M.operator,
    { buffer = buf, expr = true, desc = "Форматировать SQL (оператор)" }
  )
  vim.keymap.set(
    "x",
    "<leader>df",
    ":<C-u>'<,'>SqlFormat<cr>",
    { buffer = buf, desc = "Форматировать выделенный SQL" }
  )
end

function M.setup()
  vim.api.nvim_create_user_command("SqlFormat", function(o)
    local view = vim.fn.winsaveview()
    M.format_range(0, o.line1, o.line2)
    vim.fn.winrestview(view)
  end, {
    range = true,
    desc = "Форматировать T-SQL по стандарту репозиториев (диапазон, по умолчанию строка)",
  })

  -- Клавиша буферная: вне sql форматировать нечего, а which-key (real = true) тогда и
  -- не покажет её в группе. Уже открытые sql-буферы — по той же причине, что в
  -- config.sqlobject: FileType в них мог пройти раньше setup().
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("sqlformat_keys", { clear = true }),
    pattern = "sql",
    desc = "Клавиша форматирования в sql-буферах",
    callback = function(ev)
      map_keys(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "sql" then
      map_keys(buf)
    end
  end
end

return M
