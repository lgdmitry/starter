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

-- Свои команды поверх dadbod. Общее лежит в трёх модулях: config.sqlconn (как звать
-- sqlcmd), config.sqltarget (куда идти для этого файла), config.sqlwin (окна с ответом):
--   :SqlDeploy (<leader>dd), :SqlDeployFiles — выложить .sql файл(ы) в базу
--   :SqlDef (K, gK), :SqlRows (<leader>dr), :SqlEnum (<leader>de) — объект в базе
--   :SqlUsages (<leader>du) — где в базах используется имя; :SqlFile (gf) — файл объекта
--   :SqlQuery (<leader>dq), :SqlRun (<leader>dx) — разовый запрос рядом с процедурой
--   :SqlWhere (<leader>di), :SqlCacheClear — куда пойдут команды, забыть кэши правил
--   :SqlCancel (<leader>dc) — прервать выполняющийся sqlcmd (запросы асинхронные)
--   config.sqlcomplete — b:db для дополнения из базы в обычных .sql файлах
-- Спеки — tests/sql/, запуск описан в tests/run.lua.
require("config.sqlconn").setup()
require("config.sqltarget").setup()
require("config.sqldeploy").setup()
require("config.sqlobject").setup()
require("config.sqlquery").setup()
require("config.sqlcomplete").setup()

return {
  {
    "kristijanhusak/vim-dadbod-ui",
    optional = true,
    -- dadbod-ui читает .env только если vim-dotenv уже загружен
    dependencies = { "tpope/vim-dotenv" },
  },
  -- Подключение, сервер и база в строке статуса — чтобы до <leader>dd было видно, куда
  -- уедет файл. Что именно и когда оно известно — см. sqltarget.statusline.
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("config.sqltarget").statusline()
        end,
        cond = function()
          return vim.b.sqltarget ~= nil or vim.b.sqlctx ~= nil
        end,
        icon = "󰆼",
        color = function()
          return { fg = Snacks.util.color("Special") }
        end,
      })
    end,
  },
  -- LazyVim вешает K на vim.lsp.buf.hover() в любом буфере, к которому присоединился
  -- хоть какой-нибудь LSP-клиент, и без проверки, умеет ли тот hover. В sql-буферах
  -- такой клиент есть — copilot, а hover он не поддерживает, поэтому K отвечал
  -- "method textDocument/hover is not supported...". Перебить это своим маппингом
  -- нельзя: LazyVim ставит K через Snacks.keymap с debounce 100мс после LspAttach,
  -- то есть всегда последним. Поэтому переопределяем саму запись:
  --   has = "hover" — ставить K только если клиент реально умеет hover;
  --   enabled       — в sql-буферах K всегда наш, :SqlDef (см. config.sqlobject).
  -- То же с gK (signature help): в sql-буферах это :SqlDef! — объект на другом сервере.
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
            {
              "gK",
              function()
                return vim.lsp.buf.signature_help()
              end,
              desc = "Signature Help",
              has = "signatureHelp",
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
