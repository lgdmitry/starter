-- :SqlDeploy — выложить текущий .sql файл в базу через sqlcmd.
--
-- Зачем отдельная команда, а не dadbod: dadbod вызывает sqlcmd без -f
-- (autoload/db/adapter/sqlserver.vim), а sqlcmd без этого флага читает файл в
-- ANSI-кодировке консоли — кириллица в теле объекта приезжает в базу битой.
-- Здесь sqlcmd явно получает -f i:65001, а вдобавок -b/-r (ненулевой код
-- возврата при ошибке), выбор сервера и баз — в :DB этого нет.
--
-- Куда выкладывать — по правилам репозитория, см. config.sqlconn.
--
-- Подключение можно назвать явно: :SqlDeploy! или :SqlDeploy <подключение> [база].
--
-- В sql-буферах: <leader>dd — выложить, <leader>dD — выложить, выбрав подключение.

local sql = require("config.sqlconn")

local M = {}

local function notify(msg, level)
  sql.notify(msg, level, "SqlDeploy")
end

---Кодировка входного файла для sqlcmd: файлы в репозиториях — utf-8,
---остаётся распознать по BOM utf-16, который sqlcmd читает сам.
---@return integer|false|nil cp номер кодовой страницы для `-f i:<cp>`;
---false — если входную кодировку задавать не нужно (utf-16 с BOM); nil — не поддерживается
---@return string? errmsg
local function input_codepage(path)
  local f, ferr = io.open(path, "rb")
  if not f then
    return nil, ferr
  end
  local bytes = f:read(4) or ""
  f:close()
  local b1, b2, b3, b4 = bytes:byte(1, 4)
  -- UTF-32 проверяем первым: первые два байта UTF-32LE BOM совпадают с UTF-16LE BOM
  if
    (b1 == 0xFF and b2 == 0xFE and b3 == 0x00 and b4 == 0x00)
    or (b1 == 0x00 and b2 == 0x00 and b3 == 0xFE and b4 == 0xFF)
  then
    return nil, "UTF-32 sqlcmd не читает — перекодируйте файл в utf-8 или utf-16"
  end
  if (b1 == 0xFE and b2 == 0xFF) or (b1 == 0xFF and b2 == 0xFE) then
    return false -- utf-16 с BOM: sqlcmd распознаёт сам
  end
  return 65001
end

---Вывод sqlcmd в нижнем сплите. Курсор остаётся в файле, если деплой прошёл,
---и переходит в вывод, если sqlcmd вернул ошибку — её сразу надо читать.
local function show_output(title, lines, ok)
  local from = vim.api.nvim_get_current_win()
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "sqldeploy://" .. title)
  vim.api.nvim_win_set_height(0, math.min(20, math.max(5, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Закрыть вывод sqlcmd" })
  if ok and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
end

---Выкладывает файл по очереди в каждую базу: маска часто называет несколько
---(0x3000000 -> DataGroup + ICS_UA97), и объект должен появиться во всех.
local function run(file, conn, databases, how)
  local cp, cperr = input_codepage(file)
  if cp == nil then
    return notify(
      cperr or "не удалось определить кодировку файла",
      vim.log.levels.ERROR
    )
  end
  -- sqlcmd обрезает путь с прямыми слэшами на первом двоеточии ("file C: Access is denied")
  local input = vim.fs.normalize(file)
  if vim.fn.has("win32") == 1 then
    input = input:gsub("/", [[\]])
  end

  local name = vim.fn.fnamemodify(file, ":t")
  local target = conn.name .. " / " .. table.concat(databases, ", ")
  notify(("%s -> %s (%s)"):format(name, target, how))

  local lines, failed = {}, {}
  local function finish()
    if #lines > 0 then
      show_output(name .. " @ " .. target, lines, #failed == 0)
    end
    if #failed == 0 then
      notify("готово: " .. name .. " -> " .. target)
    else
      notify("не выложилось: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
    end
  end
  local function step(i)
    local database = databases[i]
    if not database then
      return vim.schedule(finish)
    end
    -- Форма именно i:<cp>: от неё sqlcmd пишет вывод в utf-8, а от голого -f <cp> —
    -- в ANSI-кодировке консоли. Добавлять o:65001 нельзя: вместе с -r эта пара
    -- переключает весь вывод обратно в ANSI (sqlcmd 15.0.4298.1).
    local args = { "-b", "-I", "-r", "-f", cp and ("i:" .. cp) or "o:65001", "-i", input }
    sql.sqlcmd(conn, database, args, function(code, text)
      if #databases > 1 then
        lines[#lines + 1] = ("===== %s / %s ====="):format(conn.name, database)
      end
      vim.list_extend(lines, vim.split(text, "\n", { trimempty = true }))
      if code ~= 0 then
        failed[#failed + 1] = database .. " (код " .. code .. ")"
      end
      vim.schedule(function()
        step(i + 1)
      end)
    end)
  end
  step(1)
end

---@param opts table аргументы команды: [1] — имя подключения, [2] — база;
---с ! подключение всегда спрашивается, без ! выбирается само, когда это однозначно
function M.deploy(opts)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    return notify("нет файла в буфере", vim.log.levels.ERROR)
  end
  if vim.bo.modified then
    return notify(
      "буфер не сохранён: sqlcmd читает файл с диска, сначала :w",
      vim.log.levels.ERROR
    )
  end
  if vim.fn.executable("sqlcmd") == 0 then
    return notify("sqlcmd не найден в PATH", vim.log.levels.ERROR)
  end

  local list = sql.connections(file)
  if #list == 0 then
    return notify("не найдено подключений DB_UI_* в .env проекта", vim.log.levels.ERROR)
  end

  local wanted, override_db = opts.fargs[1], opts.fargs[2]
  local function go(conn)
    if not conn then
      return notify("отменено")
    end
    local databases, how = sql.resolve_databases(file, conn, list, override_db)
    if #databases == 0 then
      return notify(
        "не определена база: добавьте её в URL или вызовите :SqlDeploy "
          .. conn.name
          .. " <база>",
        vim.log.levels.ERROR
      )
    end
    run(file, conn, databases, how)
  end

  if wanted then
    local conn = sql.by_name(list, wanted)
    return conn and go(conn) or notify("нет подключения " .. wanted, vim.log.levels.ERROR)
  end
  if not opts.bang then
    local auto = sql.resolve_connection(file, list)
    if auto then
      return go(auto)
    end
  end
  sql.select(list, "Выложить " .. vim.fn.fnamemodify(file, ":t") .. " в:", go)
end

function M.setup()
  -- Клавиши буферные: <leader>d у LazyVim — группа debug, в sql-файлах она свободна
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("sqldeploy_keys", { clear = true }),
    pattern = "sql",
    desc = "Клавиши :SqlDeploy в sql-буферах",
    callback = function(ev)
      vim.keymap.set("n", "<leader>dd", "<cmd>SqlDeploy<cr>", {
        buffer = ev.buf,
        desc = "Выложить .sql через sqlcmd",
      })
      vim.keymap.set("n", "<leader>dD", "<cmd>SqlDeploy!<cr>", {
        buffer = ev.buf,
        desc = "Выложить .sql, выбрав подключение",
      })
    end,
  })

  vim.api.nvim_create_user_command("SqlDeploy", M.deploy, {
    nargs = "*",
    bang = true,
    desc = "Выложить текущий .sql файл через sqlcmd (! — выбрать подключение вручную)",
    complete = function(lead)
      local names = vim.tbl_map(function(c)
        return c.name
      end, sql.connections(vim.api.nvim_buf_get_name(0)))
      return vim.tbl_filter(function(n)
        return n:find(lead, 1, true) == 1
      end, names)
    end,
  })
end

return M
