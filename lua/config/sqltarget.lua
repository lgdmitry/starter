-- Куда идти для текущего файла: какое подключение и какие базы.
--
-- Сервер и базы — по правилам репозитория из .claude/repo-conventions.json, тем же, по
-- которым выкладывает скилл deploy-commit (x:/Git/Dev/ClaudeSkillsMarketplace):
--   сервер — environment верхней папки пути (Crocus -> crocus), иначе
--            defaultServerEnvironment; адрес из .mcp.environments.json, а
--            логин/пароль — из подключения DB_UI_* с таким же хостом;
--   базы   — из «сторожа» самого файла, если он там есть (usBases ... OptionsDB & 0x…
--            рядом с DROP — так объект сам говорит, в каких базах он должен жить;
--            маска часто даёт несколько баз: 0x3000000 -> datagroup + ics_ua97),
--            иначе по пути внутри репозитория — см. PATH_RULES ниже.
-- Реестр usBases всегда читается с сервера окружения default: он там один на всех,
-- даже когда сам файл уезжает на другой сервер.
--
-- Без repo-conventions.json (обычный репозиторий) работают запасные правила:
-- dev-подключение по имени/хосту и база из первой папки пути либо из URL.

local sql = require("config.sqlconn")

local M = {}

local db_cache = {}

---Список баз на сервере — чтобы не гадать, база ли первая папка пути.
local function server_databases(conn)
  if not db_cache[conn.url] then
    local names = {}
    for _, line in ipairs(sql.query(conn, "master", "SELECT name FROM sys.databases")) do
      names[line:lower()] = line
    end
    db_cache[conn.url] = names
  end
  return db_cache[conn.url]
end

---Путь файла внутри репозитория (в нижнем регистре, через /) и корень репозитория.
local function repo_path(file)
  local root = file ~= "" and vim.fs.root(file, ".git") or nil
  if not root then
    return nil, nil
  end
  root = vim.fs.normalize(root)
  return vim.fs.normalize(file):sub(#root + 2):lower(), root
end

---Первая папка пути внутри репозитория, имя репозитория и его корень.
local function repo_folder(file)
  local rel, root = repo_path(file)
  if not rel then
    return nil, nil, nil
  end
  return rel:match("^([^/]+)/"), vim.fs.basename(root), root
end

local json_cache = {}

local function read_json(path)
  if json_cache[path] == nil then
    local ok, data = pcall(vim.json.decode, sql.read_file(path))
    json_cache[path] = ok and data or false
  end
  return json_cache[path] or nil
end

---.claude/repo-conventions.json — правила репозитория, по которым выкладывает и скилл
---deploy-commit: маска OptionsDB и сервер (environment) для верхней папки пути.
local function conventions(root)
  return root and read_json(root .. "/.claude/repo-conventions.json") or nil
end

---Правила верхней папки пути из repo-conventions.json. Из них нужен только
---environment (Crocus -> crocus): базы выбираются по сторожу и PATH_RULES.
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
    if (sql.url_parts(c.url)):lower() == server:lower() then
      return c
    end
  end
end

-- Что считается «сторожем»: только самоудаление объекта —
--   if not exists (select 1 from icsMaster.dbo.usBases
--                   where dbName = DB_NAME() and OptionsDB & 0x1000000 <> 0)
--   begin DROP PROC dbo.SomeProc end
-- Такую маску объект сам называет своим ответом на вопрос «в каких базах я живу».
-- В _FK/_TAB/_TRG та же конструкция значит совсем другое — условное содержимое
-- («в этих базах ещё и создать индекс/констрейнт», а с not exists — «во всех, кроме
-- этих»), и маской считать её нельзя: для таких файлов работают правила по пути.
local DROP_KINDS = { "proc", "procedure", "view", "function", "func", "trigger", "table" }

local function drops_object(chunk)
  for _, kind in ipairs(DROP_KINDS) do
    if chunk:find("drop%s+" .. kind .. "%f[%A]") then
      return true
    end
  end
  return false
end

---Маска OptionsDB из сторожа файла. Масок бывает несколько (в файле несколько
---объектов) — берём первую, как это делает скилл deploy-commit.
local function guard_mask(file)
  local text = sql.read_file(file):lower()
  for pos, mask in text:gmatch("()usbases%s+where%s+dbname%s*=%s*db_name%(%)%s+and%s+optionsdb%s*&%s*(0x%x+)") do
    local before = text:sub(math.max(1, pos - 80), pos - 1)
    if before:match("if%s+not%s+exists%s*%(%s*select[^()]*$") and drops_object(text:sub(pos, pos + 400)) then
      return mask
    end
  end
end

local mask_cache = {}

---Базы по маске. Реестр usBases живёт в icsMaster на сервере окружения default —
---оттуда его и читаем, даже если файл уедет на другой сервер.
local function mask_databases(mask, registry)
  local key = registry.url .. " " .. mask
  if not mask_cache[key] then
    mask_cache[key] =
      sql.query(registry, "icsMaster", "select dbName from dbo.usBases where OptionsDB & " .. mask .. " <> 0")
  end
  return mask_cache[key]
end

-- Куда выкладывать по пути внутри репозитория — первое подходящее правило.
-- Порядок важен: ics_ua97/bk/ и ics_ua97/Support/ должны стоять раньше ics_ua97/.
-- В databases перечислены варианты одной и той же базы для разных репозиториев:
-- берётся тот, который есть на целевом сервере (bk — это datagroup в dgsql и
-- icsZao в esql; серверы у них разные, так что двусмысленности нет).
local PATH_RULES = {
  { prefix = "crocus/", databases = { "Crocus" } },
  { prefix = "bk/", databases = { "datagroup", "icsZao" } },
  { prefix = "ics_ua97/bk/", databases = { "datagroup", "icsZao" } },
  { prefix = "ics_ua97/support/", databases = { "DEV_NEW" } },
  { prefix = "ics_ua97/", databases = { "ics_ua97" } },
  { prefix = "icsmaster/", databases = { "icsMaster" } },
}

---База по правилам PATH_RULES.
---@return string|false|nil database nil — правило не подошло, решают следующие;
---false — правило подошло, но нужной базы на сервере нет. Дальше гадать нельзя:
---запасное правило увело бы файл в базу из URL, то есть выложило бы не туда
---@return string? how
local function database_by_rules(file, conn)
  local rel = repo_path(file)
  if not rel then
    return nil
  end
  for _, rule in ipairs(PATH_RULES) do
    if rel:sub(1, #rule.prefix) == rule.prefix then
      for _, name in ipairs(rule.databases) do
        local exact = server_databases(conn)[name:lower()]
        if exact then
          return exact, "по пути " .. rule.prefix .. "**"
        end
      end
      return false,
        ("для %s** нужна база %s, а на %s её нет"):format(
          rule.prefix,
          table.concat(rule.databases, " или "),
          conn.name
        )
    end
  end
end

---Запасное правило: первая папка пути, если такая база есть на сервере, иначе база из URL.
local function database_by_path(file, conn)
  local first = repo_folder(file)
  local url_db = select(2, sql.url_parts(conn.url))
  if first then
    local exact = server_databases(conn)[first:lower()]
    if exact and exact:lower() ~= url_db:lower() then
      return exact, "база из пути"
    end
  end
  if url_db == "" then
    return nil, "в URL подключения нет базы"
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
  local first, repo = repo_folder(file)
  if first then
    local hosting = {}
    for _, c in ipairs(dev) do
      if select(2, sql.url_parts(c.url)):lower() == first:lower() then
        return c
      end
      if server_databases(c)[first:lower()] then
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
  local first, _, root = repo_folder(file)
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

---Базы для файла: сторож самого файла (он же даёт мультидеплой), иначе правило по
---пути, иначе запасное правило по папке/URL.
---@return string[] databases, string? how откуда они взялись или почему их нет — для сообщения
function M.resolve_databases(file, conn, list)
  local mask = guard_mask(file)
  if mask then
    local _, root = repo_path(file)
    local conv = conventions(root)
    local registry = conv and connection_for_server(list, env_server(root, conv, conv.defaultServerEnvironment)) or conn
    -- маска резолвится по общему реестру, а работаем с конкретным сервером: оставляем
    -- только те базы, которые на нём есть. Так отсекается чужой сторож, скопированный в
    -- Crocus/** из ics_ua97 (0x3000000 -> datagroup + ics_ua97, которых на Crocus нет).
    local dbs = {}
    for _, db in ipairs(mask_databases(mask, registry)) do
      local exact = server_databases(conn)[db:lower()]
      if exact then
        dbs[#dbs + 1] = exact
      end
    end
    if #dbs > 0 then
      return dbs, "usBases " .. mask
    end
    -- маска ничего не дала на этом сервере (в Crocus/** лежат сторожа, скопированные
    -- из ics_ua97) — молча уходим на правило по пути, там оно и должно решать
  end
  local db, how = database_by_rules(file, conn)
  if db == false then
    return {}, how -- правило знает, что базы нет: запасное тут только навредит
  end
  if not db then
    db, how = database_by_path(file, conn)
  end
  return db and { db } or {}, how
end

---Подключение и базы для файла: сначала по правилам, а если однозначно не выходит —
---спрашиваем. Форма одна на все команды, поэтому всё различие вынесено в opts.
---@param opts table
---  file     — файл, для которого решаем (из ctx.file, если контекст есть)
---  ctx      — контекст буфера (b:sqlctx): окно ответа и черновик запроса привязаны к
---             подключению и базе, в которых уже смотрели, — их и переиспользуем
---  bang     — подключение спросить в любом случае
---  name     — подключение названо явно, аргументом команды
---  database — база названа явно, аргументом команды
---  prompt   — заголовок списка подключений
---  hint     — что дописать к ошибке «не определена база»
---  title    — заголовок уведомлений
---@param cb fun(conn: table, databases: string[], file: string, how: string?)
function M.pick(opts, cb)
  local notify = sql.notifier(opts.title)
  local ctx = opts.ctx
  -- имя буфера ответа или черновика — не файл, поэтому .env ищем по исходному файлу
  local file = (ctx and ctx.file) or opts.file or ""
  local list = sql.connections(file)
  if #list == 0 then
    return notify("не найдено подключений DB_UI_* в .env проекта", vim.log.levels.ERROR)
  end

  local function go(conn)
    if not conn then
      return notify("отменено")
    end
    local dbs, how
    if opts.database and opts.database ~= "" then
      dbs, how = { opts.database }, "база указана явно"
    elseif ctx and ctx.db and ctx.conn == conn.name then
      dbs, how = { ctx.db }, "база окна"
    else
      dbs, how = M.resolve_databases(file, conn, list)
    end
    if #dbs == 0 then
      return notify(
        "не определена база" .. (how and (": " .. how) or "") .. (opts.hint or ""),
        vim.log.levels.ERROR
      )
    end
    cb(conn, dbs, file, how)
  end

  if opts.name then
    -- без if тут был бы and/or: go() возвращает nil, и «нет подключения» печаталось
    -- бы даже после удачного выбора
    local conn = sql.by_name(list, opts.name)
    if not conn then
      return notify("нет подключения " .. opts.name, vim.log.levels.ERROR)
    end
    return go(conn)
  end
  if not opts.bang then
    -- подключение окна важнее правил: в нём могли выбрать другое вручную, и K внутри
    -- ответа должен остаться там же, а не уехать обратно по правилам файла
    local conn = (ctx and ctx.conn and sql.by_name(list, ctx.conn)) or M.resolve_connection(file, list)
    if conn then
      return go(conn)
    end
  end
  sql.select(list, opts.prompt or "Подключение:", go)
end

function M.setup()
  -- Списки баз, реестр usBases и repo-conventions.json читаются один раз за сессию:
  -- меняются они редко, а запрос к серверу синхронный. Но если базу только что
  -- завели или поправили правила, перезапускать nvim ради этого не надо.
  vim.api.nvim_create_user_command("SqlCacheClear", function()
    db_cache, mask_cache, json_cache = {}, {}, {}
    sql.notify("кэш баз и правил сброшен")
  end, { desc = "Забыть списки баз, реестр usBases и repo-conventions.json" })
end

return M
