-- Подключения к MS SQL — для dadbod-ui (:DBUI читает g:dbs сам) и своего слоя
-- (config.sqlconn.connections).
--
-- Раньше они лежали в .env каждого проекта (c:/repo/dgsql, c:/repo/esql), и видно их
-- было только из папки проекта: vim-dotenv ищет .env от текущего каталога. Здесь — одно
-- место на все проекты, под git.
--
-- По одному подключению на сервер: базу для файла дают правила (config.sqltarget), в
-- буфере запроса её выбирают через :SqlConn, так что база в URL — лишь запасная, когда
-- правила ничего не дали. Несколько подключений на один хост, отличающихся только
-- базой, слою вредили: сервер для файла ищется по хосту, и находилось первое по
-- алфавиту (dgsql_datagroup вместо dgsql_dev). Цена — в дереве :DBUI у подключения
-- видна только база из URL: dadbod-ui для sqlserver других баз не показывает.
--
-- Паролей здесь нет — только ${VAR} из окружения, те же переменные, что у MCP-серверов
-- mssqlclient-* (~/.claude/mcp-servers/*.cmd):
--   dev  — $SQLCMDUSER, пароль sqlcmd сам берёт из $SQLCMDPASSWORD; esql — доменная
--          учётка (-E);
--   test — $MSSQL_TESTUSER / $MSSQL_TESTPASSWORD, только чтение.
-- Хосты тоже из окружения ($MSSQL_DEVSERVER_* / $MSSQL_TESTSERVER_*, общие с MCP): сервер
-- переедет — поменять одну переменную, а не этот файл и каждый .cmd.
-- Раскрываем при старте, как делал vim-dotenv: dadbod сам ${VAR} внутри URL не понимает.

local function env(url)
  return (url:gsub("%${([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end))
end

local TRUST = "?trustServerCertificate=true"
local DEV = "${SQLCMDUSER}@"
local TEST = "${MSSQL_TESTUSER}:${MSSQL_TESTPASSWORD}@"

-- имена в нижнем регистре — как раньше из DB_UI_*: по ним ищут подключение правила
-- (…_dev) и аргументы команд
vim.g.dbs = vim.tbl_map(function(c)
  return { name = c[1], url = env("sqlserver://" .. c[2] .. TRUST) }
end, {
  { "dgsql_dev", DEV .. "${MSSQL_DEVSERVER_DATAGROUP}/datagroup" },
  { "dgsql_test", TEST .. "${MSSQL_TESTSERVER_DATAGROUP}/datagroup" },
  { "crocus_dev", DEV .. "${MSSQL_DEVSERVER_CROCUS}/Crocus" },
  { "crocus_test", TEST .. "${MSSQL_TESTSERVER_CROCUS}/Crocus" },
  { "esql_dev", "${MSSQL_DEVSERVER_EXPRESS}/ics_ua97" },
  { "esql_test", TEST .. "${MSSQL_TESTSERVER_EXPRESS}/ics_ua97" },
})
