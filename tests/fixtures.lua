-- Подставной dgsql для спеков: datagroup-сервер по умолчанию с реестром usBases,
-- биллинг — crocus; icsMaster живёт на обоих. Репозитории создаются один раз на прогон.

local t = require("helpers")

local M = {}

M.SERVERS = {
  dgsql = {
    dbs = { "datagroup", "ics_ua97", "icsMaster", "DEV_NEW", "icsFiles" },
    usbases = { datagroup = 0x1000000, ics_ua97 = 0x2000000, DEV_NEW = 0x4000000 },
  },
  crocus = { dbs = { "Crocus", "ServiceControle", "icsMaster" } },
  dgsqltest = { dbs = { "datagroup" } },
}
M.CONNS = {
  { name = "crocus_dev", url = "sqlserver://crocus/Crocus" },
  { name = "dgsql_dev", url = "sqlserver://dgsql/datagroup" },
  { name = "dgsql_test", url = "sqlserver://dgsqltest/datagroup" },
}

M.GUARD = [[
if not exists (select 1 from icsMaster.dbo.usBases
                where dbName = DB_NAME() and OptionsDB & %s <> 0)
begin
  DROP PROC dbo.SomeProc
end
go
create procedure dbo.SomeProc as select 1
]]

-- та же конструкция без DROP — условное содержимое, а не «где живёт объект»
M.CONDITIONAL = [[
if not exists (select 1 from icsMaster.dbo.usBases
                where dbName = DB_NAME() and OptionsDB & 0x1000000 <> 0)
begin
  create index ix_x on dbo.tX (a)
end
]]

M.ROOT = t.repo({
  name = "dgsql",
  conventions = {
    defaultServerEnvironment = "default",
    usBases = { topFolderMasks = { Crocus = { environment = "crocus" }, icsMaster = {} } },
  },
  environments = { { name = "default", server = "dgsql" }, { name = "crocus", server = "crocus" } },
  files = {
    ["ics_ua97/a_PRC.sql"] = "select 1",
    ["ics_ua97/bk/b_PRC.sql"] = "select 1",
    ["ics_ua97/g_PRC.sql"] = M.GUARD:format("0x3000000"),
    ["ics_ua97/c_TAB.sql"] = M.CONDITIONAL,
    ["Crocus/d_PRC.sql"] = "select 1",
    ["Crocus/copied_PRC.sql"] = M.GUARD:format("0x3000000"),
    ["ServiceControle/e_PRC.sql"] = "select 1",
    ["icsMaster/f_PRC.sql"] = "select 1",
  },
})

-- обычный репозиторий: без repo-conventions.json, работают запасные правила
M.PLAIN = t.repo({
  name = "plain",
  files = { ["DEV_NEW/x_PRC.sql"] = "select 1", ["misc/y.sql"] = "select 1" },
})

---Копия подключения по имени — чтобы тест не испортил общую таблицу.
function M.conn(name)
  for _, c in ipairs(M.CONNS) do
    if c.name == name then
      return vim.deepcopy(c)
    end
  end
end

return M
