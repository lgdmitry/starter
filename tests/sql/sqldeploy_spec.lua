-- Выкладка пачкой (config.sqldeploy.deploy_files): куда уезжает каждый файл.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq
local fx = require("fixtures")

---deploy_files с подменённым sqlcmd; choose — что «выберут» в списке подключений.
local function deploy(files, opts, choose)
  vim.cmd("silent! only")
  vim.cmd("enew!")
  local sql = t.fresh()
  local log = t.stub_sql(sql, fx.SERVERS, fx.CONNS)
  log.steps = {}
  sql.ensure = function()
    return true
  end
  sql.select = function(_, _, cb)
    cb(choose)
  end
  sql.sqlcmd = function(conn, db, args, on_done)
    log.steps[#log.steps + 1] = conn.name .. "/" .. db .. " " .. vim.fs.basename(args[#args])
    on_done(0, "ok", false)
    return {}
  end
  local paths = vim.tbl_map(function(f)
    return fx.ROOT .. "/" .. f
  end, files)
  require("config.sqldeploy").deploy_files(paths, opts)
  vim.wait(200, function()
    local last = log.notes[#log.notes]
    return last and last.msg:find("^готово") ~= nil
  end)
  return log, log.notes[#log.notes].msg
end

describe("deploy_files", function()
  it("каждый файл — в свои базы, icsMaster — на оба сервера", function()
    local log, last = deploy({ "icsMaster/f_PRC.sql", "ics_ua97/a_PRC.sql" })
    eq({
      "dgsql_dev/icsMaster f_PRC.sql",
      "crocus_dev/icsMaster f_PRC.sql",
      "dgsql_dev/ics_ua97 a_PRC.sql",
    }, log.steps)
    eq("готово: файлов: 2 -> dgsql_dev, crocus_dev", last)
  end)
  it("подключение выбрано руками — только туда", function()
    local log = deploy({ "icsMaster/f_PRC.sql" }, { pick = true }, fx.conn("crocus_dev"))
    eq({ "crocus_dev/icsMaster f_PRC.sql" }, log.steps)
  end)
  it("хоть один файл без цели — не выкладывается ничего", function()
    local log, last = deploy({ "icsMaster/f_PRC.sql", "ics_ua97/a_PRC.sql" }, { pick = true }, fx.conn("crocus_dev"))
    eq({}, log.steps)
    t.truthy(last:find("^ничего не выложено:\na_PRC.sql: не определилась база"), last)
  end)
  it("выбранного подключения нет в .env файла", function()
    local log, last = deploy({ "icsMaster/f_PRC.sql" }, { pick = true }, { name = "zzz" })
    eq({}, log.steps)
    eq("ничего не выложено:\nf_PRC.sql: нет подключения zzz в .env проекта", last)
  end)
  it("не .sql пропускается с предупреждением", function()
    local log = deploy({ "icsMaster/f_PRC.sql", "readme.md" })
    eq({ "dgsql_dev/icsMaster f_PRC.sql", "crocus_dev/icsMaster f_PRC.sql" }, log.steps)
    eq("не .sql, пропущено: readme.md", log.notes[1].msg)
  end)
  it("изменённый буфер сохраняется до выкладки", function()
    local path = fx.ROOT .. "/ics_ua97/bk/b_PRC.sql"
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 2" })
    local buf = vim.api.nvim_get_current_buf()
    local sql = t.fresh()
    t.stub_sql(sql, fx.SERVERS, fx.CONNS)
    sql.ensure = function()
      return true
    end
    local seen
    sql.sqlcmd = function(_, _, _, on_done)
      seen = vim.fn.readfile(path)
      on_done(0, "", false)
      return {}
    end
    -- silent: иначе :write печатает «... written» посреди вывода раннера
    vim.cmd("silent lua require('config.sqldeploy').deploy({ fargs = {} })")
    vim.wait(200, function()
      return seen ~= nil
    end)
    eq({ "select 2" }, seen)
    eq(false, vim.bo[buf].modified)
  end)
end)
