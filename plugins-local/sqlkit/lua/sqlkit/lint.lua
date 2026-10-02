-- :SqlLint — проверка T-SQL по стандарту dgsql/esql (скилл mssql-repo-skills:sql-standards,
-- references/tsql-style.md; S<n> — его якоря, они же в начале каждого сообщения).
--
-- Почему только изменённые строки (по gitsigns), а весь файл — лишь по :SqlLint!:
-- стандарт применяется к новым и изменённым строкам, а в легаси нарушений столько, что
-- сообщение о своей строке в них бы утонуло. Новый, ещё не добавленный в git файл —
-- новый целиком, его проверяем весь.
--
-- Правила двух уровней. Токенные (WARN) видны по самим словам и почти не ошибаются.
-- Структурные (HINT) смотрят на устройство процедуры — где кончается условие if, какая
-- инструкция следующая, последний ли это RETURN 0 — и держатся на эвристиках: T-SQL
-- без точек с запятой по токенам разбирается только приблизительно. Правил, которым
-- нужна схема базы (FK, DEFAULT, типы колонок), здесь нет.
--
-- То, что форматтер (:SqlFormat) чинит сам — регистр, пробелы, выравнивание, —
-- отдельными правилами не проверяется: изменённые строки прогоняются через сам
-- форматтер вхолостую, и строка, которую он бы поменял, получает находку SqlFormat с
-- тем, как она должна выглядеть. Так правила форматирования живут в одном месте и
-- линтер с форматтером не могут разойтись.

local tok = require("sqlkit.token")
local lower, operand, is_comment = tok.lower, tok.operand, tok.is_comment

local M = {}

local ns = vim.api.nvim_create_namespace("sqllint")

---------------------------------------------------------------------------------------
-- Правила. Каждое получает список значимых токенов и кладёт находки через add.

local function is_word(t, ...)
  local w = lower(t)
  if not w then
    return false
  end
  for _, x in ipairs({ ... }) do
    if w == x then
      return true
    end
  end
  return false
end

local function after_dot(sig, i)
  return sig[i - 1] and sig[i - 1].k == "dot"
end

---Вызов функции: слово name, за ним `(`, и не колонка/метод через точку.
local function call(sig, i, ...)
  return is_word(sig[i], ...) and sig[i + 1] and sig[i + 1].k == "lparen" and not after_dot(sig, i)
end

---Индекс парной закрывающей скобки для `(` в позиции i.
local function close_paren(sig, i)
  local depth = 0
  for j = i, #sig do
    local k = sig[j].k
    depth = depth + (k == "lparen" and 1 or k == "rparen" and -1 or 0)
    if depth == 0 then
      return j
    end
  end
end

---Первый ли токен на своей строке (токен до него мог быть многострочным — el).
local function line_start(sig, i)
  local p = sig[i - 1]
  return not p or p.el < sig[i].l
end

---begin, открывающий блок: "begin" / "try" / "catch" или nil (BEGIN TRAN).
local function block_begin(sig, i)
  local nxt = sig[i + 1]
  if is_word(nxt, "tran", "transaction", "distributed", "dialog", "conversation") then
    return nil
  end
  return is_word(nxt, "try", "catch") and lower(nxt) or "begin"
end

local function unbracket(s)
  return (s:gsub("^%[", ""):gsub("%]$", ""))
end

---Предпроход для структурных правил. Каждому токену: d — глубина скобок, b — номер
---батча (GO), el — строка конца, in_try — внутри begin try; end — closes (что он
---закрыл: begin / try / catch / case), else — case_else. Батчу — first / last, proc
---(имя, если в нём CREATE PROCEDURE), proc_begin / proc_end — BEGIN и END тела (у
---функции и триггера тоже): после END в том же батче бывает сторож с DROP PROCEDURE,
---и он уже не тело.
local function annotate(sig)
  local batches, stack, depth, tries, proc_open = { { first = 1 } }, {}, 0, 0, false
  for _, t in ipairs(sig) do
    t.el = t.l + select(2, t.s:gsub("\n", ""))
  end
  for i, t in ipairs(sig) do
    local w = lower(t)
    if t.k == "rparen" then
      depth = math.max(0, depth - 1)
    end
    t.d = depth
    if t.k == "lparen" then
      depth = depth + 1
    end
    if w == "go" and line_start(sig, i) and not (sig[i + 1] and sig[i + 1].l == t.el) then
      -- следующий батч: незакрытое до GO дальше не тянется
      batches[#batches].last = i - 1
      batches[#batches + 1] = { first = i + 1 }
      stack, depth, tries, proc_open = {}, 0, 0, false
    elseif w == "begin" then
      local kind = block_begin(sig, i)
      if kind and #stack == 0 and is_word(sig[i - 1], "as") then
        proc_open = true
        batches[#batches].proc_begin = i
      end
      stack[#stack + 1] = kind
      tries = tries + (kind == "try" and 1 or 0)
    elseif w == "case" then
      stack[#stack + 1] = "case"
    elseif w == "end" then
      t.closes = table.remove(stack)
      tries = tries - (t.closes == "try" and 1 or 0)
      if proc_open and #stack == 0 then
        batches[#batches].proc_end, proc_open = i, false
      end
    elseif w == "else" then
      t.case_else = stack[#stack] == "case"
    end
    t.b, t.in_try = #batches, tries > 0
  end
  batches[#batches].last = #sig
  for _, b in ipairs(batches) do
    for i = b.first, b.last do
      if is_word(sig[i], "create", "alter") then
        local j = is_word(sig[i + 1], "or") and i + 3 or i + 1
        if is_word(sig[j], "proc", "procedure") then
          local k, name = j + 1, ""
          while sig[k] and (sig[k].k == "word" or sig[k].k == "ident") do
            name = unbracket(sig[k].s)
            if not (sig[k + 1] and sig[k + 1].k == "dot") then
              break
            end
            k = k + 2
          end
          b.proc = name
          break
        end
      end
    end
  end
  return { batches = batches }
end

-- С них на новой строке начинается следующая инструкция. select среди них нет: в
-- insert … select он — продолжение insert.
local STMT = tok.set([[
  insert update delete merge if else while begin end set declare exec execute return
  raiserror print drop create alter truncate commit rollback break continue goto waitfor
  throw fetch open close deallocate
]])

local function stmt_word(sig, j)
  local w = lower(sig[j])
  -- if update(col) в триггере — функция, не инструкция
  return w and STMT[w] and not (w == "update" and sig[j + 1] and sig[j + 1].k == "lparen")
end

---Начало следующей инструкции после той, что начинается в i (на той же глубине и в
---том же батче), или nil.
local function next_statement(sig, i)
  local d, b = sig[i].d, sig[i].b
  for j = i + 1, #sig do
    local s = sig[j]
    if s.b ~= b or s.d < d then
      return nil
    end
    if s.d == d and line_start(sig, j) and stmt_word(sig, j) then
      return j
    end
  end
end

---Где кончается условие if в позиции i: индекс первого токена тела. case … end внутри
---условия пропускается целиком — у него свои else и end.
local function cond_end(sig, i)
  local d, b, cases = sig[i].d, sig[i].b, 0
  for j = i + 1, #sig do
    local s = sig[j]
    if s.b ~= b or s.d < d then
      return nil
    end
    if s.d == d then
      if is_word(s, "case") then
        cases = cases + 1
      elseif cases > 0 and is_word(s, "end") then
        cases = cases - 1
      elseif cases == 0 and (stmt_word(sig, j) or is_word(s, "select", "with")) then
        return j
      end
    end
  end
end

---Есть ли среди токенов a..b переменная name (без учёта регистра).
local function has_var(sig, a, b, name)
  name = name:lower()
  for j = a, b do
    if sig[j].k == "var" and sig[j].s:lower() == name then
      return true
    end
  end
  return false
end

---Условие if в позиции i проверяет @@ERROR (и, если дан, код возврата ret)?
local function checks_error(sig, i, ret)
  if not is_word(sig[i], "if") then
    return false
  end
  local e = (cond_end(sig, i) or #sig + 1) - 1
  return has_var(sig, i + 1, e, "@@error") and (not ret or has_var(sig, i + 1, e, ret))
end

---Вызов процедуры: exec [@ret =] имя. Возвращает { ret = токен или nil, name = имя
---строчными, k = индекс после имени } или nil — для exec (@sql), exec @sql, EXECUTE AS,
---GRANT EXEC ON и системных sp_* / xp_* (у sp_executesql первые параметры позиционные
---по самому его устройству).
local function parse_exec(sig, i)
  if
    not is_word(sig[i], "exec", "execute")
    or after_dot(sig, i)
    or is_word(sig[i - 1], "with")
    or is_word(sig[i + 1], "on")
  then
    return nil
  end
  local k, ret = i + 1, nil
  if sig[k] and sig[k].k == "var" and sig[k + 1] and sig[k + 1].s == "=" then
    ret, k = sig[k], k + 2
  end
  local name, parts = nil, {}
  while sig[k] and (sig[k].k == "word" or sig[k].k == "ident") and not is_word(sig[k], "as") do
    name = unbracket(sig[k].s):lower()
    parts[#parts + 1] = name
    if sig[k + 1] and sig[k + 1].k == "dot" then
      k = k + 2
    else
      k = k + 1
      break
    end
  end
  if not name or name:match("^sp_") or name:match("^xp_") then
    return nil
  end
  local db = #parts >= 3 and (parts[1] == "msdb" or parts[1] == "master")
  return { ret = ret, name = name, k = k, db = db }
end

local rules = {}

-- S3: `*` вместо списка колонок. Умножение — когда слева операнд.
function rules.star(sig, add)
  for i, t in ipairs(sig) do
    if t.k == "op" and t.s == "*" and not operand(sig[i - 1]) then
      if sig[i - 1] and sig[i - 1].k == "lparen" and call(sig, i - 2, "count", "count_big") then
        add(t, "S3", "`*` запрещён: COUNT(1) вместо COUNT(*)")
      else
        add(t, "S3", "`*` запрещён: перечислите колонки явно")
      end
    end
  end
end

-- S4: курсоров нет — только while.
function rules.cursor(sig, add)
  for i, t in ipairs(sig) do
    if is_word(t, "cursor") and not after_dot(sig, i) then
      add(
        t,
        "S4",
        "курсоры не используются: цикл while по временной таблице или ключу"
      )
    end
  end
end

-- S20: только CONVERT() — он один принимает стиль (112, 104).
function rules.cast(sig, add)
  for i, t in ipairs(sig) do
    if call(sig, i, "cast") then
      add(t, "S20", "CONVERT() вместо CAST()")
    elseif call(sig, i, "try_cast") then
      add(t, "S20", "TRY_CONVERT() вместо TRY_CAST()")
    end
  end
end

-- S43: TRIM() вместо LTRIM(RTRIM()).
function rules.trim(sig, add)
  for i, t in ipairs(sig) do
    if
      (call(sig, i, "ltrim") and call(sig, i + 2, "rtrim"))
      or (call(sig, i, "rtrim") and call(sig, i + 2, "ltrim"))
    then
      add(t, "S43", "TRIM() вместо " .. t.s:upper() .. "(" .. sig[i + 2].s:upper() .. "())")
    end
  end
end

-- S8: временная таблица — только CREATE TABLE, не select … into #Tmp. into после
-- insert / merge / output — это вставка в уже созданную таблицу, не создание.
function rules.select_into(sig, add)
  for i, t in ipairs(sig) do
    if is_word(t, "into") and sig[i + 1] and sig[i + 1].k == "temp" then
      -- ближайшее вводящее слово той же скобки
      local depth, owner = 0, nil
      for j = i - 1, 1, -1 do
        local p = sig[j]
        if p.k == "rparen" then
          depth = depth + 1
        elseif p.k == "lparen" then
          if depth == 0 then
            break
          end
          depth = depth - 1
        elseif depth == 0 and is_word(p, "select", "insert", "merge", "output") then
          owner = lower(p)
          break
        end
      end
      if owner == "select" then
        add(
          t,
          "S8",
          "временная таблица — через CREATE TABLE, не select … into " .. sig[i + 1].s
        )
      end
    end
  end
end

-- S42: для двух аргументов — ISNULL(), не COALESCE().
function rules.coalesce(sig, add)
  for i, t in ipairs(sig) do
    if call(sig, i, "coalesce") then
      local e = close_paren(sig, i + 1)
      local depth, commas = 0, 0
      for j = i + 1, e or 0 do
        local k = sig[j].k
        depth = depth + (k == "lparen" and 1 or k == "rparen" and -1 or 0)
        if depth == 1 and k == "comma" then
          commas = commas + 1
        end
      end
      if e and commas == 1 then
        add(t, "S42", "для двух аргументов — ISNULL(), не COALESCE()")
      end
    end
  end
end

-- S33: часть даты — полным словом.
function rules.date_part(sig, add)
  for i, t in ipairs(sig) do
    local part = sig[i + 2]
    if tok.DATE_FUNCS[lower(t) or ""] and call(sig, i, lower(t)) and part and part.k == "word" then
      local full = tok.DATE_PARTS[part.s:lower()]
      if full and full ~= part.s:lower() then
        add(part, "S33", ("часть даты полностью: `%s`, не `%s`"):format(full, part.s))
      end
    end
  end
end

-- S29: `exists (` — скобка на той же строке, через один пробел.
function rules.exists(sig, add)
  for i, t in ipairs(sig) do
    local p = sig[i + 1]
    if is_word(t, "exists") and p and p.k == "lparen" and (p.l ~= t.el or p.sp ~= 1) then
      add(t, "S29", "`exists (` — скобка на той же строке, через один пробел")
    end
  end
end

-- P14: IP-объект (cht_IPGetRooms) зовут только из других dbo-объектов, права там даёт
-- цепочка владения — GRANT на него лишний.
function rules.grant_ip(sig, add)
  for i, t in ipairs(sig) do
    if is_word(t, "grant") and line_start(sig, i) then
      local j = i + 1
      while sig[j] and not is_word(sig[j], "on", "to") and sig[j].l == t.l do
        j = j + 1
      end
      if is_word(sig[j], "on") then
        local k, name = j + 1, nil
        while sig[k] and (sig[k].k == "word" or sig[k].k == "ident") do
          name = unbracket(sig[k].s)
          if not (sig[k + 1] and sig[k + 1].k == "dot") then
            break
          end
          k = k + 2
        end
        if name and name:match("^%w+_IP%u") then
          add(
            t,
            "P14",
            ("на IP-объект GRANT не даётся: %s зовут только из dbo-объектов"):format(
              name
            ),
            sig[k]
          )
        end
      end
    end
  end
end

-- S52: case никогда не пишется в одну строку.
function rules.case_line(sig, add)
  for i, t in ipairs(sig) do
    if is_word(t, "case") then
      local depth = 0
      for j = i, #sig do
        if is_word(sig[j], "case") then
          depth = depth + 1
        elseif is_word(sig[j], "end") then
          depth = depth - 1
          if depth == 0 then
            if sig[j].l == t.l then
              add(
                t,
                "S52",
                "case не пишется в одну строку; бинарный выбор — IIF()",
                sig[j]
              )
            end
            break
          end
        end
      end
    end
  end
end

-- S54: begin — отдельной строкой под условием; `end else` — одной строкой.
-- closes из предпрохода отличает end блока от end у case: `end` вложенного case, а за
-- ним else внешнего case на новой строке — это нормально.
function rules.begin_end(sig, add)
  for i, t in ipairs(sig) do
    local nxt = sig[i + 1]
    if is_word(t, "begin") and block_begin(sig, i) == "begin" then
      local p = sig[i - 1]
      if p and p.el == t.l and not is_word(p, "as") then
        add(t, "S54", "begin — отдельной строкой под условием")
      end
    elseif is_word(t, "end") and t.closes == "begin" and is_word(nxt, "else") and nxt.l ~= t.el then
      add(nxt, "S54", "`end else` — одной строкой")
    end
  end
end

-- S12: при вызове процедуры — только именованные параметры, каждый на своей строке,
-- значение — переменная или константа, не выражение (T-SQL такое и не компилирует).
local function atom(sig, k)
  local t = sig[k]
  if not t then
    return nil
  end
  if t.k == "var" or t.k == "number" or t.k == "string" or t.k == "ident" then
    return k
  end
  if t.k == "word" and not (sig[k + 1] and (sig[k + 1].k == "lparen" or sig[k + 1].k == "dot")) then
    return k -- NULL, default, константа-слово
  end
  if t.k == "op" and t.s == "-" and sig[k + 1] and sig[k + 1].k == "number" and sig[k + 1].sp == 0 then
    return k + 1 -- отрицательное число — тоже константа
  end
end

---Начинается ли с t параметр. После запятой — что угодно; иначе слово считаем
---параметром (exec p Value1) только на той же строке и если оно не ключевое: со
---следующей строки начинается уже следующая инструкция.
local function arg_start(t, prev)
  if not t then
    return false
  end
  if prev and prev.k == "comma" then
    return true
  end
  if t.k == "var" or t.k == "number" or t.k == "string" or t.k == "op" or is_word(t, "null", "default") then
    return true
  end
  return t.k == "word" and prev and t.l == prev.l and not tok.is_keyword(t)
end

function rules.exec_params(sig, add)
  for i in ipairs(sig) do
    local call = parse_exec(sig, i)
    if call then
      local k = call.k
      do
        local prev_line, first = nil, true
        while arg_start(sig[k], sig[k - 1]) do
          local a = sig[k]
          local v = k
          if a.k == "var" and sig[k + 1] and sig[k + 1].k == "op" and sig[k + 1].s == "=" then
            v = k + 2
            if not first and a.l == prev_line then
              add(a, "S12", "каждый параметр — на своей строке")
            end
          else
            add(a, "S12", "только именованные параметры: @Param = значение")
          end
          prev_line, first = a.l, false
          local e = atom(sig, v)
          if e and is_word(sig[e + 1], "out", "output") then
            e = e + 1
          end
          -- за значением на той же строке ещё оператор или скобка — это выражение;
          -- на следующей строке — уже следующая инструкция
          local after = e and sig[e + 1]
          local cont = after and after.l == sig[e].l and (after.k == "op" or after.k == "lparen" or after.k == "dot")
          if not sig[v] then
            break
          end
          if not e or cont then
            add(
              sig[v],
              "S12",
              "значение параметра — переменная или константа, не выражение"
            )
            -- выражение кончается запятой или переводом строки вне скобок
            local depth, j = 0, v
            while sig[j] do
              local s = sig[j]
              if depth == 0 and j > v and (s.k == "comma" or s.k == "semi" or s.l ~= sig[j - 1].l) then
                break
              end
              depth = depth + (s.k == "lparen" and 1 or s.k == "rparen" and -1 or 0)
              j = j + 1
            end
            e = j - 1
          end
          k = e + 1
          if sig[k] and sig[k].k == "comma" then
            k = k + 1
          else
            break
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Структурные правила (HINT). Получают ещё ctx из annotate: батчи и процедуры в них.

local STRUCT = tok.set("S7 S9 S22 S24 S32 S34 S51 S55 S64 S65 A2 A6 B1")

---Батчи с процедурой: только к ним относится «в начале / в конце процедуры».
local function procs(ctx)
  return vim.tbl_filter(function(b)
    return b.proc ~= nil
  end, ctx.batches)
end

-- S55: тело if / else — всегда в begin … end, и else if тоже: ветка без скобок молча
-- выпадает из условия, как только к ней допишут вторую строку.
function rules.if_body(sig, add)
  for i, t in ipairs(sig) do
    -- DROP TABLE IF EXISTS #x — не условие: после exists нет скобки
    local ddl = is_word(sig[i + 1], "exists") and not (sig[i + 2] and sig[i + 2].k == "lparen")
    if is_word(t, "if") and not ddl then
      local j = cond_end(sig, i)
      if j and not (is_word(sig[j], "begin") and block_begin(sig, j)) then
        add(t, "S55", "тело if — в begin … end, даже из одной инструкции")
      end
    elseif is_word(t, "else") and not t.case_else then
      local n = sig[i + 1]
      if n and not (is_word(n, "begin") and block_begin(sig, i + 1)) then
        add(t, "S55", "ветка else — в begin … end (else if — тоже)")
      end
    end
  end
end

-- S32: успешный выход один — RETURN 0 в самом конце. Ранний RETURN 0 молча обходит
-- общий хвост (DROP TABLE IF EXISTS, логирование), который добавят в конец.
function rules.return_zero(sig, add, ctx)
  for _, b in ipairs(procs(ctx)) do
    for i = b.first, b.last do
      local n = sig[i + 1]
      if is_word(sig[i], "return") and n and n.k == "number" and tonumber(n.s) == 0 then
        -- последний, если дальше только end-ы до END процедуры
        local last = true
        for j = i + 2, b.proc_end or b.last do
          if not (is_word(sig[j], "end") or sig[j].k == "semi") then
            last = false
            break
          end
        end
        if not last then
          add(
            sig[i],
            "S32",
            "успешный выход один — RETURN 0 в конце; здесь — обратить условие",
            n
          )
        end
      end
    end
  end
end

-- S9: DROP TABLE IF EXISTS перед каждым CREATE TABLE #… и в конце процедуры.
function rules.temp_drop(sig, add, ctx)
  for _, b in ipairs(ctx.batches) do
    local creates, drops, last_ref = {}, {}, {}
    for i = b.first, b.last do
      local t = sig[i]
      if t.k == "temp" then
        local name = t.s:lower()
        last_ref[name] = i
        if is_word(sig[i - 1], "table") and is_word(sig[i - 2], "create") then
          creates[#creates + 1] = { i = i, name = name, at = sig[i - 2] }
        elseif is_word(sig[i - 1], "exists") and is_word(sig[i - 2], "if") and is_word(sig[i - 3], "table") then
          drops[name] = drops[name] or {}
          table.insert(drops[name], i)
        elseif is_word(sig[i - 1], "table") and is_word(sig[i - 2], "drop") then
          drops[name] = drops[name] or {}
          table.insert(drops[name], -i) -- DROP без IF EXISTS: годится только в конце
        end
      end
    end
    for _, c in ipairs(creates) do
      local before, at_end = false, false
      for _, d in ipairs(drops[c.name] or {}) do
        before = before or (d > 0 and d < c.i)
        at_end = at_end or math.abs(d) == last_ref[c.name]
      end
      if not before then
        add(c.at, "S9", ("перед CREATE TABLE — DROP TABLE IF EXISTS %s"):format(sig[c.i].s), sig[c.i])
      end
      if b.proc and not at_end then
        add(c.at, "S9", ("в конце процедуры — DROP TABLE IF EXISTS %s"):format(sig[c.i].s), sig[c.i])
      end
    end
  end
end

-- S7: один блок declare в начале процедуры, одна переменная — одна строка.
function rules.declare_block(sig, add, ctx)
  for _, b in ipairs(procs(ctx)) do
    local seen = false
    for i = b.first, b.last do
      local t = sig[i]
      -- declare c cursor — курсор, про него S4; declare @t table (…) с другими
      -- переменными в один declare не объединить — это не второй блок
      local n = sig[i + 1]
      local table_var = n and n.k == "var" and is_word(sig[i + 2], "table")
      if is_word(t, "declare") and line_start(sig, i) and not (n and n.k == "word") and not table_var then
        if seen then
          add(t, "S7", "один блок declare — в начале процедуры")
        end
        seen = true
        -- в пределах блока: строки начинаются с запятой или с переменной
        local j = i + 1
        while j <= b.last do
          local s = sig[j]
          if s.d == t.d and line_start(sig, j) and j > i + 1 and s.k ~= "comma" and sig[j - 1].k ~= "comma" then
            break
          end
          -- висячая запятая в конце строки — это S2, дело форматтера
          local v = sig[j + 1]
          if s.d == t.d and s.k == "comma" and not line_start(sig, j) and v and v.k == "var" and v.l == s.el then
            add(sig[j + 1], "S7", "одна переменная — одна строка")
          end
          j = j + 1
        end
      end
    end
  end
end

-- S34 / S51: после insert — во временную таблицу @@ERROR не проверяют, в постоянную
-- (в процедуре) — проверяют обязательно; после вызова процедуры — exec @ret = … и
-- if @@ERROR <> 0 or @ret <> 0.
function rules.error_checks(sig, add, ctx)
  for i, t in ipairs(sig) do
    local b = ctx.batches[t.b]
    if is_word(t, "insert") and not after_dot(sig, i) then
      local target = is_word(sig[i + 1], "into") and sig[i + 2] or sig[i + 1]
      local j = next_statement(sig, i)
      -- insert … exec проверяется как вызов процедуры
      local via_exec = false
      for k = i + 1, (j or b.last + 1) - 1 do
        if sig[k].d == t.d and is_word(sig[k], "exec", "execute") then
          via_exec = true
        end
      end
      local checked = j and checks_error(sig, j)
      if not target or via_exec or target.k == "lparen" or is_word(target, "values", "default") then
        -- insert в merge — без имени таблицы
      elseif target.k == "temp" or target.k == "var" then
        if checked then
          add(
            sig[j],
            "S34",
            "после вставки во временную таблицу @@ERROR не проверяется"
          )
        end
      elseif b.proc and not checked and not t.in_try then
        add(
          t,
          "S51",
          "после insert в постоянную таблицу — if @@ERROR <> 0 с RAISERROR(60004, …)"
        )
      end
    elseif b.proc then
      local call = parse_exec(sig, i)
      if call and call.db then
        -- msdb.dbo.sysmail_… — системное, не наш код возврата
      elseif call and not call.ret then
        add(
          t,
          "S51",
          "exec @ret = …: без кода возврата ошибку процедуры не проверить"
        )
      elseif call then
        local j = next_statement(sig, i)
        if not (j and checks_error(sig, j, call.ret.s)) then
          add(
            t,
            "S51",
            ("после вызова — if @@ERROR <> 0 or %s <> 0 с RAISERROR(60003, …)"):format(call.ret.s)
          )
        end
      end
    end
  end
end

-- S22: не повторять вызов функции — значение один раз в переменную. Только вызовы без
-- аргументов (GETDATE(), dbo.em_GetEmIDByLogin()): с аргументами это чаще разные
-- вычисления. Функции, которые обязаны давать новое значение на каждый вызов или
-- зависят от места (NEWID, SCOPE_IDENTITY, ERROR_*), и оконные (… over) — не в счёт.
local VOLATILE = tok.set([[
  newid newsequentialid rand scope_identity xact_state rowcount_big error_message
  error_number error_line error_procedure error_severity error_state row_number rank
  dense_rank cume_dist percent_rank
]])

function rules.repeated_call(sig, add, ctx)
  for _, b in ipairs(ctx.batches) do
    local seen = {}
    for i = b.first, b.last do
      local t = sig[i]
      local l, r = sig[i + 1], sig[i + 2]
      if (t.k == "word" or t.k == "ident") and l and l.k == "lparen" and r and r.k == "rparen" then
        local a = i
        while sig[a - 1] and sig[a - 1].k == "dot" and sig[a - 2] do
          a = a - 2
        end
        local parts, shown = {}, {}
        for k = a, i, 2 do
          parts[#parts + 1] = unbracket(sig[k].s):lower()
          shown[#shown + 1] = sig[k].s
        end
        local key = table.concat(parts, ".")
        local header = is_word(sig[a - 1], "function", "procedure", "proc")
        -- DATEDIFF(second, @Start, GETDATE()) — замер времени: там нужен именно новый вызов
        local timing = false
        if sig[a - 1] and sig[a - 1].k == "comma" and sig[a].d > 0 then
          local o = a - 1
          while o > 1 and sig[o].d >= sig[a].d do
            o = o - 1
          end
          timing = is_word(sig[o - 1], "datediff", "datediff_big")
        end
        if not header and not timing and not VOLATILE[parts[#parts]] and not is_word(sig[i + 3], "over") then
          if seen[key] then
            local what = table.concat(shown, ".") .. "()"
            add(
              sig[a],
              "S22",
              what
                .. " уже вызывался выше: значение — один раз в переменную",
              r
            )
          end
          seen[key] = true
        end
      end
    end
  end
end

-- S64: подзапрос в списке select — источник уходит в from (outer / cross apply, join):
-- одна apply отдаёт сразу несколько колонок, все входы запроса видны в from. exists в
-- case — то же самое. Присваивание переменным (select @x = (select …)) — не колонка
-- набора, не в счёт; как и derived table в from и exists в where — список кончается на
-- from / into / where.
local LIST_END = tok.set("from into where group order having union except intersect for option")

function rules.select_subquery(sig, add)
  local seen = {}
  for i, t in ipairs(sig) do
    if is_word(t, "select") then
      local j = i + 1
      if is_word(sig[j], "distinct", "all") then
        j = j + 1
      end
      if is_word(sig[j], "top") then
        j = sig[j + 1] and sig[j + 1].k == "lparen" and (close_paren(sig, j + 1) or j) + 1 or j + 2
        if is_word(sig[j], "percent") then
          j = j + 1
        end
        if is_word(sig[j], "with") and is_word(sig[j + 1], "ties") then
          j = j + 2
        end
      end
      local assign = sig[j] and sig[j].k == "var" and sig[j + 1] and sig[j + 1].s == "="
      while not assign and sig[j] and sig[j].b == t.b and sig[j].d >= t.d do
        local s = sig[j]
        if s.d == t.d and (LIST_END[lower(s) or ""] or line_start(sig, j) and stmt_word(sig, j)) then
          break
        end
        if s.d > t.d and is_word(s, "select") and not seen[j] then
          seen[j] = true
          add(
            s,
            "S64",
            "подзапрос в списке select — источник в from: outer apply / cross apply / join"
          )
        end
        j = j + 1
      end
    end
  end
end

-- S65: временные таблицы объявляются сразу за блоком declare, до проверок параметров:
-- вверху процедуры видно всё, с чем она работает. До CREATE TABLE #… в теле допустимы
-- только SET NOCOUNT / declare / set, DROP TABLE IF EXISTS и другие CREATE TABLE #.
local BEFORE_TEMP = tok.set("declare set drop create begin")

function rules.temp_top(sig, add, ctx)
  for _, b in ipairs(procs(ctx)) do
    local stray -- первая инструкция тела, после которой temp-таблицу уже поздно создавать
    for i = (b.proc_begin or b.last) + 1, b.proc_end or b.last do
      local t = sig[i]
      if t.d == 0 and line_start(sig, i) then
        local temp = is_word(t, "create") and is_word(sig[i + 1], "table") and sig[i + 2] and sig[i + 2].k == "temp"
        if temp and stray then
          add(
            t,
            "S65",
            ("CREATE TABLE %s — сразу после declare, до проверок и тела"):format(
              sig[i + 2].s
            ),
            sig[i + 2]
          )
        elseif not stray and (stmt_word(sig, i) or is_word(t, "select", "with")) and not BEFORE_TEMP[lower(t)] then
          stray = t
        end
      end
    end
  end
end

-- P16: тело закрывается голым END — `END -- procedure` остался от файлов с несколькими
-- процедурами, при одной на файл это очевидный комментарий (S57).
function rules.bare_end(sig, add, ctx)
  for _, b in ipairs(ctx.batches) do
    local e = b.proc_end and sig[b.proc_end]
    local rec = e and ctx.recs[e.ri]
    local c = rec and rec.toks[e.ti + 1]
    if c and is_comment(c) and c.l == e.l then
      add(c, "P16", "тело закрывается голым END, без комментария")
    end
  end
end

-- S24: Get-процедура не сортирует выходной набор — сортирует форма. order by в top,
-- в over (…), within group (…), в присваивании переменным и в insert … select — не
-- выходной набор.
function rules.get_order(sig, add, ctx)
  for _, b in ipairs(procs(ctx)) do
    if b.proc:lower():find("_get") or b.proc:lower():find("^get") then
      for i = b.first, b.last do
        local t = sig[i]
        if is_word(t, "order") and is_word(sig[i + 1], "by") and t.d == 0 then
          -- владелец — ближайший select той же глубины
          local s = i - 1
          while s >= b.first and not (sig[s].d == t.d and is_word(sig[s], "select")) do
            s = s - 1
          end
          local own = s >= b.first and sig[s]
          local n = own and sig[s + 1]
          local assign = n and n.k == "var" and sig[s + 2] and sig[s + 2].s == "="
          local into = false
          for k = s + 1, i - 1 do
            into = into or (sig[k].d == t.d and is_word(sig[k], "into"))
          end
          -- инструкция, которой принадлежит select: insert … select — не вывод
          local p = s - 1
          while p >= b.first and not (sig[p].d == t.d and line_start(sig, p) and stmt_word(sig, p)) do
            p = p - 1
          end
          local in_insert = p >= b.first and is_word(sig[p], "insert", "declare", "set")
          if own and not is_word(n, "top") and not assign and not into and not in_insert then
            add(
              t,
              "S24",
              "Get-процедура не сортирует выходной набор — это делает форма",
              sig[i + 1]
            )
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Гигиена переменных и алиасов: скилл mssql-repo-skills:task-blockers, §A.2 / §A.6 /
-- §B.1 (там же hygiene.awk — то же самое, но построчными регулярками).
--
-- Находка про объявление стоит на строке declare, а появиться может от правки совсем
-- в другом месте (удалили последнее чтение) — по одним изменённым строкам её бы не
-- было видно. Поэтому эти правила передают в add span батча и показываются, если в
-- батче (процедуре) изменена хоть одна строка.

-- Слова, открывающие список: по ближайшему из них решаем, чем переменная в этом месте
-- является — целью присваивания (select / set), целью into, именем параметра exec или
-- просто чтением. top здесь нет: в select top 1 @a = x решает select.
local CLAUSE = tok.set([[
  select set where on and or when then else having from join if while return exec execute
  declare into values by not case print raiserror begin end
]])
local COMPOUND = tok.set("+= -= *= /= %= &= |= ^=")

---Ближайшее слово из CLAUSE на той же глубине перед j (или начало инструкции), или nil,
---если раньше кончилась скобка, в которой стоит j. case … end перед j пропускается
---целиком: в select @a = case … end, @b = x решает select, а не when / end.
local function clause_of(sig, j, first)
  local d, cases = sig[j].d, 0
  for k = j - 1, first, -1 do
    local s = sig[k]
    if s.d < d then
      return nil
    end
    if s.d == d then
      if s.closes == "case" then
        cases = cases + 1
      elseif cases > 0 then
        cases = cases - (is_word(s, "case") and 1 or 0)
      elseif CLAUSE[lower(s) or ""] or (line_start(sig, k) and stmt_word(sig, k)) then
        return k
      end
    end
  end
end

---Что делает с переменной токен j: "read", "write", "rw" (set @s += …) или "skip" —
---имя параметра вызываемой процедуры в exec p @Param = @x, к этой процедуре не
---относится (а значение справа от него — читается, или пишется, если out).
local function var_role(sig, j, first)
  local prev, nxt = sig[j - 1], sig[j + 1]
  if is_word(nxt, "out", "output") then
    return "write"
  end
  -- таблица-переменная пишется как цель DML, а не через `=`: без этого любая
  -- declare @t table выглядела бы «никогда не заполняемой»
  if
    is_word(prev, "update", "delete", "merge", "insert") or (is_word(prev, "from") and is_word(sig[j - 2], "delete"))
  then
    return "write"
  end
  local assign = nxt and nxt.k == "op" and (nxt.s == "=" or COMPOUND[nxt.s])
  local h = clause_of(sig, j, first)
  local hw = h and lower(sig[h])
  if hw == "into" then
    return "write" -- fetch … into @a, @b / insert into @t / output … into @t
  end
  if assign and (hw == "select" or hw == "set") then
    return COMPOUND[nxt.s] and "rw" or "write"
  end
  if assign and (hw == "exec" or hw == "execute") then
    return h == j - 1 and "write" or "skip" -- exec @ret = p — это уже наша переменная
  end
  return "read"
end

---Объявления в батче: declare @a int = 0, @t table (…). Возвращает список
---{ name, si, table } в порядке объявления, набор индексов самих объявлений и индексы
---`=` инициализаторов по именам (инициализатор — тоже запись).
local function declarations(sig, b)
  local list, at, init = {}, {}, {}
  for i = b.first, b.last do
    if is_word(sig[i], "declare") then
      local d, expect, cur = sig[i].d, true, nil
      for j = i + 1, b.last do
        local s = sig[j]
        if s.d < d or s.k == "semi" and s.d == d then
          break
        end
        if s.d == d then
          -- блок declare — строки, начинающиеся с запятой или после висячей запятой
          if j > i + 1 and line_start(sig, j) and s.k ~= "comma" and sig[j - 1].k ~= "comma" then
            break
          end
          if expect then
            if s.k ~= "var" then
              break -- declare c cursor — курсор, не переменная
            end
            cur = s.s:lower()
            list[#list + 1] = { name = cur, si = j, table = is_word(sig[j + 1], "table") }
            at[j], expect = true, false
          elseif s.k == "comma" then
            expect = true
          elseif s.k == "op" and s.s == "=" and not init[cur] then
            init[cur] = j
          end
        end
      end
    end
  end
  return list, at, init
end

---Строки батча (с 1) — span для add.
local function batch_span(sig, b)
  return { sig[b.first].l, sig[b.last].el }
end

-- §A.2: объявлена и не используется / только пишется. §A.6: читается, но нигде не
-- присваивается (всегда NULL), или первое чтение раньше первой записи — класс, который
-- подсчёт вхождений не видит: переменная выглядит вполне используемой.
function rules.var_hygiene(sig, add, ctx)
  for _, b in ipairs(ctx.batches) do
    if b.first <= b.last then
      local decls, at, init = declarations(sig, b)
      if #decls > 0 then
        local use = {}
        local function note(name, kind, j)
          local u = use[name] or { reads = 0, writes = 0 }
          use[name] = u
          if kind == "read" then
            u.reads = u.reads + 1
            if not u.read then
              u.read = j
            end
          else
            u.writes = u.writes + 1
            u.write = u.write or j
          end
        end
        for name, j in pairs(init) do
          note(name, "write", j)
        end
        for j = b.first, b.last do
          local t = sig[j]
          if t.k == "var" and not at[j] and not t.s:find("^@@") then
            local role, name = var_role(sig, j, b.first), t.s:lower()
            if role == "rw" then
              -- set @s += 'x' без начального значения — тоже NULL: чтение раньше записи
              note(name, "read", j)
              note(name, "write", j + 0.5)
            elseif role ~= "skip" then
              note(name, role, j)
            end
          end
        end
        local span = batch_span(sig, b)
        for _, dcl in ipairs(decls) do
          local u = use[dcl.name] or { reads = 0, writes = 0 }
          local t, v = sig[dcl.si], sig[dcl.si].s
          if u.reads == 0 and u.writes == 0 then
            add(t, "A2", v .. " объявлена, но не используется", nil, span)
          elseif u.reads == 0 then
            add(
              t,
              "A2",
              v
                .. (dcl.table and " заполняется" or " присваивается")
                .. ", но не читается",
              nil,
              span
            )
          elseif u.writes == 0 then
            add(
              sig[u.read],
              "A6",
              v
                .. (
                  dcl.table
                    and " читается, но нигде не заполняется — всегда пустая"
                  or " читается, но нигде не присваивается — всегда NULL"
                ),
              nil,
              span
            )
          elseif u.read < u.write then
            add(
              sig[u.read],
              "A6",
              ("%s читается раньше, чем %s (строка %d) — здесь ещё %s; в цикле — проверить первую итерацию"):format(
                v,
                dcl.table and "заполняется" or "присваивается",
                sig[math.floor(u.write)].l,
                dcl.table and "пустая" or "NULL"
              ),
              nil,
              span
            )
          end
        end
      end
    end
  end
end

-- После таблицы-источника: здесь её алиас кончился или его не было.
local CLAUSE_END = tok.set([[
  join inner left right full cross outer where group order having union except intersect
  option from apply for
]])

---Источник в from / join / apply с позиции k: таблица (с точками), @t, #t, функция
---dbo.f(…) или (подзапрос). Возвращает индекс алиаса (или nil) и индекс за источником.
local function source_alias(sig, k)
  local t = sig[k]
  if not t then
    return nil, k
  end
  if t.k == "lparen" then
    k = (close_paren(sig, k) or #sig) + 1
  elseif t.k == "word" or t.k == "ident" or t.k == "temp" or t.k == "var" then
    while sig[k + 1] and sig[k + 1].k == "dot" and sig[k + 2] do
      k = k + 2
    end
    k = k + 1
    if sig[k] and sig[k].k == "lparen" then
      k = (close_paren(sig, k) or #sig) + 1
    end
  else
    return nil, k
  end
  if is_word(sig[k], "as") then
    k = k + 1
  end
  local a = sig[k]
  -- алиас — на той же строке: со следующей начинается уже следующая инструкция
  if a and a.k == "word" and a.l == sig[k - 1].el and not tok.is_keyword(a) and not stmt_word(sig, k) then
    return k, k + 1
  end
  return nil, k
end

---Где виден алиас источника в позиции i: внутри скобок — до их конца, на верхнем
---уровне — в пределах инструкции. set после update — не новая инструкция, а её часть
---(update t set … from T t), как и end / else от case в начале строки.
local function alias_scope(sig, i, b)
  local d = sig[i].d
  if d > 0 then
    for k = i - 1, b.first, -1 do
      if sig[k].k == "lparen" and sig[k].d == d - 1 then
        return k + 1, (close_paren(sig, k) or b.last + 1) - 1
      end
    end
    return b.first, b.last
  end
  local function boundary(k)
    local s = sig[k]
    local part = is_word(s, "set") or s.closes == "case" or s.case_else
    return s.d == 0 and line_start(sig, k) and ((stmt_word(sig, k) and not part) or is_word(s, "select", "with"))
  end
  local first, last = b.first, b.last
  for k = i, b.first, -1 do
    if boundary(k) then
      first = k
      break
    end
  end
  for k = i + 1, b.last do
    if boundary(k) then
      last = k - 1
      break
    end
  end
  return first, last
end

-- §B.1: алиас в from / join, на который нигде не ссылаются. «Только в своём ON» —
-- лишь у outer join: left join, из которого ничего не берут, результат не меняет (разве
-- что размножает строки), а inner join с одним ON — обычный фильтр (update t … join
-- @Items s on s.ID = t.ID), их в каждой процедуре десятки. Только там, где источников
-- больше одного: в однотабличном запросе голые имена колонок однозначны.
function rules.alias_hygiene(sig, add, ctx)
  for _, b in ipairs(ctx.batches) do
    local scopes, span = {}, nil
    for i = b.first, b.last do
      if is_word(sig[i], "from", "join", "apply") and not after_dot(sig, i) then
        local first, last = alias_scope(sig, i, b)
        local key = first .. ":" .. last
        local sc = scopes[key] or { first = first, last = last, n = 0, aliases = {} }
        scopes[key] = sc
        local k = i + 1
        repeat
          local a, nxt = source_alias(sig, k)
          sc.n = sc.n + 1
          if a then
            local p = is_word(sig[i - 1], "outer") and i - 2 or i - 1
            sc.aliases[#sc.aliases + 1] = {
              si = a,
              join = is_word(sig[i], "join"),
              outer = is_word(sig[i], "join") and is_word(sig[p], "left", "right", "full"),
            }
          end
          -- from A a, B b — источники через запятую
          local more = sig[nxt] and sig[nxt].k == "comma" and sig[nxt].d == sig[i].d and is_word(sig[i], "from")
          k = nxt + 1
        until not more
      end
    end
    for _, sc in pairs(scopes) do
      if sc.n >= 2 then
        local seen = {}
        for _, al in ipairs(sc.aliases) do
          local a = sig[al.si]
          local name = a.s:lower()
          if not seen[name] then
            seen[name] = true
            -- свой ON: от on после алиаса до следующего join / where / … той же глубины
            local on_s, on_e = math.huge, -1
            if al.join then
              local d = a.d
              for k = al.si + 1, sc.last do
                local s = sig[k]
                if s.d < d then
                  break
                end
                if s.d == d and is_word(s, "on") then
                  on_s = k
                elseif s.d == d and on_s < k and CLAUSE_END[lower(s) or ""] then
                  break
                end
                on_e = k
              end
            end
            local inside, outside, target = 0, 0, false
            for k = sc.first, sc.last do
              local s = sig[k]
              local w = (s.k == "word" or s.k == "ident") and unbracket(s.s):lower()
              if w == name then
                if sig[k + 1] and sig[k + 1].k == "dot" and not after_dot(sig, k) then
                  if k >= on_s and k <= on_e then
                    inside = inside + 1
                  else
                    outside = outside + 1
                  end
                elseif is_word(sig[k - 1], "update", "delete") then
                  target = true -- update t set … from T t: алиас — цель DML
                end
              end
            end
            if outside == 0 and not target and (inside == 0 or al.outer) then
              span = span or batch_span(sig, b)
              add(
                a,
                "B1",
                inside > 0
                    and ("алиас %s используется только в своём ON — outer join лишний?"):format(
                      a.s
                    )
                  or ("алиас %s нигде не используется"):format(a.s),
                nil,
                span
              )
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------

---Найти нарушения в тексте. Строки и колонки — с 0, как у vim.diagnostic.
---@param lines string[]
---span — строки батча (с 1), если находку надо показывать при любом изменении в нём.
---@return { lnum: integer, col: integer, end_lnum: integer, end_col: integer, code: string, message: string, severity: integer, span?: integer[] }[]
function M.check(lines)
  local recs = tok.tokenize(table.concat(lines, "\n"), 4)
  local sig = tok.flatten(recs)
  local ctx = annotate(sig)
  ctx.recs = recs
  local out = {}
  local function add(t, code, msg, last, span)
    last = last or t
    local tail = last.s:match("[^\n]*$")
    local nl = select(2, last.s:gsub("\n", ""))
    out[#out + 1] = {
      lnum = t.l - 1,
      col = t.c,
      end_lnum = last.l - 1 + nl,
      end_col = (nl > 0 and 0 or last.c) + #tail,
      code = code,
      message = code .. ": " .. msg,
      severity = STRUCT[code] and vim.diagnostic.severity.HINT or vim.diagnostic.severity.WARN,
      span = span,
    }
  end
  -- S1 — по сырым табам, в sp они уже раскрыты. Одна находка на строку.
  local seen = {}
  for _, tab in ipairs(recs.tabs) do
    if not seen[tab.l] then
      seen[tab.l] = true
      add(
        { l = tab.l, c = tab.c, s = "\t" },
        "S1",
        "табуляция запрещена: отступ — 2 пробела"
      )
    end
  end
  for _, rule in pairs(rules) do
    rule(sig, add, ctx)
  end
  table.sort(out, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  return out
end

---------------------------------------------------------------------------------------
-- Какие строки проверять

---Строки, изменённые относительно git (с 1): true — весь файл, nil — пока неизвестно
---или проверять нечего.
local function scope(buf, on_known)
  if vim.b[buf].sqllint_all then
    return true
  end
  if vim.b[buf].gitsigns_status_dict then
    local ok, gs = pcall(require, "gitsigns")
    local hunks = ok and gs.get_hunks(buf) or {}
    local set = {}
    for _, h in ipairs(hunks) do
      for l = h.added.start, h.added.start + h.added.count - 1 do
        set[l] = true
      end
    end
    return set
  end
  -- gitsigns к неотслеживаемым файлам не цепляется (attach_to_untracked = false), а
  -- новый файл — как раз главный случай: его строки все новые. Спрашиваем git сами,
  -- один раз на буфер.
  local state = vim.b[buf].sqllint_git
  if state == "untracked" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if state == nil and name ~= "" and vim.fn.filereadable(name) == 1 then
    vim.b[buf].sqllint_git = "pending"
    vim.system(
      { "git", "ls-files", "--error-unmatch", "--", vim.fs.basename(name) },
      { cwd = vim.fs.dirname(name), text = true },
      vim.schedule_wrap(function(r)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        -- 0 — отслеживается (дальше ждём gitsigns), 1 — в репозитории, но не добавлен,
        -- 128 — не репозиторий: легаси это или нет, не знаем, молчим
        vim.b[buf].sqllint_git = r.code == 0 and "tracked" or r.code == 1 and "untracked" or "none"
        on_known()
      end)
    )
  end
end

---Строки из set (true — все), которые форматтер переписал бы: находки SqlFormat.
---@param lines string[]
---@param set true|table<integer, boolean>
---@param opts? { tabstop?: integer }
function M.unformatted(lines, set, opts)
  local fmt = require("sqlkit.format")
  local out = set == true and fmt.format(lines, 1, #lines, opts) or fmt.format_lines(lines, set, opts)
  local diags = {}
  for l, line in ipairs(lines) do
    if out[l] ~= line and (set == true or set[l]) then
      local want = vim.trim(out[l])
      if vim.fn.strchars(want) > 70 then
        want = vim.fn.strcharpart(want, 0, 70) .. "…"
      end
      diags[#diags + 1] = {
        lnum = l - 1,
        col = #line:match("^%s*"),
        end_lnum = l - 1,
        end_col = #line,
        code = "SqlFormat",
        message = "SqlFormat: не по стандарту, <leader>df → " .. want,
        severity = vim.diagnostic.severity.WARN,
      }
    end
  end
  return diags
end

---Проверить буфер и выставить диагностику.
function M.lint(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "sql" then
    return
  end
  local lines_set = scope(buf, function()
    M.lint(buf)
  end)
  if not lines_set then
    vim.diagnostic.reset(ns, buf)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diags = {}
  local function touched(span)
    for l in pairs(lines_set) do
      if l >= span[1] and l <= span[2] then
        return true
      end
    end
    return false
  end
  for _, d in ipairs(M.check(lines)) do
    if lines_set == true or lines_set[d.lnum + 1] or d.span and touched(d.span) then
      d.span = nil
      diags[#diags + 1] = d
    end
  end
  if lines_set == true or next(lines_set) then
    vim.list_extend(diags, M.unformatted(lines, lines_set, { tabstop = vim.bo[buf].tabstop }))
  end
  for _, d in ipairs(diags) do
    d.source = "sqllint"
  end
  vim.diagnostic.set(ns, buf, diags)
end

function M.setup()
  vim.api.nvim_create_user_command("SqlLint", function(o)
    local buf = vim.api.nvim_get_current_buf()
    vim.b[buf].sqllint_all = o.bang or nil
    M.lint(buf)
  end, {
    bang = true,
    desc = "Проверить T-SQL по стандарту: изменённые строки, ! — весь файл (до :SqlLint без !)",
  })

  local group = vim.api.nvim_create_augroup("sqllint", { clear = true })
  -- gitsigns сообщает, когда пересчитал ханки, — только после этого известно, какие
  -- строки изменены; InsertLeave / BufWritePost — для файлов, где gitsigns нет.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    desc = "sqllint по свежим ханкам",
    callback = function(ev)
      local buf = ev.data and ev.data.buffer
      if buf then
        M.lint(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "FileType", "BufWritePost", "InsertLeave" }, {
    group = group,
    pattern = { "sql", "*.sql" },
    desc = "sqllint",
    callback = function(ev)
      M.lint(ev.buf)
    end,
  })
end

return M
