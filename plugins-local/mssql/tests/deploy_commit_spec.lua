-- Выкладка коммита (mssql.deploy.commit_objects): что берём и в каком порядке.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

describe("commit_objects", function()
  it("оставляет только _VIW, _TRG, _PRC и ставит их в порядке видов", function()
    eq(
      {
        "ics_ua97/a_VIW.sql",
        "icsMaster/c_TRG.sql",
        "icsMaster/b_TRG.sql",
        "ics_ua97/d_PRC.sql",
      },
      require("mssql.deploy").commit_objects({
        "ics_ua97/d_PRC.sql",
        "Alter/Alter_2610/261015_x.sql",
        "icsMaster/c_TRG.sql",
        "ics_ua97/a_VIW.sql",
        "icsMaster/b_TRG.sql",
        "Common/IcsAPI/ic7_GetObjectID_FNC.sql",
        "icsMaster/Tab_TAB.sql",
      })
    )
  end)
  it("суффикс в верхнем регистре тоже берётся", function()
    eq(
      { "icsMaster/bkCurrencySvr_TRG.SQL" },
      require("mssql.deploy").commit_objects({ "icsMaster/bkCurrencySvr_TRG.SQL", "x/y_FNC.sql" })
    )
  end)
  it("внутри вида сохраняется порядок git", function()
    eq({ "z_PRC.sql", "a_PRC.sql" }, require("mssql.deploy").commit_objects({ "z_PRC.sql", "a_PRC.sql" }))
  end)
  it(
    "IP-процедуры идут первыми среди _PRC, внутри групп — порядок git",
    function()
      eq(
        {
          "icsMaster/x_IPDel_PRC.sql",
          "icsMaster/x_IPGet_PRC.sql",
          "ics_ua97/ic_IPgetProfileName_PRC.sql",
          "ics_ua97/a_PRC.sql",
          "ics_ua97/TCPIPForCirpack_PRC.sql",
        },
        require("mssql.deploy").commit_objects({
          "ics_ua97/a_PRC.sql",
          "icsMaster/x_IPDel_PRC.sql",
          "ics_ua97/TCPIPForCirpack_PRC.sql",
          "icsMaster/x_IPGet_PRC.sql",
          "ics_ua97/ic_IPgetProfileName_PRC.sql",
        })
      )
    end
  )
  it("IP-процедуры идут после VIW и TRG", function()
    eq({
      "a/v_VIW.sql",
      "a/t_TRG.sql",
      "a/x_IPGet_PRC.sql",
      "a/p_PRC.sql",
    }, require("mssql.deploy").commit_objects({ "a/p_PRC.sql", "a/x_IPGet_PRC.sql", "a/t_TRG.sql", "a/v_VIW.sql" }))
  end)
  it("коммит без нужных видов — пустой список", function()
    eq({}, require("mssql.deploy").commit_objects({ "Alter/Alter_2610/261015_x.sql" }))
  end)
end)
