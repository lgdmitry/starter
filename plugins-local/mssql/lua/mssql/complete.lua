-- Дополнение из базы (vim-dadbod-completion) в обычных .sql файлах репозитория.
--
-- vim-dadbod-completion знает, куда идти, только из b:db (или w:/t:/g:db, $DATABASE_URL).
-- Раньше b:db ставил лишь черновик :SqlQuery, так что в файлах процедур из базы не
-- дополнялось ничего — ни таблицы, ни колонки по алиасу (`from Document d` ... `d.`);
-- то, что всплывало, было словами из буфера. Здесь b:db берётся по тем же правилам,
-- что и у :SqlDeploy (mssql.target), но без вопросов: неоднозначно — значит без
-- дополнения из базы, а не окно выбора посреди набора текста.
--
-- Почему на первой правке в insert (TextChangedI), а не на открытии файла: и правила
-- (список баз, реестр usBases), и первый запрос плагина (список таблиц) синхронные,
-- а файлы из сессии открываются на старте, когда пароли ещё не дочитаны
-- (config.sqldbs). Платить за них стоит только за файлы, которые правят. Раньше было
-- на InsertEnter — без рывка на первой букве, но в insert попадают и случайно, а это
-- поход на сервер (и вопрос пароля) без нужды; рывок один раз на буфер дешевле.
--
-- Колонок в больших базах (ics_ua97 — 17 тыс.) больше порога плагина (10000), поэтому
-- их он тянет по таблице при первом `алиас.` и асинхронно: на самый первый `d.` меню
-- пустое, колонки появляются со следующей буквой.

local sql = require("mssql.conn")
local target = require("mssql.target")

local M = {}

local function attach(buf)
  -- b:db уже есть у черновика :SqlQuery; пробуем один раз на буфер, иначе при
  -- неудаче правила гонялись бы на каждой набранной букве
  if vim.b[buf].db or vim.b[buf].sqlcomplete_tried then
    return
  end
  vim.b[buf].sqlcomplete_tried = true
  local file = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or file == "" then
    return
  end
  -- постоянный запрос со строкой подключения (mssql.query): база записана в нём самом
  local ctx = vim.b[buf].sqlquery == "file" and vim.b[buf].sqlctx
  if ctx and ctx.conn then
    local ok, conn = pcall(function()
      return sql.by_name(sql.connections(ctx.file), ctx.conn)
    end)
    if ok and conn then
      vim.b[buf].db = sql.with_database(conn.url, ctx.db)
      pcall(vim.fn["vim_dadbod_completion#fetch"], buf)
    end
    return
  end
  local ok, t = pcall(target.resolve, file)
  if not ok or not t then
    return
  end
  -- сторож может дать несколько баз (datagroup + ics_ua97) — схема у них общая,
  -- для подсказок хватит первой
  vim.b[buf].db = sql.with_database(t.conn.url, t.dbs[1])
  -- правила уже отработали — пусть статус покажет, куда они привели
  target.remember(buf, t.conn, t.dbs, t.how)
  -- список таблиц — сразу, не дожидаясь, пока плагин попросит его сам
  pcall(vim.fn["vim_dadbod_completion#fetch"], buf)
end

function M.setup()
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = vim.api.nvim_create_augroup("sqlcomplete", { clear = true }),
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "sql" then
        attach(ev.buf)
      end
    end,
  })
end

return M
