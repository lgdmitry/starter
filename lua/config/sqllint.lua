-- :SqlLint — проверка T-SQL по стандарту dgsql/esql (скилл mssql-repo-skills:sql-standards,
-- references/tsql-style.md; S<n> — его якоря, они же в начале каждого сообщения).
--
-- Почему только изменённые строки (по gitsigns), а весь файл — лишь по :SqlLint!:
-- стандарт применяется к новым и изменённым строкам, а в легаси нарушений столько, что
-- сообщение о своей строке в них бы утонуло. Новый, ещё не добавленный в git файл —
-- новый целиком, его проверяем весь.
--
-- Правила пока только те, что видны по токенам: чтобы их проверить, не нужно ни
-- понимать разметку запроса, ни знать схему базы. То, что форматтер (:SqlFormat) чинит
-- сам — регистр, пробелы, выравнивание, — здесь не проверяется: это делается
-- <leader>df, а не глазами.

local tok = require("config.sqltoken")
local lower, operand = tok.lower, tok.operand

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

-- S29: `exists(` — скобка на той же строке, без пробела.
function rules.exists(sig, add)
  for i, t in ipairs(sig) do
    local p = sig[i + 1]
    if is_word(t, "exists") and p and p.k == "lparen" and (p.l ~= t.l or p.sp > 0) then
      add(t, "S29", "`exists(` — скобка вплотную, на той же строке")
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
-- Стек begin/case нужен, чтобы отличить end блока от end у case: `end` вложенного
-- case, а за ним else внешнего case на новой строке — это нормально.
function rules.begin_end(sig, add)
  local stack = {}
  for i, t in ipairs(sig) do
    local w = lower(t)
    local nxt = sig[i + 1]
    if w == "go" and not (sig[i - 1] and sig[i - 1].l == t.l) then
      stack = {} -- следующий батч: незакрытое до GO не тянется дальше
    elseif w == "begin" then
      if is_word(nxt, "tran", "transaction", "distributed", "dialog", "conversation") then
        -- BEGIN TRAN — не блок
      elseif is_word(nxt, "try", "catch") then
        stack[#stack + 1] = "try"
      else
        stack[#stack + 1] = "begin"
        local p = sig[i - 1]
        if p and p.l == t.l and not is_word(p, "as") then
          add(t, "S54", "begin — отдельной строкой под условием")
        end
      end
    elseif w == "case" then
      stack[#stack + 1] = "case"
    elseif w == "end" then
      local top = table.remove(stack)
      if top == "begin" and is_word(nxt, "else") and nxt.l ~= t.l then
        add(nxt, "S54", "`end else` — одной строкой")
      end
    end
  end
end

-- S12: при вызове процедуры — только именованные параметры, каждый на своей строке,
-- значение — переменная или константа, не выражение (T-SQL такое и не компилирует).
-- Системные sp_* / xp_* не проверяем: у sp_executesql первые параметры позиционные по
-- самому своему устройству.
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
  for i, t in ipairs(sig) do
    -- WITH EXECUTE AS в заголовке и GRANT EXEC ON — не вызовы
    if
      is_word(t, "exec", "execute")
      and not after_dot(sig, i)
      and not is_word(sig[i - 1], "with")
      and not is_word(sig[i + 1], "on")
    then
      local k = i + 1
      if sig[k] and sig[k].k == "var" and sig[k + 1] and sig[k + 1].s == "=" then
        k = k + 2 -- exec @ret = …
      end
      local name
      while sig[k] and (sig[k].k == "word" or sig[k].k == "ident") and not is_word(sig[k], "as") do
        name = sig[k].s:gsub("^%[", ""):gsub("%]$", ""):lower()
        if sig[k + 1] and sig[k + 1].k == "dot" then
          k = k + 2
        else
          k = k + 1
          break
        end
      end
      -- без имени — exec (@sql), exec @sql, execute as: не вызов процедуры
      if name and not name:match("^sp_") and not name:match("^xp_") then
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

---Найти нарушения в тексте. Строки и колонки — с 0, как у vim.diagnostic.
---@param lines string[]
---@return { lnum: integer, col: integer, end_lnum: integer, end_col: integer, code: string, message: string }[]
function M.check(lines)
  local recs = tok.tokenize(table.concat(lines, "\n"), 4)
  local sig = tok.flatten(recs)
  local out = {}
  local function add(t, code, msg, last)
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
    rule(sig, add)
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
  local diags = {}
  for _, d in ipairs(M.check(vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
    if lines_set == true or lines_set[d.lnum + 1] then
      d.severity = vim.diagnostic.severity.WARN
      d.source = "sqllint"
      diags[#diags + 1] = d
    end
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
