-- MS SQL для vim-dadbod / vim-dadbod-ui (:DBUI, <leader>D).
--
-- Сами подключения лежат не здесь, а в .env каждого проекта (tpope/vim-dotenv):
--   c:/repo/esql/.env   -> esql_dev, esql_test
--   c:/repo/dgsql/.env  -> dgsql_dev, dgsql_test, crocus_dev, crocus_test
-- dadbod-ui подхватывает из .env все переменные с префиксом DB_UI_
-- (имя подключения = остаток имени переменной в нижнем регистре),
-- см. :help vim-dadbod-ui-connections-env.
--
-- Логины/пароли в .env не хранятся: там только ${SQLCMDUSER} / ${MSSQL_TESTUSER} /
-- ${MSSQL_TESTPASSWORD}, которые vim-dotenv раскрывает из окружения — те же
-- переменные, что используют MCP-серверы mssqlclient-* (~/.claude/mcp-servers/*.cmd).
-- Пароль dev-логина отдельно не указан: sqlcmd сам берёт его из $SQLCMDPASSWORD.

-- :SqlDeploy — выложить текущий .sql файл в базу (sqlcmd, кодировка по байтам файла)
require("config.sqldeploy").setup()

return {
  {
    "kristijanhusak/vim-dadbod-ui",
    optional = true,
    -- dadbod-ui читает .env только если vim-dotenv уже загружен
    dependencies = { "tpope/vim-dotenv" },
  },
}
