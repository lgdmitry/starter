-- Окна с ответом (config.sqlwin): два места на всё, следующий ответ — в готовое окно.

local t = require("helpers")
local describe, it, eq = t.describe, t.it, t.eq

local function reset()
  vim.cmd("silent! only")
  vim.cmd("enew!")
  t.fresh()
  return require("config.sqlwin"), vim.api.nvim_get_current_win()
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
    "окно не тянет за собой sqlobject — зависимость только в одну сторону",
    function()
      local sqlwin = reset()
      sqlwin.show({ title = "a", text = "1", bottom = true })
      eq(nil, package.loaded["config.sqlobject"])
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
