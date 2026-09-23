-- Как позвать sqlcmd: подключения из .env, аутентификация, кодировки, флаги.
-- Куда именно идти для конкретного файла — отдельно, в config.sqltarget.
--
-- Подключения берутся из dadbod-ui (DB_UI_* в .env проекта), логин и пароль — из
-- окружения (SQLCMDUSER и прочие, их раскрывает vim-dotenv).

local M = {}

function M.notify(msg, level, title)
  vim.notify(msg, level or vim.log.levels.INFO, { title = title or "SQL" })
end

---notify с постоянным заголовком — по одной обёртке на команду.
function M.notifier(title)
  return function(msg, level)
    M.notify(msg, level, title)
  end
end

---Индикатор «идёт запрос»: обычное уведомление гаснет через пару секунд, а sqlcmd
---на тяжёлой выборке думает и полминуты — всё это время непонятно, идёт что-то или
---уже ничего. Уведомление с крутилкой держится ровно пока живёт процесс.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local progress_seq = 0

---@return fun() stop погасить индикатор; вызывать в основном цикле
---@return fun(msg: string) update сменить текст, не заводя второе уведомление
function M.progress(msg, title)
  local function update(new)
    msg = new
  end
  -- Snacks.notifier умеет обновлять уведомление по id и держать его без таймаута;
  -- без него (голый vim.notify) крутилка насыпала бы по сообщению на кадр
  local notifier = _G.Snacks and Snacks.notifier
  if not notifier then
    M.notify(msg, nil, title)
    return function() end, update
  end
  progress_seq = progress_seq + 1
  local id = "sqlprogress" .. progress_seq
  local timer, frame = vim.uv.new_timer(), 0
  local function draw()
    frame = frame % #SPINNER + 1
    notifier.notify(msg, vim.log.levels.INFO, {
      id = id,
      title = title or "SQL",
      icon = SPINNER[frame],
      timeout = false,
      history = false, -- в истории уведомлений от крутилки толку нет
    })
  end
  draw()
  timer:start(100, 100, vim.schedule_wrap(draw))
  local function stop()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    notifier.hide(id)
  end
  return stop, update
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local text = f:read("*a") or ""
  f:close()
  return text
end

---Строгая проверка UTF-8: отличает вывод sqlcmd в utf-8 от вывода в cp1251.
local function is_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then
      len = 1
    elseif c >= 0xC2 and c <= 0xDF then
      len = 2
    elseif c >= 0xE0 and c <= 0xEF then
      len = 3
    elseif c >= 0xF0 and c <= 0xF4 then
      len = 4
    else
      return false
    end
    for j = 1, len - 1 do
      local cc = s:byte(i + j)
      if not cc or cc < 0x80 or cc > 0xBF then
        return false
      end
    end
    i = i + len
  end
  return true
end

---Вывод sqlcmd. С -f i:65001 он в utf-8, но когда процессу не досталось консоли — а из
---nvim не достаётся — sqlcmd игнорирует флаг и пишет в ANSI-кодировке. Смотрим байты.
function M.output_to_utf8(text)
  return is_utf8(text) and text or vim.fn.iconv(text, "cp1251", "utf-8")
end

---Подключения из .env рядом с файлом (те же, что видит dadbod-ui).
function M.connections(file)
  require("lazy").load({ plugins = { "vim-dotenv", "vim-dadbod" } })
  local env = {}
  local dir = file ~= "" and vim.fs.dirname(file) or vim.uv.cwd()
  local found = vim.fs.find(".env", { path = dir, upward = true, type = "file" })[1]
  if found then
    env = vim.fn.DotenvRead(found)
  elseif vim.fn.exists("*DotenvGet") == 1 then
    env = vim.fn.DotenvGet()
  end
  local prefix = vim.g.db_ui_dotenv_variable_prefix or "DB_UI_"
  local list = {}
  for name, url in pairs(env) do
    local short = name:match("^" .. prefix .. "(.+)$")
    if short then
      list[#list + 1] = { name = short:lower(), url = url }
    end
  end
  for _, db in ipairs(type(vim.g.dbs) == "table" and vim.g.dbs or {}) do
    list[#list + 1] = { name = db.name, url = db.url }
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

---Хост и база из URL подключения ("" — если их там нет).
function M.url_parts(url)
  local ok, u = pcall(function()
    return vim.fn["db#url#parse"](vim.fn["db#resolve"](url))
  end)
  if not ok then
    return "", ""
  end
  return u.host or "", ((u.path or ""):gsub("^/", ""))
end

---URL подключения с подменённой базой — для b:db, чтобы работало дополнение имён
---таблиц и колонок (vim-dadbod-completion смотрит именно на b:db).
function M.with_database(url, database)
  local base, params = url:match("^([^?]*)(.*)$")
  local authority = base:match("^(.-://[^/]*)")
  if not authority then
    return url
  end
  return authority .. "/" .. database .. params
end

---Подключение по имени из аргумента команды. Регистр не важен с обеих сторон:
---имена из .env приведены к нижнему, а из vim.g.dbs — какие записали.
function M.by_name(list, wanted)
  for _, c in ipairs(list) do
    if c.name:lower() == wanted:lower() then
      return c
    end
  end
end

---Спросить подключение у пользователя.
function M.select(list, prompt, cb)
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(c)
      return c.name
    end,
  }, cb)
end

---Аргументы аутентификации sqlcmd и окружение с паролем.
function M.auth_args(url)
  local u = vim.fn["db#url#parse"](vim.fn["db#resolve"](url))
  local params = u.params or {}
  local args = { "-S", u.host }
  if u.user and u.user ~= "" then
    vim.list_extend(args, { "-U", u.user })
  else
    table.insert(args, "-E") -- доменная учётка
  end
  local trust = params.trustServerCertificate or params.TrustServerCertificate
  if trust and tostring(trust):match("^[1tTyY]") then
    table.insert(args, "-C")
  end
  local env = {}
  if u.password and u.password ~= "" then
    env.SQLCMDPASSWORD = u.password -- через окружение, а не -P, чтобы не светить в списке процессов
  end
  return args, env
end

---Путь для sqlcmd: путь с прямыми слэшами он обрезает на первом двоеточии
---("file C: Access is denied"), поэтому на Windows отдаём его в родном виде.
function M.native_path(path)
  local p = vim.fs.normalize(path)
  return vim.fn.has("win32") == 1 and (p:gsub("/", [[\]])) or p
end

---Флаги sqlcmd в одном месте: набор неочевидный, а собирался он раньше в шести
---местах по-разному.
---  -b         ненулевой код возврата при ошибке, иначе её не отличить от успеха
---  -I         QUOTED_IDENTIFIER ON — скриптам на входе он нужен всегда
---  -r         ошибки в stderr: без этого их не видно в выводе деплоя
---  -f i:<cp>  кодировка входа. Форма именно i:<cp>: от неё sqlcmd пишет вывод в
---             utf-8, а от голого -f <cp> — в ANSI-кодировке консоли. Добавлять
---             o:65001 нельзя: вместе с -r эта пара переключает весь вывод обратно
---             в ANSI (sqlcmd 15.0.4298.1)
---  -w         ширина строки: без неё sqlcmd ломает её на 80 символах и таблица
---             едет в кашу
---  -y/-Y      до скольких символов резать колонки. -y0 значит «не резать», а для
---             -Y ноль не документирован — в этом случае его не ставим
---@param o { query: string?, input: string?, codepage: string?, width: integer?, trunc: integer?, stderr: boolean? }
function M.args(o)
  local a = { "-b", "-f", o.codepage or "i:65001" }
  if o.input then
    table.insert(a, "-I")
  end
  if o.stderr then
    table.insert(a, "-r")
  end
  if o.width then
    vim.list_extend(a, { "-w", tostring(o.width) })
  end
  if o.trunc then
    vim.list_extend(a, { "-y", tostring(o.trunc) })
    if o.trunc > 0 then
      vim.list_extend(a, { "-Y", tostring(o.trunc) })
    end
  end
  if o.query then
    vim.list_extend(a, { "-Q", o.query })
  end
  if o.input then
    vim.list_extend(a, { "-i", M.native_path(o.input) })
  end
  return a
end

---Есть ли sqlcmd вообще. Проверка тут, а не в каждой команде: без неё вызов просто
---молча ничего не делает.
function M.ensure(title)
  if vim.fn.executable("sqlcmd") == 1 then
    return true
  end
  M.notify("sqlcmd не найден в PATH", vim.log.levels.ERROR, title)
  return false
end

---Запущенные прямо сейчас sqlcmd. Общий список, а не хэндл у того, кто запускал:
---запрос асинхронный, и отменяют его обычно уже из другого окна.
local jobs = {}

---Отменить всё, что сейчас выполняется: убиваем сам sqlcmd, а сервер, заметив
---оборванное соединение, гасит и сам запрос.
---@return string[] какие подключения/базы были остановлены
function M.cancel()
  local stopped = {}
  for job in pairs(jobs) do
    job.cancelled = true -- колбэк всё равно придёт, и по флагу видно, что ответа в нём нет
    pcall(function()
      job.proc:kill("sigterm") -- на Windows libuv всё равно завершает процесс принудительно
    end)
    stopped[#stopped + 1] = job.label
  end
  return stopped
end

---sqlcmd на подключении conn в базе database с аргументами extra.
---@param on_done fun(code: integer, text: string, cancelled: boolean) вызывается вне основного цикла
---@return table? процесс; nil — sqlcmd не нашёлся, запускать было нечего
function M.sqlcmd(conn, database, extra, on_done)
  if not M.ensure() then
    return nil
  end
  local args, env = M.auth_args(conn.url)
  local cmd = vim.list_extend({ "sqlcmd" }, args)
  vim.list_extend(cmd, { "-d", database })
  vim.list_extend(cmd, extra)
  local job = { label = conn.name .. "/" .. database }
  job.proc = vim.system(cmd, { env = env }, function(res)
    jobs[job] = nil
    on_done(
      res.code,
      (M.output_to_utf8((res.stdout or "") .. (res.stderr or "")):gsub("\r", "")),
      job.cancelled == true
    )
  end)
  jobs[job] = true
  return job.proc
end

---Разовый запрос одной колонки через sqlcmd, синхронно (ответ короткий и быстрый).
function M.query(conn, database, sql)
  if not M.ensure() then
    return {}
  end
  local args, env = M.auth_args(conn.url)
  local cmd = vim.list_extend({ "sqlcmd" }, args)
  vim.list_extend(cmd, { "-d", database })
  -- -h-1 -W: без заголовка и без выравнивания пробелами, -l 10: не ждать минуту,
  -- если сервера нет на месте
  vim.list_extend(cmd, M.args({ query = "SET NOCOUNT ON; " .. sql }))
  vim.list_extend(cmd, { "-l", "10", "-h-1", "-W" })
  local res = vim.system(cmd, { env = env }):wait()
  local rows = {}
  if res.code == 0 then
    for line in M.output_to_utf8(res.stdout or ""):gmatch("[^\r\n]+") do
      if not line:match("rows affected") then
        rows[#rows + 1] = line
      end
    end
  end
  return rows
end

---:SqlCancel — команда общая на все: отменяют не «деплой» или «запрос», а то, что
---сейчас крутится, а знает об этом только список jobs.
function M.setup()
  vim.keymap.set(
    "n",
    "<leader>dc",
    "<cmd>SqlCancel<cr>",
    { desc = "Отменить выполняющийся sqlcmd" }
  )
  vim.api.nvim_create_user_command("SqlCancel", function()
    local stopped = M.cancel()
    if #stopped == 0 then
      M.notify("нечего отменять", vim.log.levels.WARN)
    else
      M.notify("отменено: " .. table.concat(stopped, ", "), vim.log.levels.WARN)
    end
  end, { desc = "Прервать выполняющиеся sqlcmd (:SqlRun, :SqlDeploy)" })
end

return M
