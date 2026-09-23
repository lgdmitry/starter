-- Как зовётся sqlcmd: флаги, кодировки, URL (config.sqlconn).

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

describe("args", function()
  local sql = t.fresh()
  local path = "C:/tmp/q.sql"
  local native = sql.native_path(path)

  -- снимок наборов флагов для каждого места вызова: набор неочевидный, а менять его
  -- случайно, заодно с рефакторингом, нельзя
  it(":SqlDef — одно значение без обрезки", function()
    eq({ "-b", "-f", "i:65001", "-y", "0", "-Q", "Q" }, sql.args({ query = "Q", trunc = 0 }))
  end)
  it(":SqlEnum", function()
    eq(
      { "-b", "-f", "i:65001", "-w", "8000", "-y", "50", "-Y", "50", "-Q", "Q" },
      sql.args({ query = "Q", width = 8000, trunc = 50 })
    )
  end)
  it(":SqlUsages — через файл", function()
    eq(
      { "-b", "-f", "i:65001", "-I", "-w", "8000", "-y", "128", "-Y", "128", "-i", native },
      sql.args({ input = path, width = 8000, trunc = 128 })
    )
  end)
  it(":SqlDeploy — stderr и своя кодировка", function()
    eq(
      { "-b", "-f", "o:65001", "-I", "-r", "-i", native },
      sql.args({ input = path, codepage = "o:65001", stderr = true })
    )
  end)
  it("query — без лишнего", function()
    eq({ "-b", "-f", "i:65001", "-Q", "Q" }, sql.args({ query = "Q" }))
  end)
  it("путь для sqlcmd — в родном виде", function()
    eq(vim.fn.has("win32") == 1 and [[C:\tmp\q.sql]] or path, native)
  end)
end)

describe("with_database", function()
  local sql = t.fresh()
  it("подменяет базу и сохраняет параметры", function()
    eq(
      "sqlserver://u@host/icsMaster?trustServerCertificate=true",
      sql.with_database("sqlserver://u@host/datagroup?trustServerCertificate=true", "icsMaster")
    )
  end)
  it("дописывает базу, если её не было", function()
    eq("sqlserver://host/db", sql.with_database("sqlserver://host", "db"))
  end)
end)

describe("output_to_utf8", function()
  local sql = t.fresh()
  it("utf-8 не трогает", function()
    eq("Привет", sql.output_to_utf8("Привет"))
  end)
  it("cp1251 перекодирует", function()
    eq("Привет", sql.output_to_utf8("\207\240\232\226\229\242"))
  end)
end)

describe("by_name", function()
  local sql = t.fresh()
  it("без учёта регистра", function()
    eq("Crocus_Dev", sql.by_name({ { name = "Crocus_Dev" } }, "crocus_dev").name)
  end)
end)

describe("run", function()
  ---run с подменённым sqlcmd: reply(on_done) решает, что «ответит» процесс.
  local function run(o, reply)
    local sql = t.fresh()
    local seen = {}
    sql.sqlcmd = function(conn, db, args, on_done)
      seen.args, seen.db = args, db
      local i = vim.tbl_contains(args, "-i") and args[#args]
      seen.input_existed = i and vim.uv.fs_stat(i) ~= nil
      seen.input = i
      return reply(on_done)
    end
    local got
    sql.run(vim.tbl_extend("force", { conn = { name = "c", url = "" }, db = "d" }, o), function(code, text)
      got = { code = code, text = text }
    end)
    vim.wait(200, function()
      return got ~= nil
    end)
    return got, seen
  end

  it("запрос через временный файл, файл потом удалён", function()
    local got, seen = run({ lines = { "select 'ё'" }, opts = { width = 8000, trunc = 50 } }, function(on_done)
      on_done(0, "ok", false)
      return {}
    end)
    eq({ code = 0, text = "ok" }, got)
    eq("d", seen.db)
    t.truthy(seen.input_existed, "файл был на месте, пока шёл sqlcmd")
    eq(nil, vim.uv.fs_stat(seen.input), "файл удалён")
    eq({ "-b", "-f", "i:65001", "-I", "-w", "8000", "-y", "50", "-Y", "50", "-i" }, vim.list_slice(seen.args, 1, 11))
  end)
  it("флаги без файла — как есть", function()
    local _, seen = run({ opts = { query = "Q", trunc = 0 } }, function(on_done)
      on_done(0, "", false)
      return {}
    end)
    eq({ "-b", "-f", "i:65001", "-y", "0", "-Q", "Q" }, seen.args)
  end)
  it("после отмены колбэк не зовётся", function()
    local got, seen = run({ lines = { "select 1" } }, function(on_done)
      on_done(1, "обрывок", true)
      return {}
    end)
    eq(nil, got)
    eq(nil, vim.uv.fs_stat(seen.input), "файл удалён и после отмены")
  end)
  it("sqlcmd не запустился — колбэка нет, файл удалён", function()
    local got, seen = run({ lines = { "select 1" } }, function()
      return nil
    end)
    eq(nil, got)
    eq(nil, vim.uv.fs_stat(seen.input))
  end)
end)
