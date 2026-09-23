-- Открывать при старте не дашборд, а последнюю сессию.
--
-- Сессии пишет persistence.nvim (он есть в LazyVim): при выходе — сессию для текущей
-- папки, руками — <leader>qs (сессия папки) и <leader>ql (последняя вообще).
-- Здесь только автозагрузка: nvim без аргументов открывает сессию текущей папки, а
-- если её нет — остаётся дашборд. Откатываться на самую свежую сессию нельзя: в новой
-- папке (свежий worktree, новый проект) тогда всплывает чужой проект с чужим cwd.
-- NVIM_RESTORE_LAST=1 в окружении пропускает поиск по cwd и сразу берёт самую
-- свежую (см. force_last ниже).

local M = {}

---Файл сессии для текущей папки: persistence хранит их с именем ветки и без.
local function session_for_cwd(persistence)
  for _, file in ipairs({ persistence.current(), persistence.current({ branch = false }) }) do
    if vim.fn.filereadable(file) == 1 then
      return file
    end
  end
end

---Буфер, который был текущим на момент :mksession, сессия открывает через :edit
---внутри VimEnter — и он остаётся с пустым 'filetype', а значит без treesitter и
---синтаксиса. filetypedetect ставит тип через :setf, а тот молчит, если
---did_filetype() уже истинно; флаг живёт всю цепочку автокоманд, и в ней FileType
---уже успевает прозвучать раньше детектора (lazy.nvim при подгрузке плагинов
---на BufRead* переигрывает события). :e это лечил, но перечитывал файл с диска и
---прогонял все BufRead* заново. Присваивание 'filetype' did_filetype() не
---проверяет и запускает FileType как положено — этого достаточно.
local function detect_filetypes()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == "" then
      local ft = vim.filetype.match({ buf = buf })
      if ft then
        vim.bo[buf].filetype = ft
      end
    end
  end
end

---Профиль alacritty для быстрого запуска nvim (profiles/neovim.toml) всегда
---стартует с cwd = папка этого конфига — из-за этого сессия для cwd всегда
---находится и матчится именно на неё, а настоящая последняя рабочая сессия
---(другой проект) никогда не всплывает. Профиль выставляет NVIM_RESTORE_LAST=1,
---чтобы явно попросить пропустить cwd-сессию и взять глобально последнюю.
local function force_last()
  return vim.env.NVIM_RESTORE_LAST == "1"
end

---Восстанавливает сессию текущей папки, а с NVIM_RESTORE_LAST=1 — самую свежую.
---@return boolean восстановили ли что-нибудь
function M.restore()
  local persistence = require("persistence")
  if not force_last() then
    if session_for_cwd(persistence) then
      persistence.load()
      detect_filetypes()
      return true
    end
    return false
  end
  local last = persistence.last()
  if last and vim.fn.filereadable(last) == 1 then
    persistence.load({ last = true })
    detect_filetypes()
    return true
  end
  return false
end

---Файл :mksession буферы не закрывает: он делает только `silent only` (окна) и
---`badd` для своих файлов, а всё, что было открыто до него, остаётся в списке —
---при переключении через <leader>qS / <leader>fp в bufferline висит смесь двух проектов.
---Закрываем сами перед загрузкой. Только файловые буферы: терминалы (claude,
---lazygit) убивать вместе с их процессами незачем. Snacks.bufdelete спрашивает
---про несохранённые изменения; на Cancel такой буфер просто остаётся.
local function close_file_buffers()
  Snacks.bufdelete.delete({
    filter = function(buf)
      return vim.bo[buf].buftype == ""
    end,
  })
end

---:mksession пишет arglist всегда, независимо от 'sessionoptions'. Запустили
---`nvim C:/repo/dgsql/x.sql` — x.sql навсегда в arglist: он уезжает в сессию
---любого проекта, куда потом переключились или где вышли, и оттуда при каждой
---загрузке снова всплывает лишним буфером (`$argadd`). Для сессий arglist не
---нужен, поэтому чистим его перед каждым сохранением.
local function clear_arglist()
  if vim.fn.argc(-1) > 0 then
    vim.cmd("%argdelete")
  end
end

---Сессию persistence пишет только на VimLeavePre, а <leader>qS и <leader>fp сначала
---делают chdir и только потом грузят другую сессию — прежний проект так и не
---сохранялся (всё, что в нём открыли после старта, терялось), а его буферы при
---выходе уезжали в сессию нового. DirChangedPre приходит ещё со старым cwd, так что
---persistence.current() указывает куда надо. Не пишем:
--- - во время source самой сессии (SessionLoad): в ней свой `cd`, а cwd к этому
---   моменту уже новый — затёрли бы файл, который сейчас читается;
--- - при window/tab-local cwd: current() берёт cwd окна, это не смена проекта;
--- - пустой список (как persistence с `need = 1`), иначе затрём сессию пустой.
local function save_before_cd()
  local persistence = require("persistence")
  if not persistence.active() or vim.g.SessionLoad == 1 or vim.v.event.scope ~= "global" then
    return
  end
  if vim.fs.normalize(vim.v.event.directory) == vim.fs.normalize(vim.fn.getcwd()) then
    return
  end
  local has_files = vim.iter(vim.api.nvim_list_bufs()):any(function(buf)
    return vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
  end)
  if has_files then
    clear_arglist()
    persistence.save()
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("restore_session", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PersistenceLoadPre",
    desc = "Закрыть буферы прежней сессии",
    callback = close_file_buffers,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PersistenceSavePre",
    desc = "Не писать arglist в сессию",
    callback = clear_arglist,
  })
  vim.api.nvim_create_autocmd("DirChangedPre", {
    group = group,
    desc = "Сохранить сессию прежнего проекта",
    callback = save_before_cd,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
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
