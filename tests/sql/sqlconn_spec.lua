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
