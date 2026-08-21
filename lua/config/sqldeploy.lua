-- :SqlDeploy — выложить текущий .sql файл в базу через sqlcmd.
--
-- Зачем отдельная команда, а не dadbod: dadbod отдаёт содержимое буфера во
-- временный файл в UTF-8 и вызывает sqlcmd без -f, поэтому кириллица в теле
-- объекта приезжает в базу битой. Здесь файл отдаётся sqlcmd как есть (-i),
-- а кодировка определяется по его байтам — так же, как это делает
-- .claude/tasks/260813_SqlEncodingDetection_Deploy.ps1 в репозитории dgsql.
--
-- Сервер/логин берутся из подключений dadbod-ui (переменные DB_UI_* в .env
-- проекта), база — из URL подключения либо из первой папки пути, если она
-- совпадает с именем базы на сервере (ics_ua97/..., icsMaster/..., Crocus/...).

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "SqlDeploy" })
end

---Строгая проверка UTF-8 (без BOM): отличает utf-8 от cp1251.
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

---Кодировка входного файла для sqlcmd.
---@return integer|false|nil cp номер кодовой страницы для `-f i:<cp>`;
---false — если -f передавать не нужно (utf-16 с BOM); nil — кодировка не поддерживается
---@return string? errmsg
local function input_codepage(path)
  local f, ferr = io.open(path, "rb")
  if not f then
    return nil, ferr
  end
  local bytes = f:read("*a") or ""
  f:close()
  local b1, b2, b3, b4 = bytes:byte(1, 4)
  -- UTF-32 проверяем первым: первые два байта UTF-32LE BOM совпадают с UTF-16LE BOM
  if
    (b1 == 0xFF and b2 == 0xFE and b3 == 0x00 and b4 == 0x00)
    or (b1 == 0x00 and b2 == 0x00 and b3 == 0xFE and b4 == 0xFF)
  then
    return nil, "UTF-32 sqlcmd не читает — перекодируйте файл в cp1251, utf-8 или utf-16"
  end
  if (b1 == 0xFE and b2 == 0xFF) or (b1 == 0xFF and b2 == 0xFE) then
    return false -- utf-16 с BOM: sqlcmd распознаёт сам
  end
  if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
    return 65001
  end
  if not bytes:find("[\128-\255]") then
    return 1251 -- чистый ASCII — подмножество cp1251
  end
  return is_utf8(bytes) and 65001 or 1251
end

---Подключения из .env рядом с файлом (те же, что видит dadbod-ui).
local function connections(file)
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

---Аргументы аутентификации sqlcmd, окружение с паролем и база из URL.
local function auth_args(url)
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
  return args, env, (u.path or ""):gsub("^/", "")
end

local db_cache = {}

---Список баз на сервере — чтобы не гадать, база ли первая папка пути.
local function server_databases(args, env)
  local key = table.concat(args, " ")
  if db_cache[key] then
    return db_cache[key]
  end
  local cmd = vim.list_extend({ "sqlcmd" }, vim.deepcopy(args))
  vim.list_extend(cmd, { "-l", "10", "-h-1", "-W", "-Q", "SET NOCOUNT ON; SELECT name FROM sys.databases" })
  local res = vim.system(cmd, { env = env, text = true }):wait()
  local names = {}
  if res.code == 0 then
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
      names[line:lower()] = line
    end
  end
  db_cache[key] = names
  return names
end

---База: первая папка пути, если такая база есть на сервере, иначе база из URL.
local function target_database(file, url_db, args, env)
  local root = vim.fs.root(file, ".git")
  if root then
    local rel = vim.fs.normalize(file):sub(#vim.fs.normalize(root) + 2)
    local first = rel:match("^([^/]+)/")
    if first then
      local exact = server_databases(args, env)[first:lower()]
      if exact and exact:lower() ~= (url_db or ""):lower() then
        return exact, true
      end
    end
  end
  return url_db, false
end

---Вывод sqlcmd в нижнем сплите. Курсор остаётся в файле, если деплой прошёл,
---и переходит в вывод, если sqlcmd вернул ошибку — её сразу надо читать.
local function show_output(title, lines, ok)
  local from = vim.api.nvim_get_current_win()
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "sqldeploy://" .. title)
  vim.api.nvim_win_set_height(0, math.min(20, math.max(5, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Закрыть вывод sqlcmd" })
  if ok and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
end

local function run(file, conn, override_db)
  local args, env, url_db = auth_args(conn.url)
  local database, from_path = override_db, false
  if not database then
    database, from_path = target_database(file, url_db, args, env)
  end
  if not database or database == "" then
    notify(
      "не определена база: добавьте её в URL или вызовите :SqlDeploy "
        .. conn.name
        .. " <база>",
      vim.log.levels.ERROR
    )
    return
  end
  local cp, cperr = input_codepage(file)
  if cp == nil then
    notify(cperr or "не удалось определить кодировку файла", vim.log.levels.ERROR)
    return
  end

  local cmd = vim.list_extend({ "sqlcmd" }, args)
  vim.list_extend(cmd, { "-d", database, "-b", "-I", "-r" })
  if cp then
    vim.list_extend(cmd, { "-f", "i:" .. cp })
  end
  -- sqlcmd обрезает путь с прямыми слэшами на первом двоеточии ("file C: Access is denied")
  local input = vim.fs.normalize(file)
  vim.list_extend(cmd, { "-i", vim.fn.has("win32") == 1 and input:gsub("/", "\\") or input })

  local name = vim.fn.fnamemodify(file, ":t")
  local target = conn.name .. " / " .. database .. (from_path and " (база из пути)" or "")
  notify(("%s -> %s (cp=%s)"):format(name, target, cp or "utf-16"))
  vim.system(cmd, { env = env }, function(res)
    -- sqlcmd пишет вывод в ANSI-кодировке консоли
    local text = vim.fn.iconv((res.stdout or "") .. (res.stderr or ""), "cp1251", "utf-8")
    local lines = vim.split(text:gsub("\r", ""), "\n", { trimempty = true })
    vim.schedule(function()
      if #lines > 0 then
        show_output(name .. " @ " .. conn.name .. "/" .. database, lines, res.code == 0)
      end
      if res.code == 0 then
        notify("готово: " .. name .. " -> " .. conn.name .. "/" .. database)
      else
        notify("sqlcmd завершился с кодом " .. res.code, vim.log.levels.ERROR)
      end
    end)
  end)
end

---@param opts table аргументы команды: [1] — имя подключения, [2] — база
function M.deploy(opts)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    return notify("нет файла в буфере", vim.log.levels.ERROR)
  end
  if vim.bo.modified then
    return notify(
      "буфер не сохранён: sqlcmd читает файл с диска, сначала :w",
      vim.log.levels.ERROR
    )
  end
  if vim.fn.executable("sqlcmd") == 0 then
    return notify("sqlcmd не найден в PATH", vim.log.levels.ERROR)
  end

  local list = connections(file)
  if #list == 0 then
    return notify("не найдено подключений DB_UI_* в .env проекта", vim.log.levels.ERROR)
  end

  local wanted, override_db = opts.fargs[1], opts.fargs[2]
  local function go(conn)
    if not conn then
      return notify("отменено")
    end
    -- база, названная явно, важнее и базы из URL, и базы из пути
    run(file, conn, override_db)
  end

  if wanted then
    for _, c in ipairs(list) do
      if c.name == wanted:lower() then
        return go(c)
      end
    end
    return notify("нет подключения " .. wanted, vim.log.levels.ERROR)
  end
  if #list == 1 then
    return go(list[1])
  end
  vim.ui.select(list, {
    prompt = "Выложить " .. vim.fn.fnamemodify(file, ":t") .. " в:",
    format_item = function(c)
      return c.name
    end,
  }, go)
end

function M.setup()
  vim.api.nvim_create_user_command("SqlDeploy", M.deploy, {
    nargs = "*",
    desc = "Выложить текущий .sql файл через sqlcmd",
    complete = function(lead)
      local names = vim.tbl_map(function(c)
        return c.name
      end, connections(vim.api.nvim_buf_get_name(0)))
      return vim.tbl_filter(function(n)
        return n:find(lead, 1, true) == 1
      end, names)
    end,
  })
end

return M
