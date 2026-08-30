-- Общая часть команд для MS SQL (:SqlDeploy, :SqlDef, :SqlRows): где взять
-- подключение, куда именно идти для текущего файла и как позвать sqlcmd.
--
-- Подключения берутся из dadbod-ui (DB_UI_* в .env проекта), сервер и базы — по
-- правилам репозитория из .claude/repo-conventions.json, тем же, по которым
-- выкладывает скилл deploy-commit (x:/Git/Dev/ClaudeSkillsMarketplace):
--   сервер — environment верхней папки пути (Crocus -> crocus), иначе
--            defaultServerEnvironment; адрес из .mcp.environments.json, а
--            логин/пароль — из подключения DB_UI_* с таким же хостом;
--   базы   — из «сторожа» в конце файла (usBases ... OptionsDB & 0x…) через
--            icsMaster.dbo.usBases, иначе из маски верхней папки. Маска часто даёт
--            несколько баз (0x3000000 -> DataGroup + ICS_UA97).
-- Реестр usBases всегда читается с сервера окружения default: он там один на всех,
-- даже когда сам файл уезжает на другой сервер.
--
-- Без repo-conventions.json (обычный репозиторий) работают запасные правила:
-- dev-подключение по имени/хосту и база из первой папки пути либо из URL.

local M = {}

function M.notify(msg, level, title)
  vim.notify(msg, level or vim.log.levels.INFO, { title = title or "SQL" })
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

---sqlcmd на подключении conn в базе database с аргументами extra.
---@param on_done fun(code: integer, text: string) вызывается вне основного цикла
function M.sqlcmd(conn, database, extra, on_done)
  local args, env = M.auth_args(conn.url)
  local cmd = vim.list_extend({ "sqlcmd" }, args)
  vim.list_extend(cmd, { "-d", database })
  vim.list_extend(cmd, extra)
  vim.system(cmd, { env = env }, function(res)
    on_done(res.code, (M.output_to_utf8((res.stdout or "") .. (res.stderr or "")):gsub("\r", "")))
  end)
end

---Разовый запрос одной колонки через sqlcmd, синхронно (ответ короткий и быстрый).
function M.query(conn, database, sql)
  local args, env = M.auth_args(conn.url)
  local cmd = vim.list_extend({ "sqlcmd" }, args)
  vim.list_extend(cmd, { "-d", database, "-l", "10", "-h-1", "-W", "-f", "i:65001", "-Q", "SET NOCOUNT ON; " .. sql })
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

local db_cache = {}

---Список баз на сервере — чтобы не гадать, база ли первая папка пути.
function M.server_databases(conn)
  if not db_cache[conn.url] then
    local names = {}
    for _, line in ipairs(M.query(conn, "master", "SELECT name FROM sys.databases")) do
      names[line:lower()] = line
    end
    db_cache[conn.url] = names
  end
  return db_cache[conn.url]
end

---Первая папка пути внутри репозитория, имя репозитория и его корень.
function M.repo_folder(file)
  local root = file ~= "" and vim.fs.root(file, ".git") or nil
  if not root then
    return nil, nil, nil
  end
  root = vim.fs.normalize(root)
  local rel = vim.fs.normalize(file):sub(#root + 2)
  return rel:match("^([^/]+)/"), vim.fs.basename(root), root
end

local json_cache = {}

local function read_json(path)
  if json_cache[path] == nil then
    local ok, data = pcall(vim.json.decode, M.read_file(path))
    json_cache[path] = ok and data or false
  end
  return json_cache[path] or nil
end

---.claude/repo-conventions.json — правила репозитория, по которым выкладывает и скилл
---deploy-commit: маска OptionsDB и сервер (environment) для верхней папки пути.
local function conventions(root)
  return root and read_json(root .. "/.claude/repo-conventions.json") or nil
end

---Правила верхней папки пути из repo-conventions.json (mask/environment).
local function folder_rules(conv, folder)
  local masks = conv.usBases and conv.usBases.topFolderMasks
  if not (masks and folder) then
    return nil
  end
  if masks[folder] then
    return masks[folder]
  end
  for name, rules in pairs(masks) do
    if name:lower() == folder:lower() then
      return rules
    end
  end
end

---Адрес сервера по имени окружения — из .mcp.environments.json репозитория.
local function env_server(root, conv, name)
  local data = read_json(root .. "/" .. (conv.mcpEnvironmentsPath or ".claude/.mcp.environments.json"))
  for _, e in ipairs(data and data.environments or {}) do
    if e.name == name then
      return e.server
    end
  end
end

---Подключение с таким же хостом: сервер знает .mcp.environments.json, а логин и
---пароль — только .env (в environments-файле вместо пароля ${secret:...}).
local function connection_for_server(list, server)
  if not server or server == "" then
    return nil
  end
  for _, c in ipairs(list) do
    if (M.url_parts(c.url)):lower() == server:lower() then
      return c
    end
  end
end

---Маска OptionsDB из «сторожа» в конце файла — это и есть ответ самого объекта на
---вопрос, в каких базах он должен существовать.
local function guard_mask(file)
  return M.read_file(file):lower():match("usbases%s+where%s+dbname%s*=%s*db_name%(%)%s+and%s+optionsdb%s*&%s*(0x%x+)")
end

local mask_cache = {}

---Базы по маске. Реестр usBases живёт в icsMaster на сервере окружения default —
---оттуда его и читаем, даже если файл уедет на другой сервер.
local function mask_databases(mask, registry)
  local key = registry.url .. " " .. mask
  if not mask_cache[key] then
    mask_cache[key] =
      M.query(registry, "icsMaster", "select dbName from dbo.usBases where OptionsDB & " .. mask .. " <> 0")
  end
  return mask_cache[key]
end

---Запасное правило: первая папка пути, если такая база есть на сервере, иначе база из URL.
local function database_by_path(file, conn)
  local first = M.repo_folder(file)
  local url_db = select(2, M.url_parts(conn.url))
  if first then
    local exact = M.server_databases(conn)[first:lower()]
    if exact and exact:lower() ~= url_db:lower() then
      return exact, "база из пути"
    end
  end
  return url_db, "база из URL"
end

---Запасное правило выбора подключения: test-подключения отбрасываются (учётка там на
---чтение), среди dev-подключений берётся то, чья база из URL совпадает с первой папкой
---пути, потом — чей сервер единственный, где есть база с таким именем, потом — чьё имя
---содержит имя репозитория.
---@return table? conn nil — выбор неоднозначен, спрашиваем
local function connection_by_name(file, list)
  local dev = vim.tbl_filter(function(c)
    return c.name:lower():match("dev$") ~= nil
  end, list)
  local cands = #dev > 0 and dev or list
  if #cands == 1 then
    return cands[1]
  end
  if #dev == 0 then
    return nil -- нет подключений с dev в имени: молча выкладывать некуда
  end
  local first, repo = M.repo_folder(file)
  if first then
    local hosting = {}
    for _, c in ipairs(dev) do
      if select(2, M.url_parts(c.url)):lower() == first:lower() then
        return c
      end
      if M.server_databases(c)[first:lower()] then
        hosting[#hosting + 1] = c
      end
    end
    if #hosting == 1 then
      return hosting[1]
    end
  end
  if repo then
    for _, c in ipairs(dev) do
      if c.name:lower():find(repo:lower(), 1, true) then
        return c
      end
    end
  end
  return nil
end

---Сервер для файла: environment верхней папки, иначе defaultServerEnvironment.
---@return table? conn nil — правил нет и запасные не сработали, спрашиваем
function M.resolve_connection(file, list)
  local first, _, root = M.repo_folder(file)
  local conv = conventions(root)
  if conv then
    local rules = folder_rules(conv, first)
    local conn = connection_for_server(
      list,
      env_server(root, conv, (rules and rules.environment) or conv.defaultServerEnvironment)
    )
    if conn then
      return conn
    end
  end
  return connection_by_name(file, list)
end

---Базы для файла: маска-сторож самого файла, иначе маска верхней папки, иначе
---запасное правило по пути/URL.
---@return string[] databases, string how откуда они взялись — для сообщения
function M.resolve_databases(file, conn, list, override_db)
  if override_db and override_db ~= "" then
    return { override_db }, "база указана явно"
  end
  local first, _, root = M.repo_folder(file)
  local conv = conventions(root)
  if conv then
    local rules = folder_rules(conv, first)
    local mask = guard_mask(file) or (rules and rules.mask)
    if mask then
      local registry = connection_for_server(list, env_server(root, conv, conv.defaultServerEnvironment)) or conn
      -- маска резолвится по общему реестру, а работаем с конкретным сервером: оставляем
      -- только те базы, которые на нём есть. Так отсекается чужой сторож, скопированный в
      -- Crocus/** из ics_ua97 (0x3000000 -> DataGroup + ICS_UA97, которых на Crocus нет).
      local dbs = {}
      for _, db in ipairs(mask_databases(mask, registry)) do
        local exact = M.server_databases(conn)[db:lower()]
        if exact then
          dbs[#dbs + 1] = exact
        end
      end
      if #dbs > 0 then
        return dbs, "usBases " .. mask
      end
      M.notify(
        "маска " .. mask .. " не дала баз на " .. conn.name .. " — беру базу по пути",
        vim.log.levels.WARN
      )
    end
  end
  local db, how = database_by_path(file, conn)
  return db ~= "" and { db } or {}, how
end

---Подключение и базы для файла разом; conn == nil — выбор неоднозначен, надо спросить.
---@return table? conn, string[] databases, string how
function M.resolve(file, list, override_db)
  local conn = M.resolve_connection(file, list)
  if not conn then
    return nil, {}, ""
  end
  local dbs, how = M.resolve_databases(file, conn, list, override_db)
  return conn, dbs, how
end

---Подключение по имени из аргумента команды.
function M.by_name(list, wanted)
  for _, c in ipairs(list) do
    if c.name == wanted:lower() then
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

return M
