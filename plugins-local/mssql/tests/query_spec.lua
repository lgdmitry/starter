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
  it(":SqlConn вне буфера запроса ничего не меняет", function()
    local q, log = setup()
    answer({})
    q.switch()
    eq(nil, vim.b.sqlctx)
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
      eq("sqlserver://dgsql/ics_ua97", vim.b.db)
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
  it("q — назад к файлу в том же окне, запрос сохранён", function()
    local q = setup()
    local main = vim.api.nvim_get_current_buf()
    q.open_file({ args = "", bang = false })
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { "select 1" })
    vim.fn.maparg("q", "n", false, true).callback()
    eq(main, vim.api.nvim_get_current_buf())
    eq("select 1", read(q.dir .. "/" .. AUTO .. ".sql")[2])
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
    eq("sqlserver://dgsqltest/datagroup", vim.b.db)
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
end)

describe(":SqlExport", function()
  it(
    "по умолчанию — рядом с файлом (.json или .txt), у буфера без файла — в каталог",
    function()
      local q = setup()
      eq("C:/r/.claude/scratchpad/1/01_data.json", q.export_path("C:/r/.claude/scratchpad/1/01_data.sql", true))
      eq("C:/r/.claude/scratchpad/1/01_data.txt", q.export_path("C:/r/.claude/scratchpad/1/01_data.sql", false))
      eq(vim.fs.normalize(vim.uv.cwd()) .. "/export.json", q.export_path("sqlquery://dgsql_dev/datagroup", true))
      eq(vim.fs.normalize(vim.uv.cwd()) .. "/export.txt", q.export_path("", false))
    end
  )
  it("JSON ли ответ — по for json вне комментариев и строк", function()
    local q = setup()
    eq(true, q.returns_json({ "select 1 as a", "FOR  JSON PATH" }))
    eq(true, q.returns_json({ "select * from t for", "json auto" }))
    eq(false, q.returns_json({ "select 1" }))
    eq(false, q.returns_json({ "select 1 -- for json path" }))
    eq(false, q.returns_json({ "/* for", "json */ select 1" }))
    eq(false, q.returns_json({ "select 'for json' as s" }))
  end)
  it(
    "флаги: .json — без заголовков и обрезки, остальное — таблица",
    function()
      local q = setup()
      eq({ { width = 65535, trunc = 0 }, true }, { q.export_opts("a/01_data.JSON") })
      eq({ { width = 65535, trunc = 8000 }, false }, { q.export_opts("a/out.txt") })
    end
  )
  it("хвостовые пустые строки срезаются, не-JSON помечается", function()
    local q = setup()
    eq({ { '[{"a":1}]', '{"b":2}' }, true, {} }, { q.export_text('[{"a":1}]\n{"b":2}\n\n', true) })
    eq(false, select(2, q.export_text("Msg 208, Level 16\n", true)))
    eq(false, select(2, q.export_text("", true)), "пустой ответ")
    eq({ { "n s", "- -" }, true, {} }, { q.export_text("n s\n- -\n", false) })
    -- for json приходит кусками по 2033 символа — склеиваются обратно в один набор
    eq({ { '[{"a":"xy"}]', "[1]" }, true, {} }, { q.export_text('[{"a":"x\ny"}]\n[1]\n', true) })
    eq({ { '[{"a":', "[1]" }, false, {} }, { q.export_text('[{"a":\n[1]\n', true) }, "оборванный")
    -- предупреждения сервера sqlcmd пишет в тот же stdout — в файл их не пускаем
    eq(
      { { "[1]" }, true, { "Warning: Null value is eliminated" } },
      { q.export_text("Warning: Null value is eliminated\n[1]\n", true) }
    )
    eq({ { "Msg 208, Level 16" }, false, { "Msg 208, Level 16" } }, { q.export_text("Msg 208, Level 16\n", true) })
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
        cb(0, '[{"a":1}]\n')
      end
      local out = vim.fs.normalize(vim.fn.tempname()) .. "/d.json"
      q.export({ range = 0, args = out, bang = false })
      eq("SET NOCOUNT ON;", got.lines[1])
      eq(nil, got.lines[2]:find("\239\187\191", 1, true), "BOM")
      eq({ conn = "dgsql_dev", db = "ics_ua97" }, { conn = got.conn.name, db = got.db })
      eq({ '[{"a":1}]' }, read(out))
      sql.run = function(_, cb)
        cb(1, "Msg 102, Level 15")
      end
      vim.cmd("wincmd p")
      q.export({ range = 0, args = out, bang = false })
      eq({ '[{"a":1}]' }, read(out), "после ошибки")
    end
  )
end)
