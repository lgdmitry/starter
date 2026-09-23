-- Дополнение из базы (vim-dadbod-completion) в обычных .sql файлах репозитория.
--
-- vim-dadbod-completion знает, куда идти, только из b:db (или w:/t:/g:db, $DATABASE_URL).
-- Раньше b:db ставил лишь черновик :SqlQuery, так что в файлах процедур из базы не
-- дополнялось ничего — ни таблицы, ни колонки по алиасу (`from Document d` ... `d.`);
-- то, что всплывало, было словами из буфера. Здесь b:db берётся по тем же правилам,
-- что и у :SqlDeploy (config.sqltarget), но без вопросов: неоднозначно — значит без
-- дополнения из базы, а не окно выбора посреди набора текста.
--
-- Почему на InsertEnter, а не на открытии файла: и правила (список баз, реестр
-- usBases), и первый запрос плагина (список таблиц) синхронные. Платить за них стоит
-- только за файлы, которые правят, а не за каждый открытый ради чтения — и один раз
-- на входе в insert, а не рывком на первой набранной букве.
--
-- Колонок в больших базах (ics_ua97 — 17 тыс.) больше порога плагина (10000), поэтому
-- их он тянет по таблице при первом `алиас.` и асинхронно: на самый первый `d.` меню
-- пустое, колонки появляются со следующей буквой.

local sql = require("config.sqlconn")
local target = require("config.sqltarget")

local M = {}

---Подключение и база для файла по правилам — или nil, если однозначно не выходит.
local function resolve(file)
  local list = sql.connections(file)
  if #list == 0 then
    return nil
  end
  local conn = target.resolve_connection(file, list)
  if not conn then
    return nil
  end
  -- сторож может дать несколько баз (datagroup + ics_ua97) — схема у них общая,
  -- для подсказок хватит первой
  local dbs, how = target.resolve_databases(file, conn, list)
  return dbs[1] and sql.with_database(conn.url, dbs[1]), conn, dbs, how
end

local function attach(buf)
  -- b:db уже есть у черновика :SqlQuery; пробуем один раз на буфер, иначе при
  -- неудаче правила гонялись бы на каждом входе в insert
  if vim.b[buf].db or vim.b[buf].sqlcomplete_tried then
    return
  end
  vim.b[buf].sqlcomplete_tried = true
  local file = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or file == "" then
    return
  end
  local ok, url, conn, dbs, how = pcall(resolve, file)
  if not ok or not url then
    return
  end
  vim.b[buf].db = url
  -- правила уже отработали — пусть статус покажет, куда они привели
  target.remember(buf, conn, dbs, how)
  -- список таблиц — сейчас, а не на первой букве (см. выше)
  pcall(vim.fn["vim_dadbod_completion#fetch"], buf)
end

function M.setup()
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = vim.api.nvim_create_augroup("sqlcomplete", { clear = true }),
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "sql" then
        attach(ev.buf)
      end
    end,
  })
end

return M
