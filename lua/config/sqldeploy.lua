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
-- Подключение можно назвать явно: :SqlDeploy! или :SqlDeploy <подключение> [база].
--
-- В sql-буферах: <leader>dd — выложить, <leader>dD — выложить, выбрав подключение.

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

---Выкладывает файл по очереди в каждую базу: маска часто называет несколько
---(0x3000000 -> DataGroup + ICS_UA97), и объект должен появиться во всех.
---Порядок аргументов — как у колбэка sqltarget.pick.
local function run(conn, databases, file, how)
  local codepage, cperr = input_codepage(file)
  if not codepage then
    return notify(
      cperr or "не удалось определить кодировку файла",
      vim.log.levels.ERROR
    )
  end

  local name = vim.fn.fnamemodify(file, ":t")
  local target_name = conn.name .. " / " .. table.concat(databases, ", ")
  notify(("%s -> %s (%s)"):format(name, target_name, how or "?"))

  local args = sql.args({ input = file, codepage = codepage, stderr = true })
  local lines, failed = {}, {}
  local function finish()
    if #lines > 0 then
      sqlwin.show({
        kind = "deploy",
        title = name .. " @ " .. target_name,
        lines = lines,
        ctx = { file = file, conn = conn.name, db = databases[1] },
        filetype = "",
        bottom = true,
        -- курсор остаётся в файле, если деплой прошёл, и переходит в вывод,
        -- если sqlcmd вернул ошибку — её сразу надо читать
        focus = #failed > 0,
      })
    end
    if #failed == 0 then
      notify("готово: " .. name .. " -> " .. target_name)
    else
      notify("не выложилось: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
    end
  end
  local function step(i)
    local database = databases[i]
    if not database then
      return vim.schedule(finish)
    end
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
end

return M
