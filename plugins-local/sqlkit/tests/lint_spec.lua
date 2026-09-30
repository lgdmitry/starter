-- Линтер (sqlkit.lint): нарушения — примеры «Заборонено» из tsql-style.md, чистое —
-- «Правильно» оттуда же.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local lint = require("sqlkit.lint")

---Находки как «строка:код» (строки с 1) — читать проще, чем таблицы.
local function found(src)
  local out = {}
  for _, d in ipairs(lint.check(vim.split(src, "\n", { plain = true }))) do
    out[#out + 1] = (d.lnum + 1) .. ":" .. d.code
  end
  return out
end

local function src(lines)
  return table.concat(lines, "\n")
end

describe("токенные правила", function()
  it("S3: * вместо колонок, COUNT(*); умножение — можно", function()
    eq(
      { "1:S3", "2:S3", "3:S3" },
      found(src({ "select * from T", "select t.* from T t", "set @n = (select COUNT(*) from T)" }))
    )
    eq({}, found("set @a = @b * 2 + (@c) * 3"))
  end)
  it("S4: курсор", function()
    eq({ "1:S4" }, found("declare c cursor local fast_forward for select a from T"))
    eq({ "1:S4" }, found("declare @c cursor"))
  end)
  it("S20: CAST / TRY_CAST", function()
    eq({ "1:S20", "1:S20" }, found("set @d = CAST(@x as date) + TRY_CAST(@y as int)"))
    eq({}, found("set @d = CONVERT(date, @x)"))
  end)
  it("S43: LTRIM(RTRIM()) в любом порядке", function()
    eq({ "1:S43", "2:S43" }, found(src({ "set @a = NULLIF(LTRIM(RTRIM(@a)), '')", "set @b = rtrim(ltrim(@b))" })))
    eq({}, found("set @a = LTRIM(@a) + TRIM(@b)"))
  end)
  it("S8: select into #, но не insert into # / output into #", function()
    eq({ "2:S8" }, found(src({ "select", "  dcID into #TmpDocs", "from T" })))
    eq(
      {},
      found(src({
        "insert into #TmpDocs (dcID) select dcID from T",
        "update T set a = 1 output inserted.a into #TmpA (a)",
        "merge into #T t using S s on t.a = s.a when matched then delete;",
      }))
    )
  end)
  it("S42: COALESCE с двумя аргументами", function()
    eq({ "1:S42" }, found("set @a = COALESCE(@b, CONVERT(int, @c))"))
    eq({}, found("set @a = COALESCE(@b, @c, 0)"))
  end)
  it("S33: сокращённая часть даты", function()
    eq({ "1:S33", "1:S33" }, found("if DATEDIFF(dd, @a, @b) = 5 and DATEADD(mm, 1, @c) > @d"))
    eq({}, found("if DATEDIFF(day, @a, @b) = 5 and DATEADD(month, 1, @c) > @d"))
  end)
  it("S29: exists и скобка", function()
    eq(
      { "1:S29", "5:S29" },
      found(
        src({ "if not exists(select 1 from T)", "begin", "  RETURN -1", "end", "if exists", "  (select 1 from T)" })
      )
    )
    eq({}, found(src({ "if not exists (", "  select 1", "  from T)" })))
  end)
  it("S1: таб — одна находка на строку", function()
    eq({ "1:S1", "2:S1" }, found("\tselect\t1\n  select 2\t-- x"))
    eq({}, found("set @s = 'a\tb'"))
  end)
end)

describe("S52: case в одну строку", function()
  it("однострочный — нарушение, многострочный — нет", function()
    eq({ "1:S52" }, found("set @t = case when @a = 1 then 1 else 0 end"))
    eq({}, found(src({ "set @t =", "  case", "    when @a = 1 then 1", "    else 0", "  end" })))
  end)
end)

describe("S54: begin / end else", function()
  it("begin в строке с if, end и else порознь", function()
    eq(
      { "1:S54", "3:S54" },
      found(src({ "if @a is NULL begin", "  set @b = 1", "end else begin", "  set @b = 2", "end" }))
    )
    eq(
      { "5:S54" },
      found(src({ "if @a is NULL", "begin", "  set @b = 1", "end", "else", "begin", "  set @b = 2", "end" }))
    )
  end)
  it("правильная разметка, AS BEGIN, BEGIN TRAN, else у case — чисто", function()
    eq(
      {},
      found(src({
        "CREATE PROCEDURE dbo.x AS BEGIN",
        "  BEGIN TRAN",
        "  if @a is NULL",
        "  begin",
        "    set @b =",
        "      case",
        "        when @c = 1 then",
        "          case",
        "            when @d = 1 then 1",
        "            else 2",
        "          end",
        "        else 3",
        "      end",
        "  end else",
        "  begin",
        "    set @b = 2",
        "  end",
        "  COMMIT TRAN",
        "END",
      }))
    )
  end)
end)

describe("S12: вызов процедуры", function()
  it("позиционные параметры и несколько на строке", function()
    eq({ "1:S12", "1:S12", "1:S12" }, found("exec SampleProc Value1, NULL, @v out"))
    eq({ "1:S12" }, found("exec dbo.SampleProc @a = 1, @b = 2"))
  end)
  it("выражение в значении", function()
    eq(
      { "2:S12", "3:S12", "4:S12" },
      found(src({
        "exec @RetCode = bk7_IPInsProvodkaWorking",
        "   @opSum  = -@OLD_opSum",
        "  ,@Date = DATEADD(day, 1, @Date)",
        "  ,@Sum = @a + @b",
        "  ,@Name = @n",
        "if @@ERROR <> 0 or @RetCode <> 0",
      }))
    )
  end)
  it("правильный вызов, sp_executesql, exec (@sql) — чисто", function()
    eq(
      {},
      found(src({
        "exec @ret = SampleProc",
        "   @Param1 = @Value1",
        "  ,@Param2 = -1",
        "  ,@Param3 = N'x'",
        "  ,@Param4 = NULL",
        "  ,@Param5 = @Value3 out",
        "if @@ERROR <> 0 or @ret <> 0",
        "begin",
        "  RETURN -1",
        "end",
        "exec sp_ExecuteSQL",
        "   @Sql",
        "  ,N'@PeriodStart date'",
        "  ,@PeriodStart = @PeriodStart",
        "exec (@sql)",
        "exec @sql",
        "GRANT EXEC ON dbo.SampleProc TO gn_DBO",
      }))
    )
  end)
end)

describe("позиции", function()
  it(
    "колонка и конец — по токену, после многострочного комментария тоже",
    function()
      local d = lint.check({ "/* a", "b */ set @d = CAST(@x as date)" })[1]
      eq({ 1, 14, 1, 18, "S20: CONVERT() вместо CAST()" }, { d.lnum, d.col, d.end_lnum, d.end_col, d.message })
    end
  )
end)

---Процедура вокруг тела: структурные правила про «начало / конец процедуры» работают
---только внутри CREATE PROCEDURE.
local function proc(body, name)
  local out = { "CREATE PROCEDURE dbo." .. (name or "em_InsX"), "AS BEGIN" }
  vim.list_extend(out, body)
  out[#out + 1] = "END"
  return table.concat(out, "\n")
end

describe("структурные правила — уровень HINT", function()
  it("токенные — WARN, структурные — HINT", function()
    local d = lint.check({ "set @a = CAST(@b as int)", "if @a = 1", "  set @b = 2" })
    eq({ "S20", vim.diagnostic.severity.WARN, "S55", vim.diagnostic.severity.HINT }, {
      d[1].code,
      d[1].severity,
      d[2].code,
      d[2].severity,
    })
  end)
end)

describe("S55: тело if / else в begin … end", function()
  it("без begin — нарушение, и else if тоже", function()
    eq(
      { "1:S55", "3:S55", "3:S55", "5:S55" },
      found(src({
        "if @Top is NULL",
        "  set @Rows = @DefaultPage",
        "else if @Top <= 0",
        "  set @Rows = 2147483647",
        "else",
        "  set @Rows = @Top",
      }))
    )
  end)
  it("многострочное условие, case и exists в нём, DROP IF EXISTS — чисто", function()
    eq(
      {},
      found(src({
        "DROP TABLE IF EXISTS #TmpA",
        "if (@a = 1 and @b <> 2)",
        "  or @c =",
        "    case",
        "      when @d = 1 then 1",
        "      else 2",
        "    end",
        "begin",
        "  if not exists (",
        "    select 1",
        "    from T",
        "    where a = @a)",
        "  begin",
        "    set @b = 1",
        "  end else",
        "  begin",
        "    set @b = 2",
        "  end",
        "end",
      }))
    )
  end)
end)

describe("S32: один RETURN 0 в конце", function()
  it("ранний RETURN 0 — нарушение, последний и RETURN -1 — нет", function()
    eq(
      { "7:S32" },
      found(proc({
        "  if @a is NULL",
        "  begin",
        "    RETURN -1",
        "  end",
        "  RETURN 0",
        "  set @b = 1",
        "  --",
        "  RETURN 0",
      }))
    )
  end)
  it("вне процедуры не проверяется", function()
    eq({}, found(src({ "RETURN 0", "set @b = 1" })))
  end)
end)

describe("S9: DROP TABLE IF EXISTS до и после", function()
  it("нет ни до, ни в конце", function()
    eq(
      { "5:S9", "5:S9" },
      found(proc({ "  DROP TABLE IF EXISTS #Other", "  --", "  CREATE TABLE #TmpA (a int)", "  select a from #TmpA" }))
    )
  end)
  it("до и в конце — чисто; вне процедуры — только «до»", function()
    eq(
      {},
      found(proc({
        "  DROP TABLE IF EXISTS #TmpA",
        "  CREATE TABLE #TmpA (a int)",
        "  select a from #TmpA",
        "  DROP TABLE IF EXISTS #TmpA",
      }))
    )
    eq({ "1:S9" }, found(src({ "CREATE TABLE #TmpA (a int)", "select a from #TmpA" })))
  end)
end)

describe("S7: один declare-блок", function()
  it("второй declare и две переменные в строке", function()
    eq(
      { "5:S7", "7:S7" },
      found(proc({ "  declare", "     @a int", "    ,@b int, @c int", "  set @a = 1", "  declare @d int" }))
    )
  end)
  it("столбик и table-переменная с колонками в скобках — чисто", function()
    eq({}, found(proc({ "  declare", "     @a  int", "    ,@t  table (x int, y int)", "  ;", "  set @a = 1" })))
  end)
end)

describe("S34 / S51: проверки ошибок", function()
  it("@@ERROR после вставки во временную таблицу — лишний", function()
    eq(
      { "5:S34" },
      found(src({
        "insert into #TmpDocs (",
        "   dcID",
        ")",
        "select dcID from T",
        "if @@ERROR <> 0",
        "begin",
        "  RETURN -1",
        "end",
      }))
    )
  end)
  it("после insert в постоянную таблицу и после exec — обязателен", function()
    eq(
      { "3:S51", "7:S51", "8:S51" },
      found(proc({
        "  insert into Docs (",
        "     dcID",
        "  )",
        "  values (@dcID)",
        "  exec SampleProc",
        "  exec @ret = SampleProc",
        "     @Param1 = @a",
        "  set @a = 1",
      }))
    )
  end)
  it("правильные проверки — чисто", function()
    eq(
      {},
      found(proc({
        "  insert into Docs (",
        "     dcID",
        "  )",
        "  values (",
        "     @dcID",
        "  )",
        "  if @@ERROR <> 0",
        "  begin",
        "    RAISERROR(60004, 16, 10, 'Docs') WITH SETERROR",
        "    RETURN -1",
        "  end",
        "  exec @ret = SampleProc",
        "     @Param1 = @a",
        "  if @@ERROR <> 0 or @ret <> 0",
        "  begin",
        "    RAISERROR(60003, 16, 10, 'SampleProc') WITH SETERROR",
        "    RETURN -1",
        "  end",
        "  insert into #TmpA (a)",
        "  exec @ret = SampleProc",
        "  if @@ERROR <> 0 or @ret <> 0",
        "  begin",
        "    RETURN -1",
        "  end",
      }))
    )
  end)
end)

describe("S22: повторный вызов функции", function()
  it("второй GETDATE() и dbo.em_GetEmIDByLogin() — нарушение", function()
    eq(
      { "2:S22", "4:S22" },
      found(src({
        "set @CurDate = GETDATE()",
        "update T set EditAt = getdate()",
        "set @CurEmID = dbo.em_GetEmIDByLogin()",
        "set @x = dbo.em_GetEmIDByLogin()",
      }))
    )
  end)
  it(
    "NEWID, ROW_NUMBER() over, функции с аргументами, другой батч — чисто",
    function()
      eq(
        {},
        found(src({
          "select a = NEWID(), b = NEWID(), n = ROW_NUMBER() over (order by x), m = ROW_NUMBER() over (order by y)",
          "set @a = ISNULL(@b, 0) + ISNULL(@b, 0)",
          "set @d = GETDATE()",
          "GO",
          "set @d = GETDATE()",
        }))
      )
    end
  )
end)

describe("S24: Get не сортирует вывод", function()
  it("order by выходного набора в Get — нарушение", function()
    eq({ "7:S24" }, found(proc({ "  select", "     a", "    ,b", "  from T", "  order by a" }, "em_GetX")))
  end)
  it("top, over, присваивание, insert … select, не Get — чисто", function()
    eq(
      {},
      found(proc({
        "  select top 1",
        "    @id = a",
        "  from T",
        "  order by a desc",
        "  select",
        "    @id = a",
        "  from T",
        "  order by a",
        "  insert into #TmpA (a)",
        "  select",
        "    a",
        "  from T",
        "  order by a",
        "  select",
        "     a",
        "    ,n = ROW_NUMBER() over (order by a)",
        "  from T",
      }, "em_GetX"))
    )
    eq({}, found(proc({ "  select", "    a", "  from T", "  order by a" }, "em_InsX")))
  end)
end)

describe("ложные срабатывания с реальных файлов", function()
  it("S51: insert внутри begin try, exec в msdb — без проверки", function()
    eq(
      {},
      found(proc({
        "  begin try",
        "    insert into Docs (dcID)",
        "    values (@dcID)",
        "  end try",
        "  begin catch",
        "    RETURN -1",
        "  end catch",
        "  exec msdb.dbo.sysmail_help_profile_sp",
      }))
    )
  end)
  it("S32: сторож с DROP PROCEDURE после END — не тело", function()
    eq(
      {},
      found(src({
        "CREATE PROCEDURE dbo.x",
        "AS BEGIN",
        "  RETURN 0",
        "END",
        "if not exists (select 1 from T)",
        "begin",
        "  DROP PROCEDURE IF EXISTS x",
        "end",
        "GO",
      }))
    )
  end)
  it(
    "S7: declare @t table — не второй блок, висячая запятая — не две переменные",
    function()
      eq({ "4:S7" }, found(proc({ "  declare @a int,", "    @b int, @c int", "  declare @t table (x int)" })))
    end
  )
  it("S22: GETDATE() в DATEDIFF — замер времени", function()
    eq({}, found(src({ "set @Start = GETDATE()", "set @Sec = DATEDIFF(second, @Start, GETDATE())" })))
  end)
end)

describe("правила скилла 1.5.9", function()
  it("S64: подзапрос в списке select, exists в case — HINT", function()
    local d = lint.check({
      "select",
      "   chtrID   = r.chtrID",
      "  ,PeerEmID = (select top 1 p.emID from chtRoomMembers p where p.chtrID = r.chtrID)",
      "  ,State    =",
      "    case",
      "      when exists (select 1 from M m where m.chtrID = r.chtrID) then 2",
      "      else 0",
      "    end",
      "from chtRooms r",
    })
    eq(
      { "3:S64", "6:S64" },
      vim.tbl_map(function(x)
        return (x.lnum + 1) .. ":" .. x.code
      end, d)
    )
    eq(vim.diagnostic.severity.HINT, d[1].severity)
  end)
  it(
    "S64: присваивание переменной, derived table, apply, exists в where — не в счёт",
    function()
      eq(
        {},
        found(src({
          "set @x = (select COUNT(1) from T)",
          "select @Status = STUFF((select ',' + s.Name from S s FOR XML PATH('')), 1, 1, '')",
          "select top (@Rows)",
          "  t.a",
          "from (",
          "  select",
          "    a",
          "  from T) t",
          "  outer apply (",
          "    select",
          "      b",
          "    from R",
          "    where R.a = t.a) r",
          "where exists (",
          "  select 1",
          "  from Q",
          "  where Q.a = t.a)",
        }))
      )
    end
  )
  it(
    "S65: CREATE TABLE # после проверок — HINT; сразу после declare — чисто",
    function()
      eq(
        { "11:S65" },
        found(proc({
          "  SET NOCOUNT ON",
          "  declare",
          "     @RetCode int",
          "  if @dcID is NULL",
          "  begin",
          "    RAISERROR(60002, 16, 10, '@dcID')",
          "  end",
          "  DROP TABLE IF EXISTS #TmpA",
          "  CREATE TABLE #TmpA (",
          "     a int",
          "  )",
          "  DROP TABLE IF EXISTS #TmpA",
        }))
      )
      eq(
        {},
        found(proc({
          "  SET NOCOUNT ON",
          "  declare",
          "     @RetCode int",
          "  --",
          "  DROP TABLE IF EXISTS #TmpA",
          "  CREATE TABLE #TmpA (",
          "     a int",
          "  )",
          "  DROP TABLE IF EXISTS #TmpB",
          "  CREATE TABLE #TmpB (a int)",
          "  if @dcID is NULL",
          "  begin",
          "    RAISERROR(60002, 16, 10, '@dcID')",
          "  end",
          "  DROP TABLE IF EXISTS #TmpA",
          "  DROP TABLE IF EXISTS #TmpB",
        }))
      )
    end
  )
  it("P16: END тела — без комментария", function()
    eq({ "3:P16" }, found(src({ "CREATE PROCEDURE dbo.em_InsX", "AS BEGIN", "END -- procedure" })))
    eq(
      {},
      found(
        src({
          "CREATE PROCEDURE dbo.em_InsX",
          "AS BEGIN",
          "  if @a = 1",
          "  begin",
          "    set @a = 2",
          "  end -- a",
          "END",
        })
      )
    )
  end)
  it("P14: GRANT на IP-объект", function()
    eq({ "1:P14" }, found("GRANT EXEC ON [dbo].[cht_IPGetRooms] TO [gn_DBO]"))
    eq({}, found("GRANT EXEC ON [dbo].[cht_GetRooms] TO [gn_DBO]"))
  end)
end)

describe("SqlFormat: строки, которые переписал бы форматтер", function()
  local function lines(text)
    return vim.split(text, "\n", { plain = true })
  end
  it("только изменённые строки, с тем, как должно быть", function()
    local d =
      lint.unformatted(lines("RAISERROR(77311,16,10) WITH SETERROR\nset @a=1\nRETURN -1"), { [1] = true, [3] = true })
    eq(1, #d)
    eq({ 0, "SqlFormat: не по стандарту, <leader>df → RAISERROR(77311, 16, 10) WITH SETERROR" }, {
      d[1].lnum,
      d[1].message,
    })
  end)
  it("строка по стандарту — чисто; true — весь файл", function()
    eq({}, lint.unformatted(lines("RAISERROR(77311, 16, 10) WITH SETERROR"), { [1] = true }))
    eq(1, #lint.unformatted(lines("set @a = 1\nset @b=2"), true))
  end)
end)
