-- Подключения к MS SQL — для dadbod-ui (:DBUI читает g:dbs сам) и своего слоя
-- (mssql.conn.connections).
--
-- Раньше они лежали в .env каждого проекта (c:/repo/dgsql, c:/repo/esql), и видно их
-- было только из папки проекта: vim-dotenv ищет .env от текущего каталога. Здесь — одно
-- место на все проекты, под git.
--
-- По одному подключению на сервер: базу для файла дают правила (mssql.target), в
-- буфере запроса её выбирают через :SqlConn, так что база в URL — лишь запасная, когда
-- правила ничего не дали. Несколько подключений на один хост, отличающихся только
-- базой, слою вредили: сервер для файла ищется по хосту, и находилось первое по
-- алфавиту (dgsql_datagroup вместо dgsql_dev). Цена — в дереве :DBUI у подключения
-- видна только база из URL: dadbod-ui для sqlserver других баз не показывает.
--
-- Паролей здесь нет. Логины — ${VAR} из окружения, те же, что у MCP-серверов
-- mssqlclient-*, пароли — из Credential Manager (подробности у CREDREAD ниже):
--   dev  — $SQLCMDUSER, запись mssql:dev; esql — доменная учётка (-E): в домене
--          из наших серверов только EXPRESS;
--   test — $MSSQL_TESTUSER, запись mssql:test, только чтение.
-- Хосты тоже из окружения ($MSSQL_SERVER_*, общие с MCP): сервер переедет — поменять
-- одну переменную, а не этот файл и каждый .cmd. Dev и test живут на одном хосте и
-- различаются инстансом (\snickers / \test), он здесь, в коде, а не в переменной.
-- Раскрываем при старте, как делал vim-dotenv: dadbod сам ${VAR} внутри URL не понимает.

local function env(url)
  return (url:gsub("%${([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end))
end

-- dadbod раскодирует пароль из URL (db#url#decode), так что спецсимволы (@ : / %) надо
-- закодировать, иначе URL разберётся не так. Байты не-ASCII оставляем: decode собирает
-- символ из каждого %XX отдельно и UTF-8 бы испортил.
local function urlencode(s)
  return (s:gsub("[^%w%-._~\128-\255]", function(ch)
    return string.format("%%%02X", ch:byte())
  end))
end

local TRUST = "?trustServerCertificate=true"
-- cred — запись Generic Credential в Credential Manager (cmdkey /generic:<cred> ...);
-- fallback — переменная с паролем на переходный период, пока пароль ещё не перенесён
-- в хранилище. Без user — доменная учётка (-E).
local DEV = { user = "${SQLCMDUSER}", cred = "mssql:dev", fallback = "SQLCMDPASSWORD" }
local TEST = { user = "${MSSQL_TESTUSER}", cred = "mssql:test", fallback = "MSSQL_TESTPASSWORD" }
local DOMAIN = {}
local DEV_INSTANCE = "\\snickers"
local TEST_INSTANCE = "\\test"

-- имена в нижнем регистре — как раньше из DB_UI_*: по ним ищут подключение правила
-- (…_dev) и аргументы команд
local servers = {
  { "dgsql_dev", DEV, "${MSSQL_SERVER_DATAGROUP}" .. DEV_INSTANCE .. "/datagroup" },
  { "dgsql_test", DEV, "${MSSQL_SERVER_DATAGROUP}" .. TEST_INSTANCE .. "/datagroup" },
  { "crocus_dev", DEV, "${MSSQL_SERVER_CROCUS}" .. DEV_INSTANCE .. "/Crocus" },
  { "crocus_test", TEST, "${MSSQL_SERVER_CROCUS}" .. TEST_INSTANCE .. "/Crocus" },
  { "esql_dev", DOMAIN, "${MSSQL_SERVER_EXPRESS}" .. DEV_INSTANCE .. "/ics_ua97" },
  { "esql_test", TEST, "${MSSQL_SERVER_EXPRESS}" .. TEST_INSTANCE .. "/ics_ua97" },
}

---Пароль учётки: из Credential Manager, иначе из переменной на переходный период.
local function password(auth, creds)
  local pw = auth.cred and creds[auth.cred]
  if (pw == nil or pw == "") and auth.fallback then
    pw = os.getenv(auth.fallback)
  end
  return pw ~= "" and pw or nil
end

local function build(creds)
  vim.g.dbs = vim.tbl_map(function(c)
    local auth, login = c[2], ""
    if auth.user then
      local pw = password(auth, creds)
      login = env(auth.user) .. (pw and ":" .. urlencode(pw) or "") .. "@"
    end
    return { name = c[1], url = "sqlserver://" .. login .. env(c[3]) .. TRUST }
  end, servers)
end

-- Пароли — в Credential Manager, а не в переменных окружения: переменные лежат в
-- реестре открытым текстом и наследуются каждым процессом (терминал, агенты,
-- MCP-серверы), откуда легко утекают в логи и транскрипты. Хранилище шифрует DPAPI и
-- отдаёт пароль только по прямому запросу. Читаем через PowerShell (CredRead) — это
-- секунда-две на компиляции Add-Type, поэтому асинхронно: сначала g:dbs собирается с
-- паролями из переменных (или без них), потом пересобирается, когда ответ пришёл.
-- DBUI, открытый в эти секунды, запомнит список без паролей — переоткрыть.
local CREDREAD = [=[
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -Namespace W -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
  public int Flags; public int Type; public string TargetName; public string Comment;
  public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
  public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
  public int AttributeCount; public IntPtr Attributes; public string TargetAlias;
  public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr cred);
'@
$out = @{}
foreach ($t in @(%s)) {
  $p = [IntPtr]::Zero
  if ([W.Cred]::CredRead($t, 1, 0, [ref]$p)) {
    $c = [Runtime.InteropServices.Marshal]::PtrToStructure($p, [type][W.Cred+CREDENTIAL])
    $out[$t] = [Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob, $c.CredentialBlobSize / 2)
    [W.Cred]::CredFree($p)
  }
}
$out | ConvertTo-Json -Compress
]=]

local function read_creds(cb)
  local targets, seen = {}, {}
  for _, c in ipairs(servers) do
    local t = c[2].cred
    if t and not seen[t] then
      seen[t] = true
      table.insert(targets, "'" .. t .. "'")
    end
  end
  local script = CREDREAD:format(table.concat(targets, ","))
  -- -EncodedCommand (UTF-16LE в base64): многострочный скрипт через -Command
  -- коверкается кавычками командной строки Windows
  local encoded = vim.base64.encode((script:gsub(".", "%0\0")))
  vim.system(
    { "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded },
    { text = true },
    vim.schedule_wrap(function(r)
      local ok, creds = pcall(vim.json.decode, r.stdout or "")
      if r.code ~= 0 or not ok or type(creds) ~= "table" then
        vim.notify(
          "sqldbs: не удалось прочитать Credential Manager\n" .. (r.stderr or ""),
          vim.log.levels.WARN
        )
        return
      end
      cb(creds)
    end)
  )
end

build({})
if vim.fn.has("win32") == 1 then
  read_creds(function(creds)
    build(creds)
    -- молчим, пока работает запасная переменная: иначе уведомление на каждом старте
    local missing, seen = {}, {}
    for _, c in ipairs(servers) do
      local auth = c[2]
      if auth.cred and not seen[auth.cred] and not password(auth, creds) then
        seen[auth.cred] = true
        table.insert(missing, ("cmdkey /generic:%s /user:%s /pass"):format(auth.cred, env(auth.user)))
      end
    end
    if #missing > 0 then
      vim.notify(
        "sqldbs: нет паролей, добавить:\n" .. table.concat(missing, "\n"),
        vim.log.levels.WARN
      )
    end
  end)
end
