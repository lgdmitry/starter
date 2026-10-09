-- :SqlQuery / :SqlQueryFile / :SqlRun — черновик запроса рядом с процедурой и его выполнение.
--
-- Дырка, которую они закрывают: :SqlDeploy выкладывает файл целиком, :SqlDef/:SqlRows
-- показывают объект — а разового «а что вернёт вот этот select» не было, и приходилось
-- идти в :DBUI и там выбирать подключение руками.
--
-- Зачем не dadbod (:DB, <leader>S из vim-dadbod-ui): он зовёт sqlcmd вообще без -f
-- (autoload/db/adapter/sqlserver.vim), а без флага sqlcmd отдаёт вывод в ANSI-кодировке
-- консоли — то есть кириллица приезжает битой не в запросе, а в самом результате, и
-- поправить это в dadbod негде: он пишет байты вывода в файл и открывает его как буфер.
-- Здесь и вход (-f i:65001), и выход (mssql.conn.output_to_utf8) под нашим контролем,
-- а подключение с базой берутся те же, что у :SqlDeploy для этого файла.
--
-- Буферы запроса двух видов (b:sqlquery):
--   "scratch" — временный, живёт до выхода из nvim, один на пару подключение/база;
--   "file"    — постоянный: файл в M.dir, переживает перезапуск и сессии. Подключение
--               записано в нём первой строкой (`-- sqlquery: conn/db`) — b:sqlctx
--               в файле не сохранишь, а строку видно, её можно поправить руками (после
--               :w она перечитывается), и файл при копировании уносит её с собой.
--               Имя файла — `conn@db.sql` (`~N` при совпадении), :SqlConn
--               переименовывает файл вслед за подключением, q добавляет метку из
--               запроса (`conn@db~orders.sql`), а пустой — стирает.
-- Оба привязаны к подключению через b:sqlctx, как и окна ответа, поэтому новый буфер
-- запроса, открытый из буфера запроса, берёт подключение текущего, а не правила.
--
-- Клавиши глобальные (группа <leader>d, см. plugins/which-key.lua):
--   <leader>dq   — открыть временный буфер запроса для подключения/базы текущего файла
--   <leader>dQ   — то же, но подключение и база спрашиваются
--   <leader>dt   — завести новый постоянный запрос для подключения/базы текущего файла
--                  (в самом постоянном запросе — к его паре); занятое имя — ~2, ~3…
--   <leader>dT   — то же, но подключение и база спрашиваются
--   (не <leader>dp: у LazyVim это группа profiler — <leader>dpp, <leader>dph, <leader>dps)
--   <leader>dx   — выполнить выделенное (в визуальном режиме)
--   <leader>do   — выполнить файл (в визуальном — выделенное) и записать ответ в файл
--                  (:SqlExport [путь], по умолчанию рядом <имя>.txt)
--   <leader>dc   — прервать выполняющийся sqlcmd (:SqlCancel, см. mssql.conn)
--   <F5>         — то же, что <leader>dx, но и в режиме вставки (в буфере запроса;
--                  в остальных <F5> выкладывает файл, см. mssql.deploy)
-- В самом буфере запроса <leader>dx работает и в обычном режиме — на весь буфер,
-- <leader>ds (:SqlConn) меняет его подключение и базу, а q закрывает окно, как и в окне
-- с ответом (ценой записи макросов: в черновике запроса она нужна реже, чем закрыть его
-- тем же движением, что и ответ); постоянный запрос q сохраняет и закрывает совсем. С ! (:SqlQuery!, :SqlRun!) спрашиваются подключение и база.

local sql = require("mssql.conn")
local target = require("mssql.target")
local sqlwin = require("mssql.win")

local M = {}

---До скольких символов sqlcmd режет колонки в выводе (-y/-Y).
M.column_width = 255

---Где лежат постоянные запросы. Не в репозитории: там им пришлось бы жить в .gitignore
---каждого проекта, а запрос к dev-базе к коду проекта не относится.
M.dir = vim.fs.normalize(vim.fn.stdpath("data")) .. "/sqlquery"

local notify = sql.notifier("SqlQuery")

---Первая строка постоянного запроса: подключение и база. Файла, откуда запрос завели,
---в ней больше нет: подключения теперь общие (config.sqldbs), .env проекта искать не
---нужно. Хвост после базы у старых файлов (там был путь) просто пропускается.
local HEADER = "^%-%-%s*sqlquery:%s*([^/%s]+)/(%S+)"

function M.header(ctx)
  return ("-- sqlquery: %s/%s"):format(ctx.conn, ctx.db)
end

function M.parse_header(line)
  local conn, db = (line or ""):match(HEADER)
  if conn then
    -- file = "", а не nil: pick берёт ctx.file or имя буфера, а имя постоянного
    -- запроса — не файл проекта
    return { conn = conn, db = db, file = "" }
  end
end

---Постоянный ли это запрос — по пути, а не по b:sqlquery: вызывается из BufReadPost,
---когда переменных у буфера ещё нет.
function M.is_query_file(path)
  path = vim.fs.normalize(path):lower()
  local dir = M.dir:lower() .. "/"
  return path:sub(1, #dir) == dir and path:match("%.sql$") ~= nil
end

---Имя файла, заведённого самим <leader>dt: `conn@db`, с `~N` при совпадении, а после q —
---`conn@db~метка` (см. M.slug). Только такие :SqlConn и q переименовывают, а prune
---стирает — названные руками (:SqlQueryFile имя) остаются как есть.
local function is_auto(name)
  return name:match("^[^@]+@[^@~]+$") ~= nil or name:match("^[^@]+@[^@~]+~[^@]+$") ~= nil
end

---Метка из имени автоматического файла: `conn@db~orders~2` → orders, у `conn@db~2` — нет.
local function slug_of(name)
  local tail = name:match("^[^@]+@[^@~]+~(.+)$")
  tail = tail and tail:gsub("~%d+$", "")
  if tail and not tail:match("^%d+$") then
    return tail
  end
end

---Строка, пригодная в имя файла: без запрещённых в Windows знаков и без ~/@ (ими
---размечено само имя), не длиннее 40 символов.
local function clean(s)
  s = vim.fn.strcharpart(vim.trim((s:gsub('[/\\:*?"<>|~@%s]+', "_"))), 0, 40)
  s = s:gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or nil
end

---Метка запроса для имени файла: по ней запрос узнают в :SqlQueryFile <Tab> среди
---десятка `conn@db~N`. Первая строка после заголовка, если это комментарий, — его
---писали как раз как подпись; иначе первый объект после from/join/exec/update/into
---(без схемы, скобок, табличных переменных и #временных таблиц).
---@return string?
function M.slug(lines)
  local body = {}
  for i, line in ipairs(lines) do
    if not (i == 1 and M.parse_header(line)) then
      body[#body + 1] = line
    end
  end
  for _, line in ipairs(body) do
    if vim.trim(line) ~= "" then
      local comment = line:match("^%s*%-%-+%s*(.-)%s*$")
      if comment and comment ~= "" then
        return clean(comment)
      end
      break
    end
  end
  local text = table.concat(body, "\n"):gsub("/%*.-%*/", " "):gsub("%-%-[^\n]*", " "):gsub("'[^']*'", " ")
  local keywords = { from = true, join = true, exec = true, execute = true, update = true, into = true }
  for pos, word in text:gmatch("()([%a_]+)") do
    if keywords[word:lower()] then
      local ident = text:match('^%s+([%w_%.%[%]"#@]+)', pos + #word)
      local name = ident and ident:gsub('[%[%]"]', ""):match("([^%.]+)$")
      if name and not name:match("^[#@]") then
        return clean(name)
      end
    end
  end
end

---Пустой ли постоянный запрос: кроме строки подключения — ничего.
function M.is_empty(lines)
  for i, line in ipairs(lines) do
    if vim.trim(line) ~= "" and not (i == 1 and M.parse_header(line)) then
      return false
    end
  end
  return true
end

---Путь постоянного запроса к паре. self — сам переименовываемый файл: его имя не занято.
---slug — метка после `~`.
local function auto_path(conn, database, self, slug)
  local base = ("%s/%s@%s"):format(M.dir, conn, database) .. (slug and "~" .. slug or "")
  local path, n = base .. ".sql", 1
  -- диск регистронезависимый: dgsql_dev@Crocus и dgsql_dev@crocus — один файл
  while vim.uv.fs_stat(path) and path:lower() ~= (self or ""):lower() do
    n = n + 1
    path = ("%s~%d.sql"):format(base, n)
  end
  return path
end

---Имена постоянных запросов (без .sql) — для дополнения и списка.
function M.names(arglead)
  local out = {}
  for _, path in ipairs(vim.fn.glob(M.dir .. "/*.sql", false, true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    if name:lower():find((arglead or ""):lower(), 1, true) == 1 then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Стереть автоматические запросы (`conn@db`, `conn@db~N`), не менявшиеся с прошлых
---суток. <leader>dt заводит новый файл на каждый запрос, и они копились сотнями, хотя
---нужны только сегодня. Файлом, а не временным буфером, они остаются ради того, чтобы
---случайно закрытый запрос можно было открыть снова (:SqlQueryFile <Tab>), — на
---следующий день это уже не нужно. Названные руками (:SqlQueryFile имя) живут, пока
---их не удалят: имя им давали, чтобы сохранить. Граница — начало сегодняшнего дня, а не
---24 часа: вчерашний вечерний запрос утром так же не нужен.
---@param now? integer для тестов
function M.prune(now)
  local today = os.date("*t", now)
  local since = os.time({ year = today.year, month = today.month, day = today.day, hour = 0 })
  for _, path in ipairs(vim.fn.glob(M.dir .. "/*.sql", false, true)) do
    local stat = vim.uv.fs_stat(path)
    if
      is_auto(vim.fn.fnamemodify(path, ":t:r"))
      and stat
      and stat.mtime.sec < since
      and vim.fn.bufloaded(path) == 0
    then
      os.remove(path)
    end
  end
end

---Есть ли ради чего делить окно: хоть один залистованный буфер с файлом. На пустом
---старте (дашборд, [No Name]) вертикальный сплит только режет экран пополам ради
---пустоты — там черновик занимает текущее окно.
local function has_open_files()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) ~= "" then
      return true
    end
  end
  return false
end

---Буфер с таким именем. Не bufnr(): тот понимает имя как шаблон, а в путях и именах
---подключений бывают его спецсимволы.
local function buf_by_name(name)
  name = vim.fs.normalize(name):lower()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)):lower() == name then
      return buf
    end
  end
end

---Имя временного буфера. Два временных на одну пару бывают (второй переключили
---:SqlConn туда, где уже был первый), а имя буфера обязано быть уникальным — E95.
local function scratch_name(buf, conn, database)
  local base = ("sqlquery://%s/%s"):format(conn, database)
  local name, n = base, 1
  while true do
    local other = buf_by_name(name)
    if not other or other == buf then
      return name
    end
    n = n + 1
    name = ("%s#%d"):format(base, n)
  end
end

---Записать постоянный запрос под путём new (тот же — просто сохранить), старый файл стереть.
local function move(buf, new)
  local old = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  vim.api.nvim_buf_call(buf, function()
    if new == old then
      return vim.cmd("silent update")
    end
    vim.cmd("silent keepalt file " .. vim.fn.fnameescape(new))
    vim.cmd("silent write")
  end)
  if new:lower() ~= old:lower() then
    os.remove(old)
    -- :file оставляет незалистованный буфер со старым именем (keepalt не помогает),
    -- и в него вёл бы # — в файл, которого уже нет
    local stale = buf_by_name(old)
    if stale and stale ~= buf then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
    end
  end
end

---Привязать буфер запроса к подключению и базе. b:sqlctx — та же переменная, что у окон
---с ответом (mssql.win): благодаря ей K, <leader>dr и новый <leader>dq отсюда
---идут в эту же базу, а не в ту, которую вычислили бы по имени буфера; b:db — для
---дополнения таблиц и колонок (vim-dadbod-completion).
local function bind(buf, conn, database, file)
  local ctx = { file = file or "", conn = conn.name, db = database }
  vim.b[buf].sqlctx = ctx
  vim.b[buf].db = sql.with_database(conn.url, database)
  if vim.b[buf].sqlquery == "scratch" then
    pcall(vim.api.nvim_buf_set_name, buf, scratch_name(buf, conn.name, database))
  elseif vim.b[buf].sqlquery == "file" then
    local header = M.header(ctx)
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    if M.parse_header(first) then
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { header })
    else
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { header })
    end
    -- сразу на диск: иначе смена подключения потерялась бы вместе с несохранённым
    -- буфером, а следующий запуск пошёл бы по старой строке
    local old = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    local name = vim.fn.fnamemodify(old, ":t:r")
    move(buf, is_auto(name) and auto_path(conn.name, database, old, slug_of(name)) or old)
  end
  -- дополнение запомнило таблицы прошлой базы
  if vim.fn.exists("*vim_dadbod_completion#fetch") == 1 then
    pcall(vim.fn["vim_dadbod_completion#fetch"], buf)
  end
end

---Клавиши обоих видов буфера запроса. Только здесь, а не в любом sql-буфере:
---«выполнить весь буфер» в файле процедуры означало бы :SqlDeploy, q в обычном файле
---занят под что угодно другое, а сменить подключение обычному файлу — значит
---перебить правила, по которым его выкладывают.
local function map_keys(buf)
  vim.keymap.set("n", "<leader>dx", "<cmd>SqlRun<cr>", { buffer = buf, desc = "Выполнить запрос" })
  -- <F5> — одна клавиша на все режимы, чтобы не помнить, где какая; перекрывает
  -- глобальный <F5> из mssql.deploy, который в файле выкладывает. В insert через
  -- <leader> не дотянуться: <C-o><leader>dx не работает — триггер which-key съедает
  -- одноразовый normal-режим, и собранные клавиши допечатываются в буфер текстом.
  -- <cmd> выполняет запрос, не выходя из вставки и не сдвигая курсор.
  vim.keymap.set({ "n", "i" }, "<F5>", "<cmd>SqlRun<cr>", { buffer = buf, desc = "Выполнить запрос" })
  vim.keymap.set(
    "n",
    "<leader>ds",
    "<cmd>SqlConn<cr>",
    { buffer = buf, desc = "Сменить подключение запроса" }
  )
  -- временный буфер остаётся жить (bufhidden=hide) и вернётся тем же <leader>dq;
  -- постоянный сохраняется и закрывается совсем — он уже на диске, а висеть в
  -- bufferline после q ему незачем: вернуть можно через :SqlQueryFile <имя>
  -- Пустой постоянный запрос (одна строка подключения) по q стирается с диска: его
  -- заводили и передумали, а в :SqlQueryFile <Tab> он только мешал бы. Непустой с
  -- автоматическим именем получает метку из запроса (M.slug) — conn@db~N потом не
  -- отличить друг от друга.
  vim.keymap.set("n", "q", function()
    local file = vim.b[buf].sqlquery == "file"
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local empty = file and M.is_empty(lines)
    local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if file and not empty then
      local ctx = vim.b[buf].sqlctx or {}
      local name = vim.fn.fnamemodify(path, ":t:r")
      local slug = is_auto(name) and ctx.conn and ctx.db and M.slug(lines)
      move(buf, slug and auto_path(ctx.conn, ctx.db, path, slug) or path)
    end
    -- постоянный открыт в текущем окне, а не в своём сплите — окно чужое, его не
    -- закрываем; единственное окно :close не закроет (E444) — в обоих случаях просто
    -- уходим на предыдущий буфер, а если его нет — в пустой
    if file or #vim.api.nvim_tabpage_list_wins(0) == 1 then
      if not pcall(vim.cmd, "buffer #") then
        vim.cmd("enew")
      end
      if file and vim.api.nvim_get_current_buf() ~= buf then
        if empty then
          os.remove(path)
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        else
          -- :bdelete, а не wipe: так # из этого окна по-прежнему ведёт в запрос
          pcall(vim.cmd, "bdelete " .. buf)
        end
      end
      return
    end
    sqlwin.close_to(vim.b[buf].sqlquery_from)
  end, { buffer = buf, desc = "Закрыть буфер запроса" })
end

---Временный буфер запроса для этой пары подключение/база: один на пару, а не по новому
---на каждый вызов — иначе за день их набирается десяток. Ищем по b:sqlctx, а не по
---имени: после :SqlConn имя может оказаться с суффиксом.
local function query_buffer(conn, database, file)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ctx = vim.b[buf].sqlctx
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.b[buf].sqlquery == "scratch"
      and ctx
      and ctx.conn == conn.name
      and ctx.db == database
    then
      return buf
    end
  end
  -- Незалистованный: в bufferline черновику делать нечего, а закрыв окно, его и не
  -- ищут в списке буферов — возвращаются тем же <leader>dq, содержимое переживает.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile" -- запрос никуда не сохраняется, sqlcmd получает его через временный файл
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].sqlquery = "scratch"
  bind(buf, conn, database, file)
  vim.bo[buf].filetype = "sql"
  map_keys(buf)
  return buf
end

---Постоянный запрос открыт (BufReadPost) или сохранён (BufWritePost — строку
---подключения могли поправить руками): привязать по первой строке.
---
---b:db здесь не ставим, его ставит mssql.complete на первой правке в insert: с b:db
---vim-dadbod-completion на FileType сразу идёт в базу за таблицами, а запросы из
---восстановленной сессии открываются на старте — когда нужен ли вообще этот запрос
---ещё неизвестно, а пароли из Credential Manager (config.sqldbs) ещё не дочитаны и
---sqlcmd спрашивает пароль.
function M.attach_file(buf)
  vim.b[buf].sqlquery = "file"
  map_keys(buf)
  -- строку могли сменить — пусть дополнение привяжется заново, уже к новой
  vim.b[buf].db = nil
  vim.b[buf].sqlcomplete_tried = nil
  -- без строки подключения — как черновик без привязки: :SqlRun спросит подключение
  vim.b[buf].sqlctx = M.parse_header(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]) or { file = "" }
end

---Спросить базу на сервере подключения. Первыми — preferred (если они есть на этом
---сервере), за ними база из URL, дальше все остальные базы сервера.
local function choose_db(conn, preferred, cb)
  local ok, names = pcall(target.databases, conn)
  names = ok and names or {}
  local known = {}
  for _, db in ipairs(names) do
    known[db:lower()] = db
  end
  local order, seen = {}, {}
  local function add(db)
    if db and db ~= "" and not seen[db:lower()] then
      seen[db:lower()] = true
      order[#order + 1] = db
    end
  end
  -- база из URL — не выбор, а то, что записали в config.sqldbs; правила файла и
  -- прежняя база буфера говорят о намерении больше, поэтому она после них
  local url_db = sql.url_db(conn)
  for _, db in ipairs(preferred) do
    if db:lower() ~= url_db:lower() then
      -- список баз не получили (сервер недоступен) — предложенные всё равно покажем
      add(#names == 0 and db or known[db:lower()])
    end
  end
  add(url_db)
  for _, db in ipairs(names) do
    add(db)
  end
  if #order == 0 then
    return notify("на " .. conn.name .. " не нашлось баз", vim.log.levels.ERROR)
  end
  vim.ui.select(order, { prompt = ("База на %s:"):format(conn.name) }, function(db)
    if db then
      cb(db)
    end
  end)
end

---Куда идти: в черновике и в окне ответа — ровно то, к чему они привязаны, иначе как
---у :SqlDeploy. С ! после подключения спрашивается и база: подключение в
---config.sqldbs одно на сервер, и выбрать его — ещё не значит выбрать базу (раньше
---в .env на каждую базу было своё подключение, и выбор подключения её и задавал).
local function pick(bang, cb)
  target.pick({
    ctx = vim.b.sqlctx,
    file = vim.api.nvim_buf_get_name(0),
    bang = bang,
    prompt = "Запрос к:",
    title = "SqlQuery",
    url_fallback = true,
  }, function(conn, dbs, file)
    if not bang then
      return cb(conn, dbs[1], file)
    end
    choose_db(conn, dbs, function(db)
      cb(conn, db, file)
    end)
  end)
end

---Показать буфер запроса: в его окне, если он уже виден, иначе в вертикальном сплите
---(или в текущем окне, если делить нечего). show — как положить буфер в окно.
local function present(buf, show)
  local from = vim.api.nvim_get_current_win()
  local shown = buf and vim.fn.bufwinid(buf) or -1
  if shown ~= -1 then
    vim.api.nvim_set_current_win(shown) -- уже открыт: второе окно на тот же буфер не нужно
    return
  end
  local split = has_open_files()
  if split then
    vim.cmd("vsplit")
  end
  show()
  -- куда вернуть курсор по q; без сплита возвращаться некуда, окно то же самое
  vim.b.sqlquery_from = split and from or nil
end

---Курсор — туда, где писать: в пустом черновике на первую строку после заголовка.
---Без startinsert: в новый буфер часто приходят вставить запрос (p) или сразу уйти
---дальше, и insert тогда приходилось каждый раз гасить <Esc>.
local function start_editing(buf, first_line)
  local lines = vim.api.nvim_buf_get_lines(buf, first_line - 1, -1, false)
  if #lines <= 1 and (lines[1] or "") == "" then
    vim.api.nvim_win_set_cursor(0, { first_line, 0 })
  end
end

---:SqlQuery — открыть временный буфер запроса.
function M.open(opts)
  pick(opts.bang, function(conn, database, file)
    local buf = query_buffer(conn, database, file)
    present(buf, function()
      vim.api.nvim_win_set_buf(0, buf)
    end)
    start_editing(buf, 1)
    notify(("запрос к %s/%s"):format(conn.name, database))
  end)
end

---Открыть файл постоянного запроса — в текущем окне: это рабочий файл, как любой
---другой, а не справка рядом с процедурой, как временный черновик.
local function open_path(path)
  -- закрытый (bdelete) запрос живёт дальше незалистованным со старым номером, и :edit
  -- вернул бы его — а bufferline сортирует по номеру, и вкладка встала бы левее
  -- текущего файла, хотя каждый новый встаёт справа. Стираем, чтобы номер был новый.
  local old = buf_by_name(path)
  if old and not vim.bo[old].buflisted and not vim.bo[old].modified and vim.fn.bufwinid(old) == -1 then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local ctx = vim.b[buf].sqlctx or {}
  start_editing(buf, M.parse_header(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]) and 2 or 1)
  notify(("%s → %s/%s"):format(vim.fn.fnamemodify(path, ":t:r"), ctx.conn or "?", ctx.db or "?"))
end

---:SqlQueryFile [имя] — завести новый постоянный запрос к подключению текущего буфера
---(с ! — выбранному руками): `conn@db.sql`, а занято — `conn@db~N.sql`. С именем —
---файл с этим именем, у существующего подключение своё, из его первой строки.
function M.open_file(opts)
  local name = vim.trim(opts.args or ""):gsub("%.sql$", "")
  if name:find('[/:*?"<>|]') then
    return notify("недопустимое имя: " .. name, vim.log.levels.ERROR)
  end
  if name ~= "" and vim.uv.fs_stat(M.dir .. "/" .. name .. ".sql") then
    return open_path(M.dir .. "/" .. name .. ".sql")
  end
  -- без имени — всегда новый файл, а не прежний запрос к паре: <leader>dt жмут, чтобы
  -- начать запрос с чистого листа, а старые открываются по имени (:SqlQueryFile <Tab>)
  pick(opts.bang, function(conn, database, file)
    local path = name ~= "" and (M.dir .. "/" .. name .. ".sql") or auto_path(conn.name, database)
    if not vim.uv.fs_stat(path) then
      vim.fn.mkdir(M.dir, "p")
      vim.fn.writefile({ M.header({ conn = conn.name, db = database }), "" }, path)
    end
    open_path(path)
  end)
end

---:SqlConn — сменить подключение и базу буфера запроса. База спрашивается следом:
---на другом сервере нужная база редко совпадает с прежней, а подставить её молча —
---значит выполнить запрос не там.
function M.switch()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].sqlquery then
    return notify(
      "подключение меняется только в буфере запроса (<leader>dq / <leader>dt)",
      vim.log.levels.WARN
    )
  end
  local ctx = vim.b[buf].sqlctx or {}
  local file = ctx.file or ""
  local list = sql.connections(file)
  if #list == 0 then
    return notify("не найдено подключений DB_UI_* в .env проекта", vim.log.levels.ERROR)
  end
  sql.select(list, "Подключение:", function(conn)
    if not conn then
      return
    end
    -- первой — прежняя база, если она есть на этом сервере
    choose_db(conn, { ctx.db }, function(db)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      bind(buf, conn, db, file)
      notify(("запрос теперь к %s/%s"):format(conn.name, db))
    end)
  end)
end

---:SqlRun — выполнить буфер целиком или строки диапазона (в визуальном режиме — выделение).
function M.run(opts)
  if not sql.ensure("SqlQuery") then
    return
  end
  local lines = opts.range > 0 and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    or vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    return notify("нечего выполнять", vim.log.levels.WARN)
  end

  pick(opts.bang, function(conn, database, file)
    sql.run({
      conn = conn,
      db = database,
      lines = lines,
      opts = { width = 8000, trunc = M.column_width },
      -- не разовое уведомление, а живущее до ответа: запрос может думать десятки
      -- секунд, и всё это время единственный признак работы — эта крутилка
      progress = ("выполняется на %s/%s… (<leader>dc — отменить)"):format(conn.name, database),
      title = "SqlQuery",
    }, function(code, text)
      if code ~= 0 then
        notify(("sqlcmd вернул %d (%s/%s)"):format(code, conn.name, database), vim.log.levels.ERROR)
      end
      sqlwin.show({
        kind = "query",
        title = ("запрос @ %s/%s"):format(conn.name, database),
        text = text,
        ctx = { file = file, conn = conn.name, db = database },
        filetype = "",
        bottom = true,
      })
    end)
  end)
end

---Куда выгружать по умолчанию: рядом с файлом, то же имя с .txt; у буфера без файла —
---в текущий каталог.
function M.export_path(bufname)
  if bufname ~= "" and not bufname:match("^%a[%w+.-]+://") then
    return vim.fn.fnamemodify(bufname, ":r") .. ".txt"
  end
  return vim.fs.normalize(vim.uv.cwd()) .. "/export.txt"
end

---Флаги sqlcmd для выгрузки: таблица, как в окне ответа, но колонки режутся на 8000, а
---не на M.column_width. CSV нет сознательно: sqlcmd не берёт значения в кавычки, а NULL
---в узкой колонке обрезает (NUL).
M.export_opts = { width = 65535, trunc = 8000 }

---Вывод sqlcmd для файла: без хвостовых пустых строк.
---@return string[]
function M.export_text(text)
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end
  return lines
end

---Текст скрипта к выгрузке: BOM файла остаётся в первой строке текстом (в
---fileencodings нет ucs-bom). В начале входа sqlcmd его съедает, а после вставленной
---строки он — «Incorrect syntax near '?'». Снимаем все: бывают файлы и с двумя BOM
---подряд. SET NOCOUNT — без «(N rows affected)»: в таблице они только мешают.
local function export_lines(lines)
  lines = vim.list_extend({}, lines)
  while (lines[1] or ""):sub(1, 3) == "\239\187\191" do
    lines[1] = lines[1]:sub(4)
  end
  return vim.list_extend({ "SET NOCOUNT ON;" }, lines)
end

---Выполнить и записать ответ в path. Ошибка sqlcmd — файл не трогаем, ответ в окне.
---done(true) — файл записан.
local function export_to(lines, path, conn, database, file, done)
  sql.run({
    conn = conn,
    db = database,
    lines = lines,
    opts = M.export_opts,
    progress = ("выгрузка с %s/%s… (<leader>dc — отменить)"):format(conn.name, database),
    title = "SqlExport",
  }, function(code, text)
    if code ~= 0 then
      notify(
        ("sqlcmd вернул %d (%s/%s), %s не записан"):format(
          code,
          conn.name,
          database,
          vim.fn.fnamemodify(path, ":t")
        ),
        vim.log.levels.ERROR
      )
      sqlwin.show({
        kind = "query",
        title = ("выгрузка @ %s/%s"):format(conn.name, database),
        text = text,
        ctx = { file = file, conn = conn.name, db = database },
        filetype = "",
        bottom = true,
      })
      return done(false)
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(M.export_text(text), path)
    notify(("%s/%s → %s"):format(conn.name, database, path))
    done(true)
  end)
end

---Показать файл выгрузки рядом с исходником: уже открытый — перечитать (иначе в
---буфере остаётся прошлый ответ), видимый — просто перейти в его окно.
local function show_export(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    vim.cmd("checktime " .. buf)
  end
  local win = buf ~= -1 and vim.fn.bufwinid(buf) or -1
  if win ~= -1 then
    return vim.api.nvim_set_current_win(win)
  end
  vim.cmd("vsplit " .. vim.fn.fnameescape(path))
end

---:SqlExport [путь] — выполнить буфер (или диапазон) и записать ответ в файл, а не в
---окно, и открыть его рядом. Подключение — как у :SqlRun.
function M.export(opts)
  if not sql.ensure("SqlExport") then
    return
  end
  local lines = opts.range > 0 and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    or vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    return notify("нечего выполнять", vim.log.levels.WARN)
  end
  lines = export_lines(lines)
  local arg = vim.trim(opts.args or "")
  local path =
    vim.fs.normalize(arg ~= "" and vim.fn.fnamemodify(arg, ":p") or M.export_path(vim.api.nvim_buf_get_name(0)))
  pick(opts.bang, function(conn, database, file)
    export_to(lines, path, conn, database, file, function(ok)
      if ok then
        show_export(path)
      end
    end)
  end)
end

---Строки файла как их видит nvim: открытый — из буфера (с несохранёнными правками),
---иначе загружаем буфером, а не readfile — так текст приходит уже перекодированным
---по fileencodings, а не сырыми байтами cp1251.
local function file_lines(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Выгрузить пачку файлов из пикера (<leader>do): каждый — в свой .txt рядом, как
---:SqlExport в самом файле, но без открытия ответов: из пикера выгружают пачкой, и
---десяток сплитов только мешал бы. Подключение — по правилам каждого файла, а с
---pick — одно, спрошенное раз на всю пачку. По очереди, а не разом: прогресс и
---<leader>dc рассчитаны на один sqlcmd.
---@param files string[]
---@param opts? { pick: boolean? }
function M.export_files(files, opts)
  opts = opts or {}
  if not sql.ensure("SqlExport") then
    return
  end
  local sqls, skipped = {}, {}
  for _, path in ipairs(files) do
    path = vim.fs.normalize(path)
    if vim.fn.isdirectory(path) == 0 and path:lower():match("%.sql$") then
      sqls[#sqls + 1] = path
    else
      skipped[#skipped + 1] = vim.fn.fnamemodify(path, ":t")
    end
  end
  if #skipped > 0 then
    notify("не .sql, пропущено: " .. table.concat(skipped, ", "), vim.log.levels.WARN)
  end
  if #sqls == 0 then
    return
  end

  local failed = {}
  local function step(i, chosen)
    if i > #sqls then
      if #sqls > 1 then
        notify(
          #failed == 0 and ("выгружено файлов: %d"):format(#sqls)
            or ("не выгрузилось %d из %d: %s"):format(#failed, #sqls, table.concat(failed, ", ")),
          #failed == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        )
      end
      return
    end
    local src = sqls[i]
    local lines = file_lines(src)
    if vim.trim(table.concat(lines, "\n")) == "" then
      failed[#failed + 1] = vim.fn.fnamemodify(src, ":t")
      return step(i + 1, chosen)
    end
    lines = export_lines(lines)
    local function run(conn, database)
      local path = M.export_path(src)
      export_to(lines, path, conn, database, src, function(ok)
        if not ok then
          failed[#failed + 1] = vim.fn.fnamemodify(src, ":t")
        end
        step(i + 1, chosen)
      end)
    end
    if chosen then
      return run(chosen.conn, chosen.db)
    end
    target.pick({
      file = src,
      bang = opts.pick,
      prompt = "Выгрузка с:",
      title = "SqlExport",
      url_fallback = true,
    }, function(conn, dbs)
      if not opts.pick then
        return run(conn, dbs[1])
      end
      choose_db(conn, dbs, function(db)
        chosen = { conn = conn, db = db }
        run(conn, db)
      end)
    end)
  end
  step(1)
end

function M.setup()
  M.prune()
  -- Глобально: <leader>dq должен открывать черновик запроса откуда угодно, а не
  -- только из уже открытого .sql — иначе до базы приходится идти через :DBUI.
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end
  map("n", "<leader>dq", "<cmd>SqlQuery<cr>", "Буфер запроса к базе файла")
  map(
    "n",
    "<leader>dQ",
    "<cmd>SqlQuery!<cr>",
    "Буфер запроса, выбрав подключение и базу"
  )
  map("n", "<leader>dt", "<cmd>SqlQueryFile<cr>", "Новый постоянный запрос к базе файла")
  map(
    "n",
    "<leader>dT",
    "<cmd>SqlQueryFile!<cr>",
    "Новый постоянный запрос, выбрав подключение и базу"
  )
  map("x", "<leader>dx", ":<C-u>'<,'>SqlRun<cr>", "Выполнить выделенный запрос")
  map("x", "<F5>", ":<C-u>'<,'>SqlRun<cr>", "Выполнить выделенный запрос")
  map("n", "<leader>do", "<cmd>SqlExport<cr>", "Выполнить файл, ответ — в .txt рядом")
  map(
    "x",
    "<leader>do",
    ":<C-u>'<,'>SqlExport<cr>",
    "Выполнить выделенное, ответ — в .txt рядом"
  )

  vim.api.nvim_create_user_command("SqlQuery", M.open, {
    bang = true,
    desc = "Открыть временный буфер запроса к базе текущего файла (! — выбрать подключение и базу)",
  })
  vim.api.nvim_create_user_command("SqlQueryFile", M.open_file, {
    bang = true,
    nargs = "?",
    complete = function(arglead)
      return M.names(arglead)
    end,
    desc = "Открыть постоянный запрос к базе текущего файла или по имени (! — выбрать подключение и базу)",
  })
  vim.api.nvim_create_user_command("SqlConn", M.switch, {
    desc = "Сменить подключение и базу буфера запроса",
  })
  vim.api.nvim_create_user_command("SqlRun", M.run, {
    bang = true,
    range = true,
    desc = "Выполнить буфер или выделение через sqlcmd (! — выбрать подключение и базу)",
  })
  vim.api.nvim_create_user_command("SqlExport", M.export, {
    bang = true,
    range = true,
    nargs = "?",
    complete = "file",
    desc = "Выполнить буфер или выделение, ответ записать в файл (по умолчанию рядом <имя>.txt; ! — выбрать подключение и базу)",
  })

  -- Постоянные запросы привязываются к подключению при каждом открытии, в том числе
  -- из восстановленной сессии: b:sqlctx в сессию не пишется, строка в файле — да.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("sqlquery", { clear = true }),
    pattern = "*.sql",
    callback = function(ev)
      if M.is_query_file(ev.match) then
        M.attach_file(ev.buf)
      end
    end,
  })
end

return M
