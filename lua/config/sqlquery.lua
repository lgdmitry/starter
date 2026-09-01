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
-- В sql-буферах:
--   <leader>dq   — открыть буфер запроса для подключения/базы текущего файла
--   <leader>dx   — выполнить выделенное (в визуальном режиме)
-- В самом буфере запроса <leader>dx работает и в обычном режиме — на весь буфер,
-- а q закрывает окно, как и в окне с ответом (ценой записи макросов: в черновике
-- запроса она нужна реже, чем закрыть его тем же движением, что и ответ).
-- С ! (:SqlQuery!, :SqlRun!) подключение спрашивается.

local sql = require("config.sqlconn")
local sqlobject = require("config.sqlobject")

local M = {}

---До скольких символов sqlcmd режет колонки в выводе (-y/-Y).
M.column_width = 50

local function notify(msg, level)
  sql.notify(msg, level, "SqlQuery")
end

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
  -- b:sqlobject тут же даёт в буфере запроса рабочие K и <leader>dr: они спросят
  -- ту же базу, а не ту, которую вычислили бы по имени безымянного буфера
  vim.b[buf].sqlobject = { file = file, conn = conn.name, db = database, kind = "query-input" }
  vim.b[buf].sqlquery = { file = file, conn = conn.name, db = database }
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = "sql"
  return buf
end

---Куда идти: в буфере запроса — ровно то, к чему он привязан, иначе как у :SqlDeploy.
local function target(bang, cb)
  local ctx = not bang and vim.b.sqlquery or nil
  if ctx then
    local conn = sql.by_name(sql.connections(ctx.file), ctx.conn)
    if conn then
      return cb(conn, ctx.db, ctx.file)
    end
  end
  sqlobject.target(bang, function(conn, dbs, file)
    cb(conn, dbs[1], file)
  end)
end

---:SqlQuery — открыть буфер запроса в вертикальном сплите.
function M.open(opts)
  target(opts.bang, function(conn, database, file)
    local from = vim.api.nvim_get_current_win()
    local buf = query_buffer(conn, database, file)
    local shown = vim.fn.bufwinid(buf)
    if shown ~= -1 then
      vim.api.nvim_set_current_win(shown) -- уже открыт: второе окно на тот же буфер не нужно
    else
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, buf)
      vim.b[buf].sqlquery_from = from -- куда вернуть курсор по q
    end
    if vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      vim.cmd("startinsert")
    end
    notify(("запрос к %s/%s"):format(conn.name, database))
  end)
end

---:SqlRun — выполнить буфер целиком или строки диапазона (в визуальном режиме — выделение).
function M.run(opts)
  if vim.fn.executable("sqlcmd") == 0 then
    return notify("sqlcmd не найден в PATH", vim.log.levels.ERROR)
  end
  local lines = opts.range > 0 and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    or vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    return notify("нечего выполнять", vim.log.levels.WARN)
  end

  target(opts.bang, function(conn, database, file)
    -- sqlcmd читает запрос из файла, а не из -Q: через -Q командная строка приезжает
    -- в ANSI и кириллица в литералах бьётся, а с -f i:65001 файл читается как utf-8
    local input = vim.fn.tempname() .. ".sql"
    vim.fn.writefile(lines, input)
    -- sqlcmd обрезает путь с прямыми слэшами на первом двоеточии (как в :SqlDeploy)
    if vim.fn.has("win32") == 1 then
      input = vim.fs.normalize(input):gsub("/", [[\]])
    end
    local w = tostring(M.column_width)
    local args = { "-b", "-I", "-f", "i:65001", "-w", "8000", "-y", w, "-Y", w, "-i", input }

    notify(("выполняется на %s/%s…"):format(conn.name, database))
    sql.sqlcmd(conn, database, args, function(code, text)
      vim.schedule(function()
        os.remove(input)
        if code ~= 0 then
          notify(("sqlcmd вернул %d (%s/%s)"):format(code, conn.name, database), vim.log.levels.ERROR)
        end
        sqlobject.show(
          ("запрос @ %s/%s"):format(conn.name, database),
          text,
          { file = file, conn = conn.name, db = database, kind = "query" },
          ""
        )
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("sqlquery_keys", { clear = true }),
    pattern = "sql",
    desc = "Клавиши :SqlQuery/:SqlRun в sql-буферах",
    callback = function(ev)
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = ev.buf, desc = desc })
      end
      map("n", "<leader>dq", "<cmd>SqlQuery<cr>", "Буфер запроса к базе файла")
      map("n", "<leader>dQ", "<cmd>SqlQuery!<cr>", "Буфер запроса, выбрав подключение")
      -- в файле процедуры на весь буфер вешать нечего: это и есть :SqlDeploy,
      -- поэтому в обычном режиме <leader>dx живёт только в самом буфере запроса
      map("x", "<leader>dx", ":<C-u>'<,'>SqlRun<cr>", "Выполнить выделенный запрос")
      if vim.b[ev.buf].sqlquery then
        map("n", "<leader>dx", "<cmd>SqlRun<cr>", "Выполнить запрос")
        -- окно закрывается, буфер остаётся жить (bufhidden=hide): текст запроса
        -- переживёт закрытие и вернётся тем же <leader>dq
        map("n", "q", function()
          local from = vim.b[ev.buf].sqlquery_from
          vim.cmd("close")
          if from and vim.api.nvim_win_is_valid(from) then
            vim.api.nvim_set_current_win(from)
          end
        end, "Закрыть буфер запроса")
      end
    end,
  })

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
