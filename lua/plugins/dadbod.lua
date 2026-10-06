-- MS SQL для vim-dadbod / vim-dadbod-ui (:DBUI, <leader>D).
--
-- Сами подключения — g:dbs в config.sqldbs (по одному на сервер: dgsql, crocus, esql ×
-- dev/test), логины и пароли там раскрываются из окружения. DB_UI_* из .env проекта
-- dadbod-ui и слой тоже подхватывают (tpope/vim-dotenv), но одноимённые из g:dbs главнее.
require("config.sqldbs")

-- Свои команды поверх dadbod — локальный плагин mssql (lua/plugins/mssql.lua). Общее
-- лежит в трёх модулях: mssql.conn (как звать sqlcmd), mssql.target (куда идти для этого
-- файла), mssql.win (окна с ответом):
--   :SqlDeploy (<leader>dd), :SqlDeployFiles — выложить .sql файл(ы) в базу
--   :SqlDef (K, gK), :SqlRows (<leader>dr), :SqlEnum (<leader>de) — объект в базе
--   :SqlUsages (<leader>du) — где в базах используется имя; :SqlFile (gf) — файл объекта
--   :SqlQuery (<leader>dq), :SqlRun (<leader>dx) — разовый запрос рядом с процедурой
--   :SqlExport (<leader>do) — выполнить файл, ответ в <имя>.json рядом (данные proc-test)
--   :SqlQueryFile (<leader>dt) — постоянный запрос; :SqlConn (<leader>ds) — сменить
--                                подключение буфера запроса
--   :SqlWhere (<leader>di), :SqlCacheClear — куда пойдут команды, забыть кэши правил
--   :SqlCancel (<leader>dc) — прервать выполняющийся sqlcmd (запросы асинхронные)
--   :SqlFormat (<leader>df) — форматировать диапазон по стандарту dgsql/esql (sqlkit)
--   :SqlLint — диагностика по тому же стандарту на изменённых строках (! — весь файл)
--   mssql.complete — b:db для дополнения из базы в обычных .sql файлах
-- Спеки — plugins-local/{mssql,sqlkit}/tests/, запуск описан в tests/run.lua каждого.

-- sqlfluff из extra lang.sql убран целиком. Форматтером (conform, автоформат при
-- сохранении) он переписывал весь файл, а стандарт dgsql/esql применяется только к
-- новым и изменённым строкам — для этого есть :SqlFormat (sqlkit.format). Линтером
-- с --dialect=ansi он на T-SQL давал сплошной шум, а правил стандарта всё равно не знает.
local sql_ft = { "sql", "mysql", "plsql" }
local function without_sqlfluff(list)
  return vim.tbl_filter(function(name)
    return name ~= "sqlfluff"
  end, list or {})
end

return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = without_sqlfluff(opts.ensure_installed)
    end,
  },
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = function(_, opts)
      for _, ft in ipairs(sql_ft) do
        opts.linters_by_ft[ft] = without_sqlfluff(opts.linters_by_ft[ft])
      end
    end,
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = function(_, opts)
      opts.formatters.sqlfluff = nil
      for _, ft in ipairs(sql_ft) do
        opts.formatters_by_ft[ft] = without_sqlfluff(opts.formatters_by_ft[ft])
      end
    end,
  },
  {
    "kristijanhusak/vim-dadbod-ui",
    optional = true,
    -- dadbod-ui читает .env только если vim-dotenv уже загружен
    dependencies = { "tpope/vim-dotenv" },
  },
  -- Подключение, сервер и база в строке статуса — чтобы до <leader>dd было видно, куда
  -- уедет файл. Что именно и когда оно известно — см. mssql.target.statusline.
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("mssql.target").statusline()
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
  --   enabled       — в sql-буферах K всегда наш, :SqlDef (см. mssql.object).
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
