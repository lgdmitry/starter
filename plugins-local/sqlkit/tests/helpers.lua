-- Общее для спеков sqlkit: describe/it/eq, без зависимостей от остального конфига.

local M = {}

local passed, failed, failures = 0, 0, {}
local current_file, prefix = "", {}

function M.file(name)
  current_file = name
end

function M.fail_file(err)
  failed = failed + 1
  failures[#failures + 1] = current_file .. ": " .. tostring(err)
end

function M.describe(name, fn)
  table.insert(prefix, name)
  fn()
  table.remove(prefix)
end

function M.it(name, fn)
  local full = current_file .. " > " .. table.concat(prefix, " > ") .. " > " .. name
  -- traceback нужен только при неожиданной ошибке; у eq сообщение и так точное
  local ok, err = xpcall(fn, function(e)
    return type(e) == "table" and e.msg or debug.traceback(tostring(e), 2)
  end)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    failures[#failures + 1] = full .. "\n    " .. tostring(err):gsub("\n", "\n    ")
  end
end

function M.eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error({
      msg = (what and (what .. ": ") or "")
        .. "ожидали "
        .. vim.inspect(expected)
        .. ", получили "
        .. vim.inspect(actual),
    })
  end
end

function M.truthy(v, what)
  if not v then
    error({ msg = (what or "условие") .. " не выполнено" })
  end
end

function M.report()
  for _, f in ipairs(failures) do
    io.stdout:write("FAIL " .. f .. "\n")
  end
  io.stdout:write(("%d passed, %d failed\n"):format(passed, failed))
  return failed == 0
end

return M
