-- :SqlDeploy — выложить текущий .sql файл в базу через sqlcmd.
--
-- Зачем отдельная команда, а не dadbod: dadbod вызывает sqlcmd без -f
-- (autoload/db/adapter/sqlserver.vim), а sqlcmd без этого флага читает файл в
-- ANSI-кодировке консоли — кириллица в теле объекта приезжает в базу битой.
-- Здесь sqlcmd явно получает -f i:65001, а вдобавок -b/-r (ненулевой код
-- возврата при ошибке), выбор сервера и баз — в :DB этого нет.
--
-- Куда выкладывать — по правилам репозитория, см. config.sqltarget.
--
-- Несохранённый буфер сохраняется сам: sqlcmd читает файл с диска, и без этого
-- выложилась бы предыдущая версия — молча и незаметно.
--
-- Подключение можно назвать явно: :SqlDeploy! или :SqlDeploy <подключение> [база].
--
-- В sql-буферах: <leader>dd — выложить, <leader>dD — выложить, выбрав подключение,
-- <leader>dc — прервать выкладку (:SqlCancel, см. config.sqlconn).
--
-- Пачкой: :SqlDeployFiles <файлы> и то же <leader>dd по выделенным (Tab) записям в
-- snacks-пикере и explorer (действие заведено в lua/plugins/snacks.lua).

local sql = require("config.sqlconn")
local target = require("config.sqltarget")
local sqlwin = require("config.sqlwin")

local M = {}

local notify = sql.notifier("SqlDeploy")

---Кодировка входного файла для sqlcmd: файлы в репозиториях — utf-8,
---остаётся распознать по BOM utf-16, который sqlcmd читает сам.
---@return string? codepage значение для -f; nil — кодировка не поддерживается
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
    -- utf-16 с BOM: вход sqlcmd распознаёт сам, задать остаётся только кодировку вывода
    return "o:65001"
  end
  return "i:65001"
end

---Имена подключений пачки без повторов — для заголовка окна с ответом.
local function conn_names(jobs)
  local seen, names = {}, {}
  for _, job in ipairs(jobs) do
    if not seen[job.conn.name] then
      seen[job.conn.name] = true
      names[#names + 1] = job.conn.name
    end
  end
  return names
end

---Выкладывает по очереди: каждый файл — в каждую свою базу. Баз обычно несколько
---(маска часто называет их пачкой: 0x3000000 -> DataGroup + ICS_UA97), и объект
---должен появиться во всех; файлов больше одного, когда выкладывают выделенное в
---пикере (см. M.deploy_files).
---@param jobs { conn: table, databases: string[], file: string, how: string? }[]
local function run_jobs(jobs)
  local steps = {}
  for _, job in ipairs(jobs) do
    local codepage, cperr = input_codepage(job.file)
    if not codepage then
      return notify(
        vim.fn.fnamemodify(job.file, ":t")
          .. ": "
          .. (cperr or "не удалось определить кодировку файла"),
        vim.log.levels.ERROR
      )
    end
    for _, database in ipairs(job.databases) do
      steps[#steps + 1] = { conn = job.conn, database = database, file = job.file, codepage = codepage }
    end
  end
  if #steps == 0 then
    return
  end

  local single = #jobs == 1
  local what = single and vim.fn.fnamemodify(jobs[1].file, ":t") or ("файлов: " .. #jobs)
  -- для пачки в заголовке только сервер(ы): базы у каждого файла свои, перечислять
  -- их все — строка, которую никто не прочитает
  local target_name = single and (jobs[1].conn.name .. " / " .. table.concat(jobs[1].databases, ", "))
    or table.concat(conn_names(jobs), ", ")
  -- не разовое уведомление, а живущее до конца выкладки: sqlcmd на большом файле
  -- думает долго, а на нескольких базах ещё и по разу на каждую — без крутилки
  -- между «выкладываю» и «готово» непонятно, идёт что-то или уже нет
  local done, step_msg = sql.progress(
    single and ("%s -> %s (%s, <leader>dc — отменить)"):format(what, target_name, jobs[1].how or "?")
      or ("выкладываю %s (<leader>dc — отменить)"):format(what),
    "SqlDeploy"
  )

  local lines, failed = {}, {}
  local cancelled = false
  local function finish()
    done()
    if #lines > 0 then
      sqlwin.show({
        kind = "deploy",
        title = what .. " @ " .. target_name,
        lines = lines,
        ctx = { file = steps[1].file, conn = steps[1].conn.name, db = steps[1].database },
        filetype = "",
        bottom = true,
        -- курсор остаётся в файле, если деплой прошёл, и переходит в вывод,
        -- если sqlcmd вернул ошибку — её сразу надо читать
        focus = #failed > 0,
      })
    end
    if cancelled then
      -- отдельным сообщением, а не «готово»: часть баз осталась со старой версией
      -- объекта, а та, на которой прервали, — вообще неизвестно с какой
      notify("прервано: " .. what .. " -> " .. target_name, vim.log.levels.WARN)
    elseif #failed == 0 then
      notify("готово: " .. what .. " -> " .. target_name)
    else
      notify("не выложилось: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
    end
  end
  local function step(i)
    local cur = steps[i]
    if not cur then
      return vim.schedule(finish)
    end
    local name = vim.fn.fnamemodify(cur.file, ":t")
    if #steps > 1 then
      step_msg(("%s -> %s/%s (%d из %d)"):format(name, cur.conn.name, cur.database, i, #steps))
    end
    local args = sql.args({ input = cur.file, codepage = cur.codepage, stderr = true })
    local started = sql.sqlcmd(cur.conn, cur.database, args, function(code, text, stopped)
      if #steps > 1 then
        lines[#lines + 1] = ("===== %s @ %s/%s ====="):format(name, cur.conn.name, cur.database)
      end
      vim.list_extend(lines, vim.split(text, "\n", { trimempty = true }))
      if stopped then
        -- отменили — до остальных шагов не идём, показываем то, что успело выложиться
        cancelled = true
        return vim.schedule(finish)
      end
      if code ~= 0 then
        failed[#failed + 1] = (single and "" or name .. " / ") .. cur.database .. " (код " .. code .. ")"
      end
      vim.schedule(function()
        step(i + 1)
      end)
    end)
    if not started then
      done() -- процесс не запустился, колбэка не будет — гасим сами
    end
  end
  step(1)
end

---Один файл — форма колбэка sqltarget.pick.
local function run(conn, databases, file, how)
  run_jobs({ { conn = conn, databases = databases, file = file, how = how } })
end

---@param opts table аргументы команды: [1] — имя подключения, [2] — база;
---с ! подключение всегда спрашивается, без ! выбирается само, когда это однозначно
function M.deploy(opts)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    return notify("нет файла в буфере", vim.log.levels.ERROR)
  end
  -- sqlcmd читает файл с диска, а не буфер: без записи выложилась бы прошлая версия
  if vim.bo.modified then
    local ok, err = pcall(vim.cmd.write)
    if not ok then
      return notify("не сохранился буфер: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if not sql.ensure("SqlDeploy") then
    return
  end

  target.pick({
    file = file,
    bang = opts.bang,
    name = opts.fargs[1],
    database = opts.fargs[2],
    prompt = "Выложить " .. vim.fn.fnamemodify(file, ":t") .. " в:",
    hint = ". Можно указать явно: :SqlDeploy <подключение> <база>",
    title = "SqlDeploy",
  }, run)
end

---Записывает файл, если он открыт в изменённом буфере: sqlcmd читает диск, и без
---этого выложилась бы прошлая версия — молча и незаметно. Буфер ищем перебором, а не
---через bufnr(): тот матчит имя как шаблон и на коротком пути найдёт не тот буфер.
---@return string? errmsg
local function save_if_modified(file)
  local want = vim.fs.normalize(file):lower()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)):lower() == want then
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd.write()
      end)
      if not ok then
        return "не сохранился буфер: " .. tostring(err)
      end
    end
  end
end

---Выложить сразу несколько файлов: :SqlDeployFiles или <leader>dd по выделенным (Tab)
---записям в пикере/explorer (см. lua/plugins/snacks.lua).
---
---Подключение и базы считаются по правилам, без вопросов: спрашивать по разу на файл
---значило бы цепочку vim.ui.select посреди выкладки, а пачку берут почти всегда из
---одного репозитория, где правила однозначны. Если цель не сошлась хоть для одного
---файла — не выкладываем ничего: выложить половину пачки хуже, чем не начать.
---@param files string[]
function M.deploy_files(files)
  if not sql.ensure("SqlDeploy") then
    return
  end
  local jobs, skipped, bad = {}, {}, {}
  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ":t")
    if vim.fn.isdirectory(file) == 1 or name:lower():sub(-4) ~= ".sql" then
      skipped[#skipped + 1] = name
    else
      local err = save_if_modified(file)
      local list = sql.connections(file)
      local conn = (not err and #list > 0) and target.resolve_connection(file, list) or nil
      local dbs, how = {}, nil
      if conn then
        dbs, how = target.resolve_databases(file, conn, list)
      end
      if err then
        bad[#bad + 1] = name .. ": " .. err
      elseif #list == 0 then
        bad[#bad + 1] = name .. ": не найдено подключений DB_UI_* в .env проекта"
      elseif not conn then
        bad[#bad + 1] = name .. ": не определилось подключение"
      elseif #dbs == 0 then
        bad[#bad + 1] = name .. ": не определилась база" .. (how and (" (" .. how .. ")") or "")
      else
        jobs[#jobs + 1] = { conn = conn, databases = dbs, file = file, how = how }
      end
    end
  end
  if #skipped > 0 then
    notify("не .sql, пропущено: " .. table.concat(skipped, ", "), vim.log.levels.WARN)
  end
  if #bad > 0 then
    return notify("ничего не выложено:\n" .. table.concat(bad, "\n"), vim.log.levels.ERROR)
  end
  if #jobs == 0 then
    return notify("нечего выкладывать", vim.log.levels.WARN)
  end
  run_jobs(jobs)
end

function M.setup()
  -- Клавиши глобальные, а не буферные: группа <leader>d у LazyVim отдана debug, но
  -- extra с dap не подключён, и держать SQL-клавиши только в sql-буферах значило, что
  -- в which-key их не видно, пока не откроешь .sql. Промах по буферу не страшен —
  -- :SqlDeploy сам скажет, что файла в буфере нет.
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end
  map("<leader>dd", "<cmd>SqlDeploy<cr>", "Выложить .sql через sqlcmd")
  map("<leader>dD", "<cmd>SqlDeploy!<cr>", "Выложить .sql, выбрав подключение")

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

  vim.api.nvim_create_user_command("SqlDeployFiles", function(opts)
    M.deploy_files(vim.tbl_map(function(f)
      return vim.fn.fnamemodify(f, ":p")
    end, opts.fargs))
  end, {
    nargs = "+",
    complete = "file",
    desc = "Выложить несколько .sql файлов через sqlcmd (цели — по правилам, без вопросов)",
  })
end

return M
