-- :SqlQuery / :SqlRun — черновик запроса рядом с процедурой и его выполнение.
--
-- Дырка, которую они закрывают: :SqlDeploy выкладывает файл целиком, :SqlDef/:SqlRows
-- показывают объект — а разового «а что вернёт вот этот select» не было, и приходилось
-- идти в :DBUI и там выбирать подключение руками.
--
-- Зачем не dadbod (:DB, <leader>S из vim-dadbod-ui): он зовёт sqlcmd вообще без -f
-- (autoload/db/adapter/sqlserver.vim), а без флага sqlcmd отдаёт вывод в ANSI-кодировке
-- консоли — то есть кириллица приезжает битой не в запросе, а в самом результате, и
-- поправить это в dadbod негде: он пишет байты вывода в файл и открывает его как буфер.
-- Здесь и вход (-f i:65001), и выход (sqlconn.output_to_utf8) под нашим контролем,
-- а подключение с базой берутся те же, что у :SqlDeploy для этого файла.
--
-- Клавиши глобальные (группа <leader>d, см. plugins/which-key.lua):
--   <leader>dq   — открыть буфер запроса для подключения/базы текущего файла
--   <leader>dQ   — то же, но подключение спрашивается
--   <leader>dx   — выполнить выделенное (в визуальном режиме)
-- В самом буфере запроса <leader>dx работает и в обычном режиме — на весь буфер,
-- а q закрывает окно, как и в окне с ответом (ценой записи макросов: в черновике
-- запроса она нужна реже, чем закрыть его тем же движением, что и ответ).
-- С ! (:SqlQuery!, :SqlRun!) подключение спрашивается.

local sql = require("config.sqlconn")
local target = require("config.sqltarget")
local sqlwin = require("config.sqlwin")

local M = {}

---До скольких символов sqlcmd режет колонки в выводе (-y/-Y).
M.column_width = 50

local notify = sql.notifier("SqlQuery")

---URL подключения с подменённой базой — для b:db, чтобы в буфере запроса работало
---дополнение имён таблиц и колонок (vim-dadbod-completion смотрит именно на b:db).
local function with_database(url, database)
  local base, params = url:match("^([^?]*)(.*)$")
  local authority = base:match("^(.-://[^/]*)")
  if not authority then
    return url
  end
  return authority .. "/" .. database .. params
end

---Есть ли ради чего делить окно: хоть один залистованный буфер с файлом. На пустом
---старте (дашборд, [No Name]) вертикальный сплит только режет экран пополам ради
---пустоты — там черновик занимает текущее окно.
local function has_open_files()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) ~= "" then
      return true
    end
  end
  return false
end

---Буфер запроса для этой пары подключение/база: один на пару, а не по новому на
---каждый вызов — иначе за день их набирается десяток.
local function query_buffer(conn, database, file)
  local name = ("sqlquery://%s/%s"):format(conn.name, database)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf):find(name, 1, true) then
      return buf
    end
  end
  -- Незалистованный: в bufferline черновику делать нечего, а закрыв окно, его и не
  -- ищут в списке буферов — возвращаются тем же <leader>dq, содержимое переживает.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile" -- запрос никуда не сохраняется, sqlcmd получает его через временный файл
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].db = with_database(conn.url, database)
  -- b:sqlctx — та же переменная, что у окон с ответом (config.sqlwin): благодаря ей
  -- K и <leader>dr в черновике спрашивают ту же базу, а не ту, которую вычислили бы
  -- по имени безымянного буфера
  vim.b[buf].sqlctx = { file = file, conn = conn.name, db = database }
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = "sql"
  -- Эти две — только здесь: «выполнить весь буфер» в файле процедуры означало бы
  -- :SqlDeploy, а q в обычном файле занят под что угодно другое.
  vim.keymap.set("n", "<leader>dx", "<cmd>SqlRun<cr>", { buffer = buf, desc = "Выполнить запрос" })
  -- окно закрывается, буфер остаётся жить (bufhidden=hide): текст запроса переживёт
  -- закрытие и вернётся тем же <leader>dq
  vim.keymap.set("n", "q", function()
    -- окно может быть единственным (открылись без сплита) — :close там E444,
    -- поэтому просто уходим на предыдущий буфер, а если его нет — в пустой
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      if not pcall(vim.cmd, "buffer #") then
        vim.cmd("enew")
      end
      return
    end
    local from = vim.b[buf].sqlquery_from
    vim.cmd("close")
    if from and vim.api.nvim_win_is_valid(from) then
      vim.api.nvim_set_current_win(from)
    end
  end, { buffer = buf, desc = "Закрыть буфер запроса" })
  return buf
end

---Куда идти: в черновике и в окне ответа — ровно то, к чему они привязаны, иначе как
---у :SqlDeploy.
local function pick(bang, cb)
  target.pick({
    ctx = vim.b.sqlctx,
    file = vim.api.nvim_buf_get_name(0),
    bang = bang,
    prompt = "Запрос к:",
    title = "SqlQuery",
  }, function(conn, dbs, file)
    cb(conn, dbs[1], file)
  end)
end

---:SqlQuery — открыть буфер запроса в вертикальном сплите.
function M.open(opts)
  pick(opts.bang, function(conn, database, file)
    local from = vim.api.nvim_get_current_win()
    local buf = query_buffer(conn, database, file)
    local shown = vim.fn.bufwinid(buf)
    if shown ~= -1 then
      vim.api.nvim_set_current_win(shown) -- уже открыт: второе окно на тот же буфер не нужно
    elseif has_open_files() then
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, buf)
      vim.b[buf].sqlquery_from = from -- куда вернуть курсор по q
    else
      vim.api.nvim_win_set_buf(0, buf) -- делить нечего, занимаем текущее окно
      vim.b[buf].sqlquery_from = nil -- возвращаться по q некуда, окно то же самое
    end
    if vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      vim.cmd("startinsert")
    end
    notify(("запрос к %s/%s"):format(conn.name, database))
  end)
end

---:SqlRun — выполнить буфер целиком или строки диапазона (в визуальном режиме — выделение).
function M.run(opts)
  if not sql.ensure("SqlQuery") then
    return
  end
  local lines = opts.range > 0 and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    or vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    return notify("нечего выполнять", vim.log.levels.WARN)
  end

  pick(opts.bang, function(conn, database, file)
    -- sqlcmd читает запрос из файла, а не из -Q: через -Q командная строка приезжает
    -- в ANSI и кириллица в литералах бьётся, а с -f i:65001 файл читается как utf-8
    local input = vim.fn.tempname() .. ".sql"
    vim.fn.writefile(lines, input)
    local args = sql.args({ input = input, width = 8000, trunc = M.column_width })

    notify(("выполняется на %s/%s…"):format(conn.name, database))
    sql.sqlcmd(conn, database, args, function(code, text)
      vim.schedule(function()
        os.remove(input)
        if code ~= 0 then
          notify(("sqlcmd вернул %d (%s/%s)"):format(code, conn.name, database), vim.log.levels.ERROR)
        end
        sqlwin.show({
          kind = "query",
          title = ("запрос @ %s/%s"):format(conn.name, database),
          text = text,
          ctx = { file = file, conn = conn.name, db = database },
          filetype = "",
          bottom = true,
        })
      end)
    end)
  end)
end

function M.setup()
  -- Глобально: <leader>dq должен открывать черновик запроса откуда угодно, а не
  -- только из уже открытого .sql — иначе до базы приходится идти через :DBUI.
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end
  map("n", "<leader>dq", "<cmd>SqlQuery<cr>", "Буфер запроса к базе файла")
  map("n", "<leader>dQ", "<cmd>SqlQuery!<cr>", "Буфер запроса, выбрав подключение")
  map("x", "<leader>dx", ":<C-u>'<,'>SqlRun<cr>", "Выполнить выделенный запрос")

  vim.api.nvim_create_user_command("SqlQuery", M.open, {
    bang = true,
    desc = "Открыть буфер запроса к базе текущего файла (! — выбрать подключение)",
  })
  vim.api.nvim_create_user_command("SqlRun", M.run, {
    bang = true,
    range = true,
    desc = "Выполнить буфер или выделение через sqlcmd (! — выбрать подключение)",
  })
end

return M
