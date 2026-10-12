-- Окна с ответом (mssql.win): два места на всё, следующий ответ — в готовое окно.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local function reset()
  vim.cmd("silent! only")
  vim.cmd("enew!")
  t.fresh()
  return require("mssql.win"), vim.api.nvim_get_current_win()
end

local function sqlwins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].sqlwin then
      out[#out + 1] = win
    end
  end
  return out
end

local function buffer_map(buf, lhs)
  local m = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  return m.buffer == 1 and m or nil
end

describe("show", function()
  it("нижнее окно переиспользуется", function()
    local sqlwin = reset()
    sqlwin.show({ kind = "query", title = "a", text = "1", bottom = true })
    sqlwin.show({ kind = "deploy", title = "b", text = "2", bottom = true })
    eq(1, #sqlwins())
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    eq({ "2" }, t.lines(0))
    eq("deploy", vim.b.sqlwin.kind)
  end)
  it("код объекта — в своём, вертикальном окне", function()
    local sqlwin = reset()
    sqlwin.show({ kind = "query", title = "a", text = "1", bottom = true })
    sqlwin.show({ kind = "object", title = "b", text = "2" })
    eq(2, #sqlwins())
    eq("side", vim.b.sqlwin.slot)
    eq("sql", vim.bo.filetype)
  end)
  it(
    "использования — в своём окне рядом с нижним, результат не затирают",
    function()
      local sqlwin = reset()
      sqlwin.show({ kind = "query", title = "a", text = string.rep("x\n", 15), bottom = true })
      local result = vim.api.nvim_get_current_win()
      sqlwin.show({ kind = "usages", title = "b", text = "2", bottom = true })
      eq(2, #sqlwins())
      eq("aside", vim.b.sqlwin.slot)
      eq(result, vim.b.sqlwin.from, "q вернёт в результат")
      eq(16, vim.api.nvim_win_get_height(result), "высоту результата не сплющило")
      eq(vim.api.nvim_win_get_position(result)[1], vim.api.nvim_win_get_position(0)[1], "рядом, а не под")
      eq("x", t.lines(vim.api.nvim_win_get_buf(result))[1])
      sqlwin.show({ kind = "usages", title = "c", text = "3", bottom = true })
      eq(2, #sqlwins(), "повторный — в то же окно")
      eq({ "3" }, t.lines(0))
    end
  )
  it(
    "enum из результата — рядом, результат на месте; новый результат — слева от справки",
    function()
      local sqlwin = reset()
      sqlwin.show({ kind = "query", title = "a", text = "1", bottom = true })
      local result = vim.api.nvim_get_current_win()
      sqlwin.show({ kind = "enum", title = "e", text = "2", bottom = true })
      eq(2, #sqlwins())
      eq({ "1" }, t.lines(vim.api.nvim_win_get_buf(result)), "результат не затёрт")
      local aside = vim.api.nvim_get_current_win()
      vim.cmd("close")
      vim.api.nvim_set_current_win(result)
      vim.cmd("close")
      sqlwin.show({ kind = "message", title = "m", text = "3", bottom = true })
      aside = vim.api.nvim_get_current_win()
      vim.cmd("wincmd p")
      sqlwin.show({ kind = "query", title = "q", text = "4", bottom = true })
      eq(vim.api.nvim_win_get_position(aside)[1], vim.api.nvim_win_get_position(0)[1], "в одну полосу")
      t.truthy(vim.api.nvim_win_get_position(0)[2] < vim.api.nvim_win_get_position(aside)[2], "слева")
    end
  )
  it("прошлый ответ не стирается: <C-o> возвращает к нему", function()
    local sqlwin = reset()
    sqlwin.show({ kind = "object", title = "x", text = "code x" })
    local first = vim.api.nvim_get_current_buf()
    sqlwin.show({ kind = "object", title = "y", text = "code y" })
    eq(2, #vim.api.nvim_tabpage_list_wins(0), "то же окно")
    eq(true, vim.api.nvim_buf_is_valid(first), "x жив")
    vim.cmd.normal({ args = { vim.keycode("<C-o>") }, bang = true })
    eq(first, vim.api.nvim_get_current_buf())
    eq({ "code x" }, t.lines(0))
  end)
  it("тот же ответ ещё раз — вытесняет прежний, а не копится", function()
    local sqlwin = reset()
    sqlwin.show({ kind = "object", title = "x", text = "1" })
    local first = vim.api.nvim_get_current_buf()
    sqlwin.show({ kind = "object", title = "y", text = "2" })
    sqlwin.show({ kind = "object", title = "x", text = "3" })
    eq(false, vim.api.nvim_buf_is_valid(first))
    t.truthy(vim.api.nvim_buf_get_name(0):find("sql://x$"), vim.api.nvim_buf_get_name(0))
  end)
  it("хранится не больше keep ответов", function()
    local sqlwin = reset()
    sqlwin.keep = 2
    local bufs = {}
    for i = 1, 4 do
      sqlwin.show({ kind = "object", title = "o" .. i, text = tostring(i) })
      bufs[i] = vim.api.nvim_get_current_buf()
    end
    eq({ false, false, true, true }, vim.tbl_map(vim.api.nvim_buf_is_valid, bufs))
  end)
  it("буфер: имя, пустой хвост срезан, только чтение, ctx", function()
    local sqlwin = reset()
    local ctx = { file = "f.sql", conn = "c", db = "d" }
    sqlwin.show({ title = "x @ c/d", text = "a\nb\n\n  \n", ctx = ctx, filetype = "" })
    eq({ "a", "b" }, t.lines(0))
    t.truthy(vim.api.nvim_buf_get_name(0):find("sql://x @ c/d", 1, true), "имя буфера")
    eq(false, vim.bo.modifiable)
    eq("nofile", vim.bo.buftype)
    eq(ctx, vim.b.sqlctx)
  end)
  it("высота нижнего окна — по строкам, от 5 до 20", function()
    local sqlwin = reset()
    sqlwin.show({ title = "a", text = "1", bottom = true })
    eq(5, vim.api.nvim_win_get_height(0))
    sqlwin.show({ title = "b", text = string.rep("x\n", 40), bottom = true })
    eq(20, vim.api.nvim_win_get_height(0))
  end)
  it("focus=false — курсор остаётся где был", function()
    local sqlwin, main = reset()
    sqlwin.show({ title = "a", text = "1", bottom = true, focus = false })
    eq(main, vim.api.nvim_get_current_win())
  end)
  it("ответ из окна ответа наследует, куда возвращаться", function()
    local sqlwin, main = reset()
    sqlwin.show({ title = "a", text = "1", bottom = true })
    sqlwin.show({ title = "b", text = "2", bottom = true })
    eq(main, vim.b.sqlwin.from)
  end)
end)

describe("клавиши", function()
  it("K, gK, gf и q — буферные", function()
    local sqlwin = reset()
    sqlwin.show({ title = "a", text = "1", bottom = true, filetype = "" })
    for _, lhs in ipairs({ "K", "gK", "gf", "q" }) do
      t.truthy(buffer_map(0, lhs), lhs)
    end
  end)
  it(
    "окно не тянет за собой mssql.object — зависимость только в одну сторону",
    function()
      local sqlwin = reset()
      sqlwin.show({ title = "a", text = "1", bottom = true })
      eq(nil, package.loaded["mssql.object"])
    end
  )
  it("q закрывает и возвращает в исходное окно", function()
    local sqlwin, main = reset()
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    sqlwin.show({ title = "a", text = "1", bottom = true })
    buffer_map(0, "q").callback()
    eq(other, vim.api.nvim_get_current_win())
    eq(0, #sqlwins())
    t.truthy(main ~= other)
  end)
end)
