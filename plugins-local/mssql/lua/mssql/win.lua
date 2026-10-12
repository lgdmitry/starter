-- Окна с ответом sqlcmd: код объекта, строки таблицы, текст сообщения, вывод деплоя.
-- Раньше то же самое было написано дважды — в deploy и в object.
--
-- Окон на всё про всё три, и следующий ответ ложится в готовое, а не добавляет сплит:
-- код объекта — в вертикальном справа, результат запроса и вывод деплоя — в нижнем
-- (<leader>dx после <leader>dd покажет результат там же, где лежал вывод деплоя), а
-- справка по значению из них — текст сообщения, значения enum, строки таблицы, список
-- использований — в окне рядом с нижним. Справку ищут по номеру или имени прямо из
-- результата запроса (K на tvID в ответе), и в нижнем окне она затирала бы сам результат;
-- в боковом — код процедуры, из которой её смотрят.
--
-- Прошлый ответ при этом не стирается: он остаётся скрытым буфером, и <C-o> в окне
-- возвращает к нему (<C-i> — обратно). Новое окно на каждый K раскладку бы не
-- удержало, а стирать — значит терять код процедуры, от которой ушли по K к соседней.
-- Хранятся последние M.keep ответов, одинаковый ответ (тот же объект там же)
-- вытесняет прежний.
--
-- В буфере остаются две переменные:
--   b:sqlwin — вид окна, его место и куда вернуть курсор по q (кухня этого модуля);
--   b:sqlctx — где смотрели (file/conn/db). Из неё K, :SqlRows и :SqlRun внутри окна
--              берут подключение и базу, то есть ходят туда же, откуда ответ.

local M = {}

---Сколько прошлых ответов держать скрытыми буферами.
M.keep = 30

local history = {}

---Запомнить ответ; лишние — самые старые из скрытых — стереть.
local function remember(buf)
  history = vim.tbl_filter(vim.api.nvim_buf_is_valid, history)
  history[#history + 1] = buf
  local extra = #history - M.keep
  for i = 1, #history do
    if extra <= 0 then
      break
    end
    local old = history[i]
    if vim.fn.bufwinid(old) == -1 then
      pcall(vim.api.nvim_buf_delete, old, { force = true })
      extra = extra - 1
    end
  end
  history = vim.tbl_filter(vim.api.nvim_buf_is_valid, history)
end

---Имя ответа: такой же скрытый ответ (тот же объект там же) уступает имя новому, а
---видимый в другом окне — нет, тогда к имени добавляется номер буфера (имена буферов
---обязаны быть уникальными — E95).
local function set_name(buf, name)
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.api.nvim_buf_get_name(other) == name then
      if vim.fn.bufwinid(other) == -1 then
        pcall(vim.api.nvim_buf_delete, other, { force = true })
      else
        name = ("%s (%d)"):format(name, buf)
      end
      break
    end
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
end

---Справка по значению из ответа — её место рядом с нижним окном (slot "aside").
local ASIDE = { usages = true, message = true, enum = true, rows = true }

---Место окна: вертикальное — код объекта, нижнее — результат и деплой, рядом с нижним —
---справка. Виды (kind) при этом остаются разными: по ним видно, что в окне показано.
local function slot_of(o)
  if ASIDE[o.kind] then
    return "aside"
  end
  return o.bottom and "bottom" or "side"
end

---Окно на нужном месте, если оно ещё открыто в этой вкладке.
local function window_of(slot)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local w = vim.b[vim.api.nvim_win_get_buf(win)].sqlwin
    if w and w.slot == slot then
      return win
    end
  end
end

---K, gK и gf — общие для sql-буферов и окон с ответом. Живут здесь, а не в
---mssql.object: окну они нужны всегда (filetype у него бывает и пустой, так что по
---FileType они бы туда не попали), а require mssql.object отсюда замыкал бы цикл — самим
---командам тут знать нечего, это только <cmd>.
function M.map_object_keys(buf)
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

---Клавиши окна ответа: q — закрыть и вернуться туда, откуда пришли; K — посмотреть
---объект под курсором, уже в подключении и базе этого окна (b:sqlctx), gf — его файл в
---том же репозитории, откуда пришёл ответ, gK — объект на другом сервере.
local function keys(buf)
  M.map_object_keys(buf)
  vim.keymap.set("n", "q", function()
    M.close_to((vim.b[buf].sqlwin or {}).from)
  end, { buffer = buf, desc = "Закрыть окно" })
end

---Уйти из окна ответа туда, откуда в него пришли, — перед тем как открыть файл «в текущем
---окне» (постоянный запрос, выгрузка): иначе файл ложился в полосу ответа, а следующий
---ответ открывал под ней ещё одну — окно уже не помечено как окно ответа.
function M.leave_answer()
  local w = vim.b.sqlwin
  if w and w.from and vim.api.nvim_win_is_valid(w.from) then
    vim.api.nvim_set_current_win(w.from)
  end
end

---Закрыть текущее окно и вернуться в from, если оно ещё живо, — q и в окне ответа, и в
---черновике запроса.
function M.close_to(from)
  vim.cmd("close")
  if from and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
end

---@param o table
---  kind     — что показано: object / message / query / deploy (на выбор окна не
---             влияет, окно выбирает bottom)
---  title    — имя буфера после sql://
---  text     — содержимое одной строкой (или lines — уже готовыми строками)
---  ctx      — где смотрели: file, conn, db
---  filetype — "sql" для кода объекта (по умолчанию), "" для табличного вывода
---  bottom   — нижний сплит вместо вертикального: так показывают то, что читают как
---             вывод, а не как файл (текст сообщения, результат запроса, деплой)
---  focus    — оставлять ли курсор в окне ответа (по умолчанию да)
function M.show(o)
  local lines = o.lines or vim.split(o.text or "", "\n")
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end

  local from = vim.api.nvim_get_current_win()
  local slot = slot_of(o)
  local win = window_of(slot)
  -- Куда вернуть курсор по q. Само окно ответа origin'ом быть не может: K внутри него
  -- переиспользует это же окно, и тогда q возвращал бы в него же — наследуем прошлый.
  if win == from then
    from = (vim.b[vim.api.nvim_win_get_buf(win)].sqlwin or {}).from or from
  end
  -- справка — рядом с нижним, а не ещё одной полосой под ним: две полосы по 20 строк
  -- съедают почти весь экран; и наоборот — результат встаёт слева от уже открытой справки
  local paired = slot == "aside" and "bottom" or slot == "bottom" and "aside"
  local beside = not win and paired and window_of(paired)
  if win then
    vim.api.nvim_set_current_win(win)
  elseif beside then
    vim.api.nvim_set_current_win(beside)
    vim.cmd(slot == "aside" and "rightbelow vsplit" or "leftabove vsplit")
  elseif o.bottom then
    -- split, а не new: :new заводит пустой буфер, который мы тут же подменяем своим,
    -- и он остаётся в списке как [No Name] — по одному на каждый показ
    vim.cmd("botright split")
  else
    vim.cmd("vsplit")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  -- nvim_win_set_buf сам ставит метку в списке переходов окна: <C-o> вернёт прошлый ответ
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].sqlwin = { kind = o.kind, slot = slot, from = from }
  vim.b[buf].sqlctx = o.ctx
  vim.bo[buf].filetype = o.filetype or "sql"
  keys(buf)
  set_name(buf, "sql://" .. o.title)
  remember(buf)
  -- рядом с результатом высоту не трогаем: она у них общая, и короткий список
  -- сплющил бы результат
  if o.bottom and not (paired and window_of(paired)) then
    vim.api.nvim_win_set_height(0, math.min(20, math.max(5, #lines + 1)))
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  if o.focus == false and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  else
    -- <F5> жмут и из режима вставки, а окно ответа нередактируемое: в insert тут
    -- можно только упереться в «modifiable is off», так что ответ читаем из normal
    vim.cmd("stopinsert")
  end
end

return M
