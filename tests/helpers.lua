-- Общее для спеков: describe/it/eq, свежие модули слоя, подставной сервер и репозиторий.

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

---Модули слоя заново: в них кэши (базы, реестр usBases, json), и тесты не должны
---видеть чужие.
function M.fresh()
  for name in pairs(package.loaded) do
    if name:match("^config%.sql") then
      package.loaded[name] = nil
    end
  end
  return require("config.sqlconn")
end

---URL вида sqlserver://host/db — dadbod под -u NONE не загружен, разбираем сами.
local function parse(url)
  local host, db = url:match("^%w+://([^/?]*)/?([^?]*)")
  return host or "", db or ""
end

---Подставной транспорт: servers = { host = { dbs = {...}, usbases = { db = mask } } }.
---Возвращает журнал запросов — по нему видно, куда ходили.
function M.stub_sql(sql, servers, conns)
  local log = { notes = {}, queries = {} }
  sql.url_parts = parse
  sql.connections = function()
    return vim.deepcopy(conns)
  end
  sql.notify = function(msg, level)
    log.notes[#log.notes + 1] = { msg = msg, level = level }
  end
  sql.query = function(conn, database, text)
    local host = parse(conn.url)
    local srv = servers[host] or { dbs = {} }
    log.queries[#log.queries + 1] = host .. "/" .. database .. ": " .. text
    if text:find("sys.databases", 1, true) then
      return vim.deepcopy(srv.dbs)
    end
    local mask = text:match("OptionsDB & (0x%x+)")
    if mask then
      local out = {}
      for db, opts in pairs(srv.usbases or {}) do
        if bit.band(opts, tonumber(mask)) ~= 0 then
          out[#out + 1] = db
        end
      end
      table.sort(out)
      return out
    end
    return {}
  end
  return log
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---Подставной репозиторий во временном каталоге.
---@param o { name: string, files: table<string, string>, conventions: table?, environments: table? }
---@return string root
function M.repo(o)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "/" .. o.name
  vim.fn.mkdir(root .. "/.git", "p")
  if o.conventions then
    write(root .. "/.claude/repo-conventions.json", vim.json.encode(o.conventions))
  end
  if o.environments then
    write(root .. "/.claude/.mcp.environments.json", vim.json.encode({ environments = o.environments }))
  end
  for rel, text in pairs(o.files or {}) do
    write(root .. "/" .. rel, text)
  end
  return root
end

---Строки буфера, не зависящие от того, как их туда положили.
function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return M
