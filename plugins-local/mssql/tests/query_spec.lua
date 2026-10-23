-- Буферы запроса (mssql.query): временный и постоянный, привязка к подключению,
-- наследование его новым буфером и смена через :SqlConn.

local t = require("helpers")
local F = require("fixtures")
local describe, it, eq = t.describe, t.it, t.eq

local FILE = F.ROOT .. "/ics_ua97/a_PRC.sql"

---ui.select отвечает по очереди из answers (подключения — по имени).
local function answer(answers)
  local i = 0
  vim.ui.select = function(items, opts, cb)
    i = i + 1
    for _, item in ipairs(items) do
      local label = opts.format_item and opts.format_item(item) or item
      if label == answers[i] then
        return cb(item)
      end
    end
    error("нет варианта " .. tostring(answers[i]) .. " в " .. vim.inspect(items))
  end
end

local function setup()
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  vim.cmd("silent edit! " .. vim.fn.fnameescape(FILE))
  local sql = t.fresh()
  local log = t.stub_sql(sql, F.SERVERS, F.CONNS)
  local q = require("mssql.query")
  q.dir = vim.fs.normalize(vim.fn.tempname()) .. "/sqlquery"
  q.setup()
  return q, log
end

local function read(path)
  return vim.fn.readfile(path)
end

describe("строка подключения", function()
  it("туда и обратно, путь старых файлов пропускается", function()
    local q = setup()
    local ctx = { conn = "dgsql_dev", db = "ics_ua97", file = "" }
    eq("-- sqlquery: dgsql_dev/ics_ua97", q.header({ conn = "dgsql_dev", db = "ics_ua97", file = "C:/x.sql" }))
    eq(ctx, q.parse_header(q.header(ctx)))
    eq(ctx, q.parse_header("-- sqlquery: dgsql_dev/ics_ua97 C:/repo/a b/x.sql"))
    eq({ conn = "c", db = "d", file = "" }, q.parse_header("--sqlquery: c/d"))
    eq(nil, q.parse_header("select 1"))
  end)
end)

describe("временный буфер", function()
  it("по правилам файла, один на пару", function()
    local q = setup()
    q.open({ bang = false })
    local buf = vim.api.nvim_get_current_buf()
    eq("scratch", vim.b.sqlquery)
    eq({ file = FILE, conn = "dgsql_dev", db = "ics_ua97" }, vim.b.sqlctx)
    eq("sqlserver://dgsql/ics_ua97", vim.b.db)
    eq("sqlquery://dgsql_dev/ics_ua97", vim.api.nvim_buf_get_name(buf))
    vim.cmd("stopinsert")
    q.open({ bang = false })
    eq(buf, vim.api.nvim_get_current_buf())
  end)
  it(":SqlConn меняет подключение, базу и имя", function()
    local q = setup()
    q.open({ bang = false })
    vim.cmd("stopinsert")
    answer({ "crocus_dev", "ServiceControle" })
    q.switch()
    eq({ file = FILE, conn = "crocus_dev", db = "ServiceControle" }, vim.b.sqlctx)
    eq("sqlserver://crocus/ServiceControle", vim.b.db)
    eq("sqlquery://crocus_dev/ServiceControle", vim.api.nvim_buf_get_name(0))
  end)
  it(
    "новый из переключённого — к его подключению, а не по правилам",
    function()
      local q = setup()
      q.open({ bang = false })
      vim.cmd("stopinsert")
      answer({ "crocus_dev", "Crocus" })
      q.switch()
      local buf = vim.api.nvim_get_current_buf()
      q.open({ bang = false })
      eq(buf, vim.api.nvim_get_current_buf(), "тот же буфер, а не dgsql_dev/ics_ua97")
    end
  )
  it("два буфера на одну пару — имена не сталкиваются", function()
    local q = setup()
    q.open({ bang = false })
    vim.cmd("stopinsert")
    local first = vim.api.nvim_get_current_buf()
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    vim.cmd("wincmd p")
    q.open({ bang = false }) -- снова dgsql_dev/ics_ua97, уже новый
    vim.cmd("stopinsert")
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    t.truthy(vim.api.nvim_get_current_buf() ~= first, "другой буфер")
    eq("sqlquery://crocus_dev/Crocus#2", vim.api.nvim_buf_get_name(0))
  end)
  it("с ! база спрашивается, первой — база по правилам файла", function()
    local q = setup()
    local offered
    answer({ "dgsql_dev", "ics_ua97" })
    local select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if not opts.format_item then
        offered = items
      end
      return select(items, opts, cb)
    end
    q.open({ bang = true })
    vim.cmd("stopinsert")
    eq("ics_ua97", offered[1])
    eq({ file = FILE, conn = "dgsql_dev", db = "ics_ua97" }, vim.b.sqlctx)
  end)
  it(":SqlConn не в .sql и не в буфере запроса ничего не меняет", function()
    local q, log = setup()
    vim.cmd("enew")
    answer({})
    q.switch()
    eq(nil, vim.b.sqlctx)
    eq({ "" }, t.lines(0))
    eq(vim.log.levels.WARN, log.notes[#log.notes].level)
  end)
end)

describe("постоянный запрос", function()
  local AUTO = "dgsql_dev@ics_ua97"

  it(
    "имя — conn@db, строка подключения текущего файла, текущее окно",
    function()
      local q = setup()
      local win = vim.api.nvim_get_current_win()
      q.open_file({ args = "", bang = false })
      vim.cmd("stopinsert")
      local path = q.dir .. "/" .. AUTO .. ".sql"
      eq(path, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq({ "-- sqlquery: dgsql_dev/ics_ua97", "" }, read(path))
      eq(win, vim.api.nvim_get_current_win())
      eq(1, #vim.api.nvim_tabpage_list_wins(0), "без сплита")
      eq("file", vim.b.sqlquery)
      eq({ conn = "dgsql_dev", db = "ics_ua97", file = "" }, vim.b.sqlctx)
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end
  )
  it("второй раз — новый файл, прежний остаётся", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1" })
    vim.cmd("silent write | silent edit " .. vim.fn.fnameescape(FILE))
    q.open_file({ args = "", bang = false })
    eq({ AUTO, AUTO .. "~2" }, q.names())
    eq({ "-- sqlquery: dgsql_dev/ics_ua97", "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    q.open_file({ args = AUTO, bang = false })
    eq("select 1", vim.api.nvim_buf_get_lines(0, 1, 2, false)[1], "по имени — прежний")
  end)
  it("из постоянного — новый файл к той же паре", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    local first = vim.api.nvim_get_current_buf()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    t.truthy(vim.api.nvim_get_current_buf() ~= first, "другой буфер")
    eq(q.dir .. "/" .. AUTO .. "~2.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    eq({ conn = "dgsql_dev", db = "ics_ua97", file = "" }, vim.b.sqlctx)
    q.open_file({ args = "", bang = false })
    eq(q.dir .. "/" .. AUTO .. "~3.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  end)
  it(
    "закрытый открывается заново с новым номером — вкладка справа",
    function()
      local q = setup()
      q.open_file({ args = "", bang = false })
      vim.cmd("stopinsert")
      local old = vim.api.nvim_get_current_buf()
      vim.cmd("silent write | silent edit " .. vim.fn.fnameescape(FILE))
      vim.cmd("bdelete " .. old)
      q.open_file({ args = AUTO, bang = false })
      t.truthy(vim.api.nvim_get_current_buf() > vim.fn.bufnr(FILE), "номер больше, чем у файла")
      eq(0, vim.fn.bufexists(old), "старый стёрт")
      eq({ conn = "dgsql_dev", db = "ics_ua97", file = "" }, vim.b.sqlctx)
    end
  )
  it("q — назад к файлу в том же окне, запрос сохранён и закрыт", function()
    local q = setup()
    local main = vim.api.nvim_get_current_buf()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1" })
    vim.fn.maparg("q", "n", false, true).callback()
    eq(main, vim.api.nvim_get_current_buf())
    eq("select 1", read(q.dir .. "/" .. AUTO .. ".sql")[2])
    eq(0, vim.fn.buflisted(q.dir .. "/" .. AUTO .. ".sql"), "буфер запроса закрыт")
  end)
  it("q — автоматическому имени метка из запроса", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select * from dbo.[Orders] o", "join x on 1 = 1" })
    vim.fn.maparg("q", "n", false, true).callback()
    eq({ AUTO .. "~Orders" }, q.names(), "старого файла нет")
    eq("select * from dbo.[Orders] o", read(q.dir .. "/" .. AUTO .. "~Orders.sql")[2])
    -- второй с той же меткой — с номером, а повторный q имя не меняет
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1 from Orders" })
    vim.fn.maparg("q", "n", false, true).callback()
    eq({ AUTO .. "~Orders", AUTO .. "~Orders~2" }, q.names())
    q.open_file({ args = AUTO .. "~Orders~2", bang = false })
    vim.fn.maparg("q", "n", false, true).callback()
    eq({ AUTO .. "~Orders", AUTO .. "~Orders~2" }, q.names())
  end)
  it("q — названный руками не переименовывается", function()
    local q = setup()
    q.open_file({ args = "report", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select * from Orders" })
    vim.fn.maparg("q", "n", false, true).callback()
    eq({ "report" }, q.names())
  end)
  it("q — пустой стирается вместе с буфером", function()
    local q = setup()
    local main = vim.api.nvim_get_current_buf()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "", "  " })
    vim.fn.maparg("q", "n", false, true).callback()
    eq(main, vim.api.nvim_get_current_buf())
    eq({}, q.names())
    eq(0, vim.fn.bufexists(q.dir .. "/" .. AUTO .. ".sql"))
  end)
  it("метка: комментарий первой строкой, иначе первый объект", function()
    local q = setup()
    local h = "-- sqlquery: a/b"
    eq("остатки_заказов", q.slug({ h, "", "-- остатки заказов", "select * from t" }))
    eq("uspGetOrders", q.slug({ h, "exec dbo.uspGetOrders @id = 1" }))
    eq("tblItems", q.slug({ h, "update [dbo].[tblItems] set a = 1" }))
    eq("Orders", q.slug({ h, "select x into #t from (select 1) s", "join Orders o on 1 = 1" }))
    eq("Real", q.slug({ h, "/* from Fake */ select 'from Str' from Real" }))
    eq(nil, q.slug({ h, "select 1" }))
    eq(nil, q.slug({ h, "" }))
    eq(true, q.is_empty({ h, "", " " }))
    eq(false, q.is_empty({ h, "select 1" }))
  end)
  it(":SqlConn сохраняет метку", function()
    local q = setup()
    vim.fn.mkdir(q.dir, "p")
    vim.fn.writefile({ "-- sqlquery: dgsql_dev/ics_ua97", "select 1" }, q.dir .. "/" .. AUTO .. "~Orders~2.sql")
    q.open_file({ args = AUTO .. "~Orders~2", bang = false })
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    eq(q.dir .. "/crocus_dev@Crocus~Orders.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  end)
  it(":SqlConn переписывает строку и переименовывает файл", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1" })
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    local path = q.dir .. "/crocus_dev@Crocus.sql"
    eq(path, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    eq({ "-- sqlquery: crocus_dev/Crocus", "select 1" }, read(path))
    eq({ "crocus_dev@Crocus" }, q.names(), "старого файла нет")
    eq(0, vim.fn.bufexists(q.dir .. "/" .. AUTO .. ".sql"), "и буфера со старым именем")
    eq("Crocus", vim.b.sqlctx.db)
    eq(false, vim.bo.modified)
  end)
  it(":SqlConn на занятую пару — суффикс ~2", function()
    local q = setup()
    vim.fn.mkdir(q.dir, "p")
    vim.fn.writefile({ "-- sqlquery: crocus_dev/Crocus" }, q.dir .. "/crocus_dev@Crocus.sql")
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    eq(q.dir .. "/crocus_dev@Crocus~2.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  end)
  it("названный руками :SqlConn не переименовывает", function()
    local q = setup()
    q.open_file({ args = "report", bang = false })
    vim.cmd("stopinsert")
    answer({ "crocus_dev", "Crocus" })
    q.switch()
    eq(q.dir .. "/report.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    eq("-- sqlquery: crocus_dev/Crocus", read(q.dir .. "/report.sql")[1])
  end)
  it("из постоянного новый заводится к его подключению", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    answer({ "crocus_dev", "ServiceControle" })
    q.switch()
    vim.cmd("silent edit " .. vim.fn.fnameescape(q.dir .. "/crocus_dev@ServiceControle.sql"))
    q.open_file({ args = "q2", bang = false })
    vim.cmd("stopinsert")
    eq("-- sqlquery: crocus_dev/ServiceControle", read(q.dir .. "/q2.sql")[1])
    q.open({ bang = false })
    eq({ file = "", conn = "crocus_dev", db = "ServiceControle" }, vim.b.sqlctx, "и временный тоже")
  end)
  it("с ! спрашиваются подключение и база", function()
    local q = setup()
    answer({ "crocus_dev", "ServiceControle" })
    q.open_file({ args = "", bang = true })
    vim.cmd("stopinsert")
    eq(q.dir .. "/crocus_dev@ServiceControle.sql", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    eq({ conn = "crocus_dev", db = "ServiceControle", file = "" }, vim.b.sqlctx)
  end)
  it("существующий открывается со своим подключением", function()
    local q = setup()
    vim.fn.mkdir(q.dir, "p")
    vim.fn.writefile({ "-- sqlquery: dgsql_test/datagroup", "select 2" }, q.dir .. "/old.sql")
    q.open_file({ args = "old.sql", bang = false })
    eq({ conn = "dgsql_test", db = "datagroup", file = "" }, vim.b.sqlctx)
    -- в базу не ходим, пока запрос не начали править: из сессии он открывается на
    -- старте, когда пароли ещё не дочитаны (config.sqldbs)
    eq(nil, vim.b.db, "на открытии")
    require("mssql.complete").setup()
    vim.bo.filetype = "sql" -- под -u NONE детектора типов нет
    vim.cmd("doautocmd InsertEnter")
    eq(nil, vim.b.db, "на InsertEnter: в insert попадают и случайно")
    vim.cmd("doautocmd TextChangedI")
    eq("sqlserver://dgsqltest/datagroup", vim.b.db, "на первой правке")
  end)
  it("строку поправили руками — после :w привязка новая", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "-- sqlquery: crocus_dev/Crocus" })
    vim.cmd("silent write")
    eq({ conn = "crocus_dev", db = "Crocus", file = "" }, vim.b.sqlctx)
  end)
  it("клавиши буферные: <leader>dx, <leader>ds, q, <F5>", function()
    local q = setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    for _, lhs in ipairs({ "<leader>dx", "<leader>ds", "q", "<F5>" }) do
      eq(1, vim.fn.maparg(lhs, "n", false, true).buffer, lhs)
    end
    eq(1, vim.fn.maparg("<F5>", "i", false, true).buffer, "<F5> в insert")
  end)
  it("<F5>: в запросе — выполнить, в файле — выложить", function()
    local q = setup()
    require("mssql.deploy").setup()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    for _, mode in ipairs({ "n", "i" }) do
      eq("<Cmd>SqlRun<CR>", vim.fn.maparg("<F5>", mode), "запрос, " .. mode)
    end
    vim.cmd("enew!")
    for _, mode in ipairs({ "n", "i" }) do
      eq("<Cmd>SqlDeploy<CR>", vim.fn.maparg("<F5>", mode), "файл, " .. mode)
    end
  end)
  it(
    "prune: вчерашние автоматические стираются, сегодняшние, названные и открытые — нет",
    function()
      local q = setup()
      vim.fn.mkdir(q.dir, "p")
      local yesterday = os.time() - 86400 * 2
      for _, name in ipairs({ "a@b", "a@b~2", "a@b~3", "a@b~Orders~2", "my", "c@d" }) do
        local path = q.dir .. "/" .. name .. ".sql"
        vim.fn.writefile({ "-- sqlquery: a/b" }, path)
        if name ~= "c@d" then
          vim.uv.fs_utime(path, yesterday, yesterday)
        end
      end
      vim.cmd("silent edit " .. vim.fn.fnameescape(q.dir .. "/a@b~3.sql"))
      q.prune()
      eq({ "a@b~3", "c@d", "my" }, q.names())
    end
  )
end)

describe("файл из окна ответа", function()
  it(
    "постоянный запрос открывается не в окне ответа, а там, откуда в него пришли",
    function()
      local q = setup()
      local src = vim.api.nvim_get_current_win()
      require("mssql.win").show({
        kind = "query",
        title = "r",
        text = "1",
        bottom = true,
        ctx = { file = FILE, conn = "dgsql_dev", db = "ics_ua97" },
      })
      local answer_win = vim.api.nvim_get_current_win()
      q.open_file({ args = "", bang = false })
      eq(src, vim.api.nvim_get_current_win())
      eq(true, vim.b.sqlquery == "file")
      t.truthy(vim.b[vim.api.nvim_win_get_buf(answer_win)].sqlwin, "ответ на месте")
    end
  )
end)

describe(":SqlExport", function()
  it(
    "по умолчанию — рядом с файлом .txt, у буфера без файла — в каталог",
    function()
      local q = setup()
      eq("C:/r/.claude/scratchpad/1/01_data.txt", q.export_path("C:/r/.claude/scratchpad/1/01_data.sql"))
      eq(vim.fs.normalize(vim.uv.cwd()) .. "/export.txt", q.export_path("sqlquery://dgsql_dev/datagroup"))
      eq(vim.fs.normalize(vim.uv.cwd()) .. "/export.txt", q.export_path(""))
    end
  )
  it("хвостовые пустые строки срезаются", function()
    local q = setup()
    eq({ "n s", "- -" }, q.export_text("n s\n- -\n\n"))
    eq({}, q.export_text(""), "пустой ответ")
  end)
  it(
    "пишет ответ в файл с NOCOUNT впереди; при ошибке файл не трогает",
    function()
      local q = setup()
      q.open_file({ args = "", bang = false })
      vim.cmd("stopinsert")
      -- BOM, оставшийся в тексте первой строки, после SET NOCOUNT ломал запрос
      vim.api.nvim_buf_set_lines(
        0,
        0,
        1,
        false,
        { "\239\187\191\239\187\191" .. vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] }
      )
      vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1" })
      local sql = require("mssql.conn")
      local got
      sql.ensure = function()
        return true
      end
      sql.run = function(o, cb)
        got = o
        cb(0, "a\n-\n1\n")
      end
      local out = vim.fs.normalize(vim.fn.tempname()) .. "/d.txt"
      q.export({ range = 0, args = out, bang = false })
      eq("SET NOCOUNT ON;", got.lines[1])
      eq(nil, got.lines[2]:find("\239\187\191", 1, true), "BOM")
      eq({ conn = "dgsql_dev", db = "ics_ua97" }, { conn = got.conn.name, db = got.db })
      eq({ width = 65535, trunc = 8000 }, got.opts)
      eq({ "a", "-", "1" }, read(out))
      sql.run = function(_, cb)
        cb(1, "Msg 102, Level 15")
      end
      vim.cmd("buffer #")
      q.export({ range = 0, args = out, bang = false })
      eq({ "a", "-", "1" }, read(out), "после ошибки")
    end
  )
  it(
    "открывает файл ответа в текущем окне, повторная выгрузка — перечитывает его",
    function()
      local q = setup()
      local sql = require("mssql.conn")
      sql.ensure = function()
        return true
      end
      local answer_text = "a\n1\n"
      sql.run = function(_, cb)
        cb(0, answer_text)
      end
      local out = vim.fs.normalize(vim.fn.tempname()) .. "/d.txt"
      q.export({ range = 0, args = out, bang = false })
      eq(out, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(1, #vim.api.nvim_tabpage_list_wins(0), "без сплита")
      vim.cmd("buffer #")
      answer_text = "a\n2\n"
      q.export({ range = 0, args = out, bang = false })
      eq(out, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(1, #vim.api.nvim_tabpage_list_wins(0), "без сплита")
      eq({ "a", "2" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end
  )
  it(
    "пачка из пикера: каждый .sql — рядом, по правилам файла, без открытия",
    function()
      local q = setup()
      local sql = require("mssql.conn")
      sql.ensure = function()
        return true
      end
      local runs = {}
      sql.run = function(o, cb)
        runs[#runs + 1] = o.conn.name .. "/" .. o.db
        cb(0, "n\n1\n")
      end
      local crocus = F.ROOT .. "/Crocus/d_PRC.sql"
      local wins = #vim.api.nvim_tabpage_list_wins(0)
      q.export_files({ FILE, crocus, F.ROOT .. "/ics_ua97" })
      eq({ "dgsql_dev/ics_ua97", "crocus_dev/Crocus" }, runs)
      eq({ "n", "1" }, read(F.ROOT .. "/ics_ua97/a_PRC.txt"))
      eq({ "n", "1" }, read(F.ROOT .. "/Crocus/d_PRC.txt"))
      eq(wins, #vim.api.nvim_tabpage_list_wins(0), "ничего не открыто")
      os.remove(F.ROOT .. "/ics_ua97/a_PRC.txt")
      os.remove(F.ROOT .. "/Crocus/d_PRC.txt")
    end
  )
end)

describe(":SqlRun по секциям", function()
  local BUF = {
    "-- sqlquery: dgsql_dev/datagroup",
    "select 1",
    "",
    "-- sqlquery: dgsql_test/datagroup",
    "select 2",
    "",
  }

  it(
    "заголовки режут диапазон, начало диапазона берёт заголовок выше",
    function()
      local q = setup()
      local function shape(list)
        return vim.tbl_map(function(s)
          return { s.ctx and s.ctx.conn, s.line, s.lines }
        end, list)
      end
      eq(
        { { "dgsql_dev", 1, { "select 1", "" } }, { "dgsql_test", 4, { "select 2", "" } } },
        shape(q.sections(BUF, 1, 6))
      )
      eq(
        { { "dgsql_test", 4, { "select 2" } } },
        shape(q.sections(BUF, 5, 5)),
        "середина второй секции"
      )
      eq(
        { { "dgsql_test", 4, { "select 2" } } },
        shape(q.sections(BUF, 3, 5)),
        "пустой хвост первой выкинут"
      )
      eq(
        { { nil, 0, { "select 0" } }, { "dgsql_dev", 2, { "select 1" } } },
        shape(q.sections({ "select 0", "-- sqlquery: dgsql_dev/datagroup", "select 1" }, 1, 3)),
        "текст до первого заголовка"
      )
    end
  )

  local function stub_run(q)
    local sql = require("mssql.conn")
    sql.ensure = function()
      return true
    end
    local runs, shown = {}, nil
    sql.run = function(o, cb)
      runs[#runs + 1] = { o.conn.name .. "/" .. o.db, o.lines }
      cb(0, "n\n" .. #runs .. "\n\n")
    end
    require("mssql.win").show = function(o)
      shown = o
    end
    return runs, function()
      return shown
    end
  end

  it(
    "каждая секция — на своём подключении, ответы одним окном",
    function()
      local q = setup()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, BUF)
      local runs, shown = stub_run(q)
      q.run({ range = 0, bang = false })
      eq({ { "dgsql_dev/datagroup", { "select 1", "" } }, { "dgsql_test/datagroup", { "select 2", "" } } }, runs)
      eq("-- sqlquery: dgsql_dev/datagroup\nn\n1\n\n-- sqlquery: dgsql_test/datagroup\nn\n2\n", shown().text)
      eq({ conn = "dgsql_dev", db = "datagroup" }, { conn = shown().ctx.conn, db = shown().ctx.db })
      vim.cmd("silent edit!")
    end
  )

  it(
    "неизвестное подключение — не выполняется ничего; с ! заголовки не в счёт",
    function()
      local q = setup()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, BUF)
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "-- sqlquery: nope/datagroup" })
      local runs = stub_run(q)
      q.run({ range = 0, bang = false })
      eq({}, runs)
      answer({ "crocus_dev", "Crocus" })
      q.run({ range = 0, bang = true })
      eq(1, #runs)
      eq("crocus_dev/Crocus", runs[1][1])
      vim.cmd("silent edit!")
    end
  )

  it(
    "файл без заголовков ниже первой строки — как раньше, одним запросом",
    function()
      local q = setup()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 1", "select 2" })
      local runs = stub_run(q)
      q.run({ range = 0, bang = false })
      eq({ { "dgsql_dev/ics_ua97", { "select 1", "select 2" } } }, runs)
      vim.cmd("silent edit!")
    end
  )
end)

describe(":SqlConn в обычном файле", function()
  it("записывает цель первой строкой, повторно — заменяет", function()
    local q = setup()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "\239\187\191select 1" })
    vim.b.sqltarget = { conn = "dgsql_dev", host = "dgsql", dbs = { "ics_ua97" } }
    answer({ "crocus_dev", "ServiceControle" })
    q.switch()
    eq({ "-- sqlquery: crocus_dev/ServiceControle", "select 1" }, t.lines(0), "BOM снят")
    eq(nil, vim.b.sqltarget, "статус забыл прежнюю цель")
    answer({ "dgsql_dev", "datagroup" })
    q.switch()
    eq({ "-- sqlquery: dgsql_dev/datagroup", "select 1" }, t.lines(0))
    eq(nil, vim.b.sqlquery, "буфером запроса не стал")
    vim.cmd("silent edit!")
  end)
end)
