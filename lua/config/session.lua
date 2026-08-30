-- Открывать при старте не дашборд, а последнюю сессию.
--
-- Сессии пишет persistence.nvim (он есть в LazyVim): при выходе — сессию для текущей
-- папки, руками — <leader>qs (сессия папки) и <leader>ql (последняя вообще).
-- Здесь только автозагрузка: nvim без аргументов сначала ищет сессию текущей папки,
-- а если её нет — берёт самую свежую из сохранённых. Сессий нет вовсе — остаётся
-- дашборд, он никуда не убран.

local M = {}

---Файл сессии для текущей папки: persistence хранит их с именем ветки и без.
local function session_for_cwd(persistence)
  for _, file in ipairs({ persistence.current(), persistence.current({ branch = false }) }) do
    if vim.fn.filereadable(file) == 1 then
      return file
    end
  end
end

---Восстанавливает сессию текущей папки, иначе самую свежую из сохранённых.
---@return boolean восстановили ли что-нибудь
function M.restore()
  local persistence = require("persistence")
  if session_for_cwd(persistence) then
    persistence.load()
    return true
  end
  local last = persistence.last()
  if last and vim.fn.filereadable(last) == 1 then
    persistence.load({ last = true })
    return true
  end
  return false
end

function M.setup()
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("restore_session", { clear = true }),
    nested = true, -- иначе у файлов из сессии не сработают FileType, LSP и прочее
    desc = "Открыть последнюю сессию вместо дашборда",
    callback = function()
      -- запустили с файлом (nvim file.sql), с готовым буфером (nvim +Man), из пайпа
      -- или вообще без интерфейса (--headless) — не лезем
      if vim.fn.argc(-1) > 0 or vim.api.nvim_buf_get_name(0) ~= "" or #vim.api.nvim_list_uis() == 0 then
        return
      end
      M.restore()
    end,
  })
end

return M
