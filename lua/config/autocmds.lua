-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")
--
-- Страховка от E138 "All main.shada.tmp.X files exist, cannot write ShaDa file".
-- Neovim пишет shada не поверх main.shada, а во временный main.shada.tmp.<a-z>, и
-- оставляет его, если процесс убили до переименования. Когда заняты все 26 букв, каждый
-- выход падает с E138, а история/метки/регистры перестают сохраняться совсем.
-- Подчищаем остатки старше суток: работающий экземпляр столько свой файл не держит.
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("shada_tmp_cleanup", { clear = true }),
  once = true,
  desc = "Удалять зависшие main.shada.tmp.* старше суток",
  callback = function()
    vim.schedule(function()
      local dir = vim.fn.stdpath("state") .. "/shada"
      for name, kind in vim.fs.dir(dir) do
        if kind == "file" and name:match("^main%.shada%.tmp%.%a$") then
          local path = dir .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if stat and os.time() - stat.mtime.sec > 24 * 60 * 60 then
            vim.uv.fs_unlink(path)
          end
        end
      end
    end)
  end,
})

-- Репозитории-зеркала T-SQL (c:/repo/dgsql, c:/repo/esql): .sql файлы там в cp1251 + CRLF.
-- Раньше это задавал .editorconfig внутри dgsql, но charset=cp1251 нет в спецификации
-- editorconfig — Neovim ругался на каждый открываемый файл. Из тех настроек здесь остались
-- только те, которых нет в дефолтах: CRLF для новых файлов даёт виндовый fileformats=dos,unix,
-- финальный перевод строки — fixeol, а кодировку новых файлов и обрезку хвостовых пробелов
-- задаём сами. Только *.sql: разметка и json в .claude/ — utf-8, и хвостовые пробелы в
-- markdown значимы (перенос строки).
local sql_mirrors = { "/repo/dgsql/", "/repo/esql/" }

local function in_sql_mirror(buf)
  local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf)):lower()
  for _, root in ipairs(sql_mirrors) do
    if path:find(root, 1, true) then
      return true
    end
  end
  return false
end

local sql_mirror = vim.api.nvim_create_augroup("sql_mirror_repos", { clear = true })

vim.api.nvim_create_autocmd("BufNewFile", {
  group = sql_mirror,
  pattern = "*.sql",
  desc = "Новые .sql в зеркалах T-SQL создавать в cp1251 + CRLF",
  callback = function(ev)
    if in_sql_mirror(ev.buf) then
      vim.bo[ev.buf].fileencoding = "cp1251"
      vim.bo[ev.buf].fileformat = "dos"
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePre", {
  group = sql_mirror,
  pattern = "*.sql",
  desc = "Обрезать хвостовые пробелы (было trim_trailing_whitespace в .editorconfig)",
  callback = function(ev)
    if not in_sql_mirror(ev.buf) then
      return
    end
    local view = vim.fn.winsaveview()
    vim.cmd([[silent! keeppatterns %s/\s\+$//e]])
    vim.fn.winrestview(view)
  end,
})
