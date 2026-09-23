-- Просмотр объектов (config.sqlobject): только то, что не требует живого сервера.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local ROOT = t.repo({ name = "objrepo", files = { ["ics_ua97/a_PRC.sql"] = "exec dbo.x" } })
-- база из URL другая: K ищет сначала в базе файла, потом в ней
local SERVERS = { srv = { dbs = { "ics_ua97", "icsMaster" } } }
local CONNS = { { name = "srv_dev", url = "sqlserver://srv/icsMaster" } }

local function setup(reply)
  vim.cmd("silent! only")
  vim.cmd("silent edit! " .. vim.fn.fnameescape(ROOT .. "/ics_ua97/a_PRC.sql"))
  local sql = t.fresh()
  local log = t.stub_sql(sql, SERVERS, CONNS)
  log.sqlcmd = {}
  sql.sqlcmd = function(_, db, _, on_done)
    log.sqlcmd[#log.sqlcmd + 1] = db
    return reply(on_done)
  end
  return require("config.sqlobject"), log
end

describe(":SqlDef", function()
  it("отменённый K не показывает окна и не ругается", function()
    local obj, log = setup(function(on_done)
      on_done(1, "", true)
      return {}
    end)
    obj.define({ fargs = { "dbo.x" } })
    vim.wait(100)
    eq(1, #vim.api.nvim_tabpage_list_wins(0))
    eq({}, log.notes)
  end)
  it(
    "не нашлось в первой базе — идёт в следующую, нашлось — окно",
    function()
      local obj, log
      obj, log = setup(function(on_done)
        on_done(0, #log.sqlcmd == 1 and "#NOTFOUND#" or "create procedure dbo.x", false)
        return {}
      end)
      obj.define({ fargs = { "dbo.x" } })
      vim.wait(200, function()
        return #vim.api.nvim_tabpage_list_wins(0) == 2
      end)
      eq({ "ics_ua97", "icsMaster" }, log.sqlcmd)
      eq("icsMaster", vim.b.sqlctx.db)
      eq({}, log.notes)
    end
  )
end)
