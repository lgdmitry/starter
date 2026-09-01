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

-- Свои команды поверх dadbod (общая часть — config.sqlconn):
--   :SqlDeploy (<leader>dd в sql-буферах) — выложить текущий .sql файл в базу
--   :SqlDef (K), :SqlRows (<leader>dr), :SqlEnum (<leader>de) — посмотреть объект в базе
--   :SqlQuery (<leader>dq), :SqlRun (<leader>dx) — разовый запрос рядом с процедурой
require("config.sqldeploy").setup()
require("config.sqlobject").setup()
require("config.sqlquery").setup()

return {
  {
    "kristijanhusak/vim-dadbod-ui",
    optional = true,
    -- dadbod-ui читает .env только если vim-dotenv уже загружен
    dependencies = { "tpope/vim-dotenv" },
  },
  -- LazyVim вешает K на vim.lsp.buf.hover() в любом буфере, к которому присоединился
  -- хоть какой-нибудь LSP-клиент, и без проверки, умеет ли тот hover. В sql-буферах
  -- такой клиент есть — copilot, а hover он не поддерживает, поэтому K отвечал
  -- "method textDocument/hover is not supported...". Перебить это своим маппингом
  -- нельзя: LazyVim ставит K через Snacks.keymap с debounce 100мс после LspAttach,
  -- то есть всегда последним. Поэтому переопределяем саму запись:
  --   has = "hover" — ставить K только если клиент реально умеет hover;
  --   enabled       — в sql-буферах K всегда наш, :SqlDef (см. config.sqlobject).
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ["*"] = {
          keys = {
            {
              "K",
              function()
                return vim.lsp.buf.hover()
              end,
              desc = "Hover",
              has = "hover",
              enabled = function(buf)
                return vim.bo[buf].filetype ~= "sql"
              end,
            },
          },
        },
      },
    },
  },
}
