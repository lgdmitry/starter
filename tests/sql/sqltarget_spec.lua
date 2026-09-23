-- Куда идёт файл: подключение и базы по правилам репозитория (config.sqltarget).

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

-- Как в dgsql: datagroup-сервер по умолчанию с реестром usBases, биллинг — crocus;
-- icsMaster живёт на обоих.
local SERVERS = {
  dgsql = {
    dbs = { "datagroup", "ics_ua97", "icsMaster", "DEV_NEW", "icsFiles" },
    usbases = { datagroup = 0x1000000, ics_ua97 = 0x2000000, DEV_NEW = 0x4000000 },
  },
  crocus = { dbs = { "Crocus", "ServiceControle", "icsMaster" } },
  dgsqltest = { dbs = { "datagroup" } },
}
local CONNS = {
  { name = "crocus_dev", url = "sqlserver://crocus/Crocus" },
  { name = "dgsql_dev", url = "sqlserver://dgsql/datagroup" },
  { name = "dgsql_test", url = "sqlserver://dgsqltest/datagroup" },
}

local GUARD = [[
if not exists (select 1 from icsMaster.dbo.usBases
                where dbName = DB_NAME() and OptionsDB & %s <> 0)
begin
  DROP PROC dbo.SomeProc
end
go
create procedure dbo.SomeProc as select 1
]]

-- та же конструкция без DROP — условное содержимое, а не «где живёт объект»
local CONDITIONAL = [[
if not exists (select 1 from icsMaster.dbo.usBases
                where dbName = DB_NAME() and OptionsDB & 0x1000000 <> 0)
begin
  create index ix_x on dbo.tX (a)
end
]]

local ROOT = t.repo({
  name = "dgsql",
  conventions = {
    defaultServerEnvironment = "default",
    usBases = { topFolderMasks = { Crocus = { environment = "crocus" }, icsMaster = {} } },
  },
  environments = { { name = "default", server = "dgsql" }, { name = "crocus", server = "crocus" } },
  files = {
    ["ics_ua97/a_PRC.sql"] = "select 1",
    ["ics_ua97/bk/b_PRC.sql"] = "select 1",
    ["ics_ua97/g_PRC.sql"] = GUARD:format("0x3000000"),
    ["ics_ua97/c_TAB.sql"] = CONDITIONAL,
    ["Crocus/d_PRC.sql"] = "select 1",
    ["Crocus/copied_PRC.sql"] = GUARD:format("0x3000000"),
    ["ServiceControle/e_PRC.sql"] = "select 1",
    ["icsMaster/f_PRC.sql"] = "select 1",
  },
})

-- обычный репозиторий: без repo-conventions.json, работают запасные правила
local PLAIN = t.repo({
  name = "plain",
  files = { ["DEV_NEW/x_PRC.sql"] = "select 1", ["misc/y.sql"] = "select 1" },
})

local function setup()
  local sql = t.fresh()
  local log = t.stub_sql(sql, SERVERS, CONNS)
  return require("config.sqltarget"), sql, log
end

local function conn(name)
  for _, c in ipairs(CONNS) do
    if c.name == name then
      return vim.deepcopy(c)
    end
  end
end

describe("resolve_connection", function()
  it("по умолчанию — сервер окружения default", function()
    local target = setup()
    eq("dgsql_dev", target.resolve_connection(ROOT .. "/ics_ua97/a_PRC.sql", CONNS).name)
  end)
  it("environment верхней папки из topFolderMasks", function()
    local target = setup()
    eq("crocus_dev", target.resolve_connection(ROOT .. "/Crocus/d_PRC.sql", CONNS).name)
  end)
  it("environment своего правила PATH_RULES", function()
    local target = setup()
    eq("crocus_dev", target.resolve_connection(ROOT .. "/ServiceControle/e_PRC.sql", CONNS).name)
  end)
  it("без repo-conventions: dev-сервер, где есть база первой папки", function()
    local target = setup()
    eq("dgsql_dev", target.resolve_connection(PLAIN .. "/DEV_NEW/x_PRC.sql", CONNS).name)
  end)
end)

describe("resolve_databases", function()
  it("по пути", function()
    local target = setup()
    local dbs, how = target.resolve_databases(ROOT .. "/ics_ua97/a_PRC.sql", conn("dgsql_dev"), CONNS)
    eq({ "ics_ua97" }, dbs)
    eq("по пути ics_ua97/**", how)
  end)
  it("более длинный префикс раньше короткого", function()
    local target = setup()
    eq({ "datagroup" }, (target.resolve_databases(ROOT .. "/ics_ua97/bk/b_PRC.sql", conn("dgsql_dev"), CONNS)))
  end)
  it(
    "правило подошло, а базы на сервере нет — пусто, без базы из URL",
    function()
      local target = setup()
      local dbs, how = target.resolve_databases(ROOT .. "/Crocus/d_PRC.sql", conn("dgsql_dev"), CONNS)
      eq({}, dbs)
      t.truthy(how:find("нужна база Crocus", 1, true), "причина в how")
    end
  )
  it("сторож даёт несколько баз", function()
    local target = setup()
    local dbs, how = target.resolve_databases(ROOT .. "/ics_ua97/g_PRC.sql", conn("dgsql_dev"), CONNS)
    eq({ "datagroup", "ics_ua97" }, dbs)
    eq("usBases 0x3000000", how)
  end)
  it(
    "реестр usBases читается с default-сервера, даже когда файл едет на crocus",
    function()
      local target, _, log = setup()
      local dbs = target.resolve_databases(ROOT .. "/Crocus/copied_PRC.sql", conn("crocus_dev"), CONNS)
      -- чужой сторож, скопированный из ics_ua97: на crocus его баз нет — решает путь
      eq({ "Crocus" }, dbs)
      local registry = vim.tbl_filter(function(q)
        return q:find("usBases", 1, true) ~= nil
      end, log.queries)
      eq(1, #registry)
      t.truthy(registry[1]:find("^dgsql/icsMaster"), "реестр с dgsql: " .. registry[1])
    end
  )
  it("условный блок без DROP сторожем не считается", function()
    local target = setup()
    eq({ "ics_ua97" }, (target.resolve_databases(ROOT .. "/ics_ua97/c_TAB.sql", conn("dgsql_dev"), CONNS)))
  end)
  it("без правил: база из первой папки", function()
    local target = setup()
    local dbs, how = target.resolve_databases(PLAIN .. "/DEV_NEW/x_PRC.sql", conn("dgsql_dev"), CONNS)
    eq({ "DEV_NEW" }, dbs)
    eq("база из пути", how)
  end)
  it("без правил и без такой базы: база из URL", function()
    local target = setup()
    local dbs, how = target.resolve_databases(PLAIN .. "/misc/y.sql", conn("dgsql_dev"), CONNS)
    eq({ "datagroup" }, dbs)
    eq("база из URL", how)
  end)
end)

describe("other_servers", function()
  it("icsMaster уезжает и на второй сервер", function()
    local target = setup()
    local out = target.other_servers(ROOT .. "/icsMaster/f_PRC.sql", conn("dgsql_dev"), { "icsMaster" }, CONNS)
    eq(1, #out)
    eq("crocus_dev", out[1].conn.name)
    eq({ "icsMaster" }, out[1].databases)
  end)
  it("обычные базы — только на свой сервер", function()
    local target = setup()
    eq({}, target.other_servers(ROOT .. "/ics_ua97/a_PRC.sql", conn("dgsql_dev"), { "ics_ua97" }, CONNS))
  end)
  it("без repo-conventions — никуда", function()
    local target = setup()
    eq({}, target.other_servers(PLAIN .. "/misc/y.sql", conn("dgsql_dev"), { "icsMaster" }, CONNS))
  end)
end)

describe("pick", function()
  ---pick с подставленным выбором подключения; колбэк синхронный, когда вопросов нет.
  local function pick(opts, choose)
    local target, sql, log = setup()
    sql.select = function(list, _, cb)
      cb(choose and sql.by_name(list, choose) or nil)
    end
    local got
    target.pick(opts, function(c, dbs, file, how)
      got = { conn = c.name, dbs = dbs, file = file, how = how }
    end)
    return got, log
  end

  it("по правилам с url_fallback: база подключения — последней", function()
    local got = pick({ file = ROOT .. "/ServiceControle/e_PRC.sql", url_fallback = true })
    eq("crocus_dev", got.conn)
    eq({ "ServiceControle", "Crocus" }, got.dbs)
    eq("по пути servicecontrole/**, потом база из URL", got.how)
  end)
  it("руками (!) с url_fallback: база подключения — первой", function()
    local got = pick({ file = ROOT .. "/ServiceControle/e_PRC.sql", url_fallback = true, bang = true }, "crocus_dev")
    eq({ "Crocus", "ServiceControle" }, got.dbs)
    eq("база подключения, потом по пути servicecontrole/**", got.how)
  end)
  it("правила базы не дали — только база из URL", function()
    local got = pick({ file = ROOT .. "/Crocus/d_PRC.sql", url_fallback = true, name = "dgsql_dev" })
    eq({ "datagroup" }, got.dbs)
    t.truthy(got.how:find("^база из URL, для crocus/%*%*"), got.how)
  end)
  it("база из URL уже среди баз файла — не дублируется", function()
    local got = pick({ file = ROOT .. "/Crocus/d_PRC.sql", url_fallback = true })
    eq({ "Crocus" }, got.dbs)
  end)
  it("без url_fallback и без базы — отказ с причиной", function()
    local got, log = pick({ file = ROOT .. "/Crocus/d_PRC.sql", name = "dgsql_dev", hint = ". подсказка" })
    eq(nil, got)
    t.truthy(log.notes[1].msg:find("не определена база: для crocus/", 1, true), log.notes[1].msg)
    t.truthy(log.notes[1].msg:find(". подсказка$"), "hint в конце")
  end)
  it("явная база важнее правил", function()
    local got = pick({ file = ROOT .. "/ics_ua97/a_PRC.sql", database = "DEV_NEW" })
    eq({ "DEV_NEW" }, got.dbs)
    eq("база указана явно", got.how)
  end)
  it("контекст окна: его подключение и база", function()
    local got = pick({
      file = "sql://whatever",
      ctx = { file = ROOT .. "/ics_ua97/a_PRC.sql", conn = "crocus_dev", db = "ServiceControle" },
    })
    eq("crocus_dev", got.conn)
    eq({ "ServiceControle" }, got.dbs)
    eq(ROOT .. "/ics_ua97/a_PRC.sql", got.file)
  end)
  it(
    "неизвестное подключение по имени — ошибка, колбэк не зовётся",
    function()
      local got, log = pick({ file = ROOT .. "/ics_ua97/a_PRC.sql", name = "nope" })
      eq(nil, got)
      eq("нет подключения nope", log.notes[1].msg)
    end
  )
  it("отмена выбора подключения", function()
    local got, log = pick({ file = ROOT .. "/ics_ua97/a_PRC.sql", bang = true }, nil)
    eq(nil, got)
    eq("отменено", log.notes[1].msg)
  end)
end)
