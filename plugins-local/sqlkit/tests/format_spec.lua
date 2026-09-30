-- Форматирование (sqlkit.format): ожидаемое — примеры «Правильно» из tsql-style.md.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local fmt = require("sqlkit.format")

local function run(src, l1, l2)
  local lines = vim.split(src, "\n", { plain = true })
  return table.concat(fmt.format(lines, l1 or 1, l2 or #lines), "\n")
end

describe("токены", function()
  it("регистр, пробелы у операторов и запятых, части даты", function()
    eq(
      "select @X = ISNULL(a, 0), b from T where DATEDIFF(day, @d, GETDATE()) > 5 and x is NOT NULL and y = -1",
      run("SELECT @X=isnull(a,0) , b from T where DATEDIFF(dd,@d,getdate())>5 and x is not null and y=-1")
    )
  end)
  it(
    "exists ( через пробел, * и унарный минус не трогает, скобки без пробелов",
    function()
      eq(
        "if not exists (select COUNT(*), t.* from t where (a) = -@b * 2)",
        run("if not exists( select count(*), t.* from t where ( a )=-@b*2 )")
      )
    end
  )
  it("UNION / UNION ALL — заглавными (S66), all без union — нет", function()
    eq(
      "select a from T\nUNION ALL\nselect a from S UNION select all a from R",
      run("select a from T\nunion all\nselect a from S union select all a from R")
    )
  end)
  it("серия из трёх скобок — исключение S37", function()
    eq("set @a = ((( 1 )))", run("set @a=((( 1 )))"))
  end)
  it("строки, комментарии и [идентификаторы] не меняются", function()
    eq("set @s = 'a,b=c' + [x,y] -- x=y,z", run("set @s='a,b=c'+[x,y] -- x=y,z"))
  end)
  it(
    "имена, похожие на ключевые слова, не трогает: Date колонка, date тип",
    function()
      eq(
        "select Date, Text from T where CONVERT(date, Date) = @d",
        run("select Date, Text from T where convert(DATE,Date)=@d")
      )
    end
  )
  it("табы — пробелы", function()
    eq(false, run("\tselect\ta"):find("\t") ~= nil)
  end)
end)

describe("§13: что ЗАГЛАВНЫМИ", function()
  it("заголовок процедуры, её END, RAISERROR, RETURN, SET, транзакции", function()
    eq(
      table.concat({
        "CREATE PROCEDURE dbo.x",
        "   @a  int -- a",
        "AS BEGIN",
        "  SET NOCOUNT ON",
        "  if @a is NULL",
        "  begin",
        "    RAISERROR(60002, 16, 10) WITH SETERROR",
        "    RETURN -1",
        "  end",
        "  BEGIN TRAN",
        "  select case when @a = 1 then 1 else 2 end",
        "  COMMIT TRAN",
        "  RETURN 0",
        "END",
        "GO",
      }, "\n"),
      run(table.concat({
        "create procedure dbo.x",
        "   @a int -- a",
        "as begin",
        "  set nocount on",
        "  if @a is null",
        "  begin",
        "    raiserror(60002,16,10) with seterror",
        "    return -1",
        "  end",
        "  begin tran",
        "  select CASE WHEN @a=1 THEN 1 ELSE 2 END",
        "  commit tran",
        "  return 0",
        "end",
        "go",
      }, "\n"))
    )
  end)
  it("DDL заглавными, выражение CHECK строчными", function()
    eq(
      "ALTER TABLE [dbo].[chtRooms] ADD CONSTRAINT [CK_chtRooms_chtrType] CHECK ([chtrType] between 0 and 3)",
      run("alter table [dbo].[chtRooms] add constraint [CK_chtRooms_chtrType] check ([chtrType] BETWEEN 0 AND 3)")
    )
  end)
  it("DDL кончается на следующей инструкции", function()
    eq("DROP TABLE IF EXISTS #Tmp\nselect 1 from x", run("drop table if exists #Tmp\nSELECT 1 FROM x"))
  end)
end)

describe("списки с ведущими запятыми", function()
  it(
    "висячие запятые — в начало строки, отступ 3/2, `=` в колонку (S2, S11)",
    function()
      eq(
        table.concat({
          "select",
          "   x        = t.x",
          "  ,LongName = t.y",
          "from T t",
          "  left join U u on u.id = t.id",
        }, "\n"),
        run(table.concat({ "select", "  x=t.x,", "  LongName=t.y", "from T t", "  left join U u on u.id=t.id" }, "\n"))
      )
    end
  )
  it("отступ от вводящей строки: exec внутри блока", function()
    eq(
      "  exec @ret = bk_Proc\n     @opSum   = @StornSum\n    ,@opcrSum = @StornCrSum",
      run("  exec @ret = bk_Proc\n    @opSum=@StornSum,\n    @opcrSum = @StornCrSum")
    )
  end)
  it("update ... set", function()
    eq("update T set\n   a  = 1\n  ,bb = 2\nwhere x = 1", run("update T set\n  a=1,\n  bb=2\nwhere x=1"))
  end)
  it("подзапрос: отступ от select, а не от скобки", function()
    eq(
      table.concat({
        "from emNotifications n",
        "  outer apply",
        "    (select",
        "        rn.IsRefusal",
        "       ,rn.EditBy",
        "     from emRefusaNotifications rn",
        "    ) r",
      }, "\n"),
      run(table.concat({
        "from emNotifications n",
        "  outer apply",
        "    (select",
        "      rn.IsRefusal,",
        "      rn.EditBy",
        "     from emRefusaNotifications rn",
        "    ) r",
      }, "\n"))
    )
  end)
  it(
    "колонку `=` задаёт самое длинное имя, прежнее выравнивание не в счёт",
    function()
      eq("exec x\n   @a          = 1\n  ,@LongerName = 2", run("exec x\n   @a      = 1\n  ,@LongerName = 2"))
    end
  )
end)

describe("объявления (S21)", function()
  it("CREATE TABLE: типы, NULL под NULL, комментарии", function()
    eq(
      table.concat({
        "CREATE TABLE #TmpX (",
        "   dcID         int   NOT NULL -- ID",
        "  ,InvoiceSum   money NOT NULL -- Сума",
        "  ,ConfirmDate  date      NULL -- Дата",
        ")",
      }, "\n"),
      run(table.concat({
        "create table #TmpX (",
        "   dcID int not null -- ID",
        "  ,InvoiceSum money not null -- Сума",
        "  ,ConfirmDate date null -- Дата",
        ")",
      }, "\n"))
    )
  end)
  it("declare", function()
    eq(
      "declare\n   @RetCode      int\n  ,@DocumentSum  money        -- сума\n  ,@ClientName   varchar(250)",
      run("declare\n   @RetCode int\n  ,@DocumentSum money -- сума\n  ,@ClientName varchar(250)")
    )
  end)
end)

describe("диапазон", function()
  it("строки вне диапазона не трогает", function()
    eq("select A=isnull(x,1)\nselect A = ISNULL(x, 1)", run("select A=isnull(x,1)\nselect A=isnull(x,1)", 2, 2))
  end)
  it("блок, задетый диапазоном, выравнивается целиком", function()
    eq("declare\n   @a           int\n  ,@LongerName  int", run("declare\n   @a   int\n  ,@LongerName int", 3, 3))
  end)
  it("середина многострочного комментария — не код", function()
    local src = "/*\n  select a,b\n*/\nselect a,b"
    eq("/*\n  select a,b\n*/\nselect a, b", run(src, 2, 4))
  end)
  it("число строк не меняется", function()
    local src = "select\n  a,\n  -- c\n  b\nfrom t"
    eq(5, #vim.split(run(src), "\n"))
  end)
end)
