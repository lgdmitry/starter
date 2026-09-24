-- Отступ новой строки в T-SQL (indentexpr) по стандарту dgsql/esql (tsql-style.md §1, §14).
--
-- Treesitter-отступ здесь бесполезен: грамматика sql из nvim-treesitter T-SQL почти не
-- разбирает (процедура без `;` — сплошной ERROR), и indents.scm отдаёт 0 чуть ли не для
-- каждой строки, а после `end` даже -2. Родной indent/sql.vim писан под другой диалект
-- (отступ после `as`, `from` на +4). Поэтому свои простые правила: держать отступ
-- предыдущей строки и сдвигать только там, где стандарт однозначен. Раскладку операторов
-- по клаузам это не делает — это не форматтер (:SqlFormat), а помощь при наборе.
--
-- Строки разбираются поодиночке (многострочный комментарий или литерал собьёт правило
-- на своих строках) — токенизировать весь файл на каждый <CR> ради этого не стоит.

local tok = require("config.sqltoken")

local M = {}

---Сколько строк назад искать пару для `end` / `)` / клаузы: дальше — уже не помощь.
local LOOKBACK = 300

---Клаузы, которые стоят в колонке своего select (S48).
local CLAUSES = tok.set("from where group order having union except intersect")

---Слова, после которых идёт список, начинающийся с первого элемента на +3 (S2).
local LIST_OPENERS = tok.set("select declare")

---Значимые токены строки (без комментариев) и её отступ.
local function parse(line)
  local rec = tok.tokenize(line, 8)[1]
  local sig = {}
  for _, t in ipairs(rec.toks) do
    if not tok.is_comment(t) then
      sig[#sig + 1] = t
    end
  end
  return sig, #sig > 0 and rec.indent or nil
end

local function word(t)
  return tok.lower(t)
end

---Экранная колонка токена: байтовая c у многобайтных символов перед ним врёт.
local function column(line, t)
  return vim.api.nvim_strwidth(line:sub(1, t.c))
end

---`begin`, открывающий блок: `begin tran` / `begin distributed transaction` — нет.
local function opens_block(sig, i)
  if word(sig[i]) ~= "begin" then
    return false
  end
  local nxt = word(sig[i + 1])
  return nxt ~= "tran" and nxt ~= "transaction" and nxt ~= "distributed"
end

---Назад от строки lnum - 1, токены каждой строки справа налево. visit(t, sig, i, line, l)
---возвращает отступ, когда нашёл, что искал, false — искать дальше нет смысла (вернётся
---false). `go` — граница батча, дальше не смотрим.
local function scan_back(get, lnum, visit)
  for l = lnum - 1, math.max(1, lnum - LOOKBACK), -1 do
    local line = get(l)
    local sig = parse(line)
    if #sig == 1 and word(sig[1]) == "go" then
      return nil
    end
    for i = #sig, 1, -1 do
      local r = visit(sig[i], sig, i, line, l)
      if r ~= nil then
        return r
      end
    end
  end
end

---Для `end` — отступ строки с его `begin` (или колонка `case`).
local function match_end(get, lnum)
  local depth = 0
  return scan_back(get, lnum, function(t, sig, i, line)
    local w = word(t)
    if w == "end" then
      depth = depth + 1
    elseif w == "case" or opens_block(sig, i) then
      if depth == 0 then
        return w == "case" and column(line, t) or select(2, parse(line))
      end
      depth = depth - 1
    end
  end)
end

---Для `)` в начале строки — отступ строки с парной `(` (стандарт закрывает скобку на
---уровне той строки, где она открылась: `) AS BEGIN`, `) s on ...`).
local function match_paren(get, lnum)
  local depth = 0
  return scan_back(get, lnum, function(t, _, _, line)
    if t.k == "rparen" then
      depth = depth + 1
    elseif t.k == "lparen" then
      if depth == 0 then
        return select(2, parse(line))
      end
      depth = depth - 1
    end
  end)
end

---Для from / where / ... — колонка select своего запроса: вложенные подзапросы в скобках
---пропускаются, а выход за открывающую скобку значит, что запрос начался на ней же.
local function match_select(get, lnum)
  local depth = 0
  return scan_back(get, lnum, function(t, sig, i, line)
    local w = word(t)
    if t.k == "rparen" then
      depth = depth + 1
    elseif t.k == "lparen" then
      depth = depth - 1
      if depth < 0 then
        return false
      end
    elseif depth == 0 then
      if w == "select" or w == "update" or w == "delete" then
        return column(line, t)
      end
      if w == "end" or opens_block(sig, i) then
        return false -- ушли за пределы оператора
      end
    end
  end) or nil
end

---Заголовок объекта: `CREATE [OR ALTER] PROCEDURE ...` и т. п.
local function is_header(sig)
  local w = word(sig[1])
  if w ~= "create" and w ~= "alter" then
    return false
  end
  local kind = word(sig[2]) == "or" and word(sig[4]) or word(sig[2])
  return kind == "procedure" or kind == "proc" or kind == "function" or kind == "trigger" or kind == "view"
end

---Для `AS` в начале строки — отступ заголовка объекта (параметры между ними на +3).
local function match_header(get, lnum)
  return scan_back(get, lnum, function(t, sig, i, line)
    if i == 1 and is_header(sig) then
      return select(2, parse(line))
    end
    if word(t) == "end" or opens_block(sig, i) then
      return false
    end
  end) or nil
end

---Отступ строки lnum. get(l) — текст строки l, sw — ширина уровня.
function M.compute(get, lnum, sw)
  local prev = lnum - 1
  local psig, pind
  while prev >= 1 do
    psig, pind = parse(get(prev))
    if pind then
      break
    end
    prev = prev - 1
  end
  if prev < 1 then
    return 0
  end

  local csig = parse(get(lnum))
  local first = csig[1]
  local fw = word(first)

  if fw == "end" then
    return match_end(get, lnum) or math.max(pind - sw, 0)
  end
  if first and first.k == "rparen" then
    return match_paren(get, lnum) or math.max(pind - sw, 0)
  end
  if fw == "as" then
    local col = match_header(get, lnum)
    if col then
      return col
    end
  end
  if fw and CLAUSES[fw] then
    local col = match_select(get, lnum)
    if col then
      return col
    end
  end

  local pfirst, plast = psig[1], psig[#psig]
  local pfw, plw = word(pfirst), word(plast)

  -- ведущая запятая — на вторую позицию уровня, под предыдущей запятой (S2)
  if first and first.k == "comma" then
    if pfirst.k == "comma" then
      return pind
    end
    if LIST_OPENERS[pfw] and #psig > 1 then
      return pind + sw -- `select a` в одну строку: список продолжается уровнем ниже
    end
    -- первый элемент стоит на +3 от открывшей список строки, запятая — на +2
    return pind % 2 == 1 and pind - 1 or pind
  end

  if opens_block(psig, #psig) or (plw == "try" or plw == "catch") and opens_block(psig, #psig - 1) then
    return pind + sw
  end
  if plast.k == "lparen" then
    return pind + sw
  end
  -- `select` / `declare` одни в строке — первый элемент на +3 (S2)
  if #psig == 1 and LIST_OPENERS[pfw] then
    return pind + sw + 1
  end
  -- `CREATE PROCEDURE имя` — параметры под ним так же на +3; с `AS` в той же строке
  -- параметров нет, а у функции они в скобках (правило для `(` выше)
  local kind = is_header(psig) and (word(psig[2]) == "or" and word(psig[4]) or word(psig[2]))
  if (kind == "procedure" or kind == "proc") and plw ~= "as" and plw ~= "begin" then
    return pind + sw + 1
  end
  return pind
end

function M.indentexpr()
  local lnum = vim.v.lnum
  return M.compute(function(l)
    return vim.fn.getline(l)
  end, lnum, vim.fn.shiftwidth())
end

---Буферу sql — свой indentexpr (из indent/sql.lua).
function M.attach(buf)
  local bo = vim.bo[buf]
  bo.indentexpr = "v:lua.require'config.sqlindent'.indentexpr()"
  -- переотступ при наборе: `end`, `)` и запятая в начале строки, клаузы запроса
  -- (`0\,` — запятая; `0<,>` Vim не понимает)
  bo.indentkeys = [[0=~end,0),0\,,0=~as,0=~from,0=~where,0=~group,0=~order,0=~having,0=~union,!^F,o,O]]
  bo.autoindent = true
  bo.smartindent = false
end

return M
