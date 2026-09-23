-- Окна с ответом sqlcmd: код объекта, строки таблицы, текст сообщения, вывод деплоя.
-- Раньше то же самое было написано дважды — в sqldeploy и в sqlobject.
--
-- Окон на всё про всё два, и следующий ответ ложится в готовое, а не добавляет сплит:
-- код объекта — в вертикальном справа, всё, что читают как вывод (текст сообщения,
-- строки таблицы, результат запроса, деплой), — в нижнем. То есть <leader>dx после
-- <leader>dd покажет результат там же, где лежал вывод деплоя.
--
-- В буфере остаются две переменные:
--   b:sqlwin — вид окна, его место и куда вернуть курсор по q (кухня этого модуля);
--   b:sqlctx — где смотрели (file/conn/db). Из неё K, :SqlRows и :SqlRun внутри окна
--              берут подключение и базу, то есть ходят туда же, откуда ответ.

local M = {}

---Место окна: нижний сплит один на все виды вывода, вертикальный — на код объекта.
---Виды (kind) при этом остаются разными: по ним видно, что в окне показано.
local function slot_of(o)
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

---Клавиши окна ответа: q — закрыть и вернуться туда, откуда пришли; K — посмотреть
---объект под курсором, уже в подключении и базе этого окна (b:sqlctx), gf — его файл в
---том же репозитории, откуда пришёл ответ, gK — объект на другом сервере.
local function keys(buf)
  require("config.sqlobject").map_def_keys(buf)
  vim.keymap.set("n", "q", function()
    local from = (vim.b[buf].sqlwin or {}).from
    vim.cmd("close")
    if from and vim.api.nvim_win_is_valid(from) then
      vim.api.nvim_set_current_win(from)
    end
  end, { buffer = buf, desc = "Закрыть окно" })
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
  if win then
    vim.api.nvim_set_current_win(win)
  elseif o.bottom then
    -- split, а не new: :new заводит пустой буфер, который мы тут же подменяем своим,
    -- и он остаётся в списке как [No Name] — по одному на каждый показ
    vim.cmd("botright split")
  else
    vim.cmd("vsplit")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf) -- прошлый буфер с bufhidden=wipe тут же удаляется
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].sqlwin = { kind = o.kind, slot = slot, from = from }
  vim.b[buf].sqlctx = o.ctx
  vim.bo[buf].filetype = o.filetype or "sql"
  keys(buf)
  pcall(vim.api.nvim_buf_set_name, buf, "sql://" .. o.title)
  if o.bottom then
    vim.api.nvim_win_set_height(0, math.min(20, math.max(5, #lines + 1)))
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  if o.focus == false and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
end

return M
