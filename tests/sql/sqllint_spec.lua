-- Линтер (config.sqllint): нарушения — примеры «Заборонено» из tsql-style.md, чистое —
-- «Правильно» оттуда же.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local lint = require("config.sqllint")

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
      { "1:S29", "3:S29" },
      found(src({ "if not exists (select 1 from T)", "  return", "if exists", "  (select 1 from T)" }))
    )
    eq({}, found(src({ "if not exists(", "  select 1", "  from T)" })))
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
