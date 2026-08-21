-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")
--
--vim.api.nvim_create_autocmd("DBDev", function()
--  vim.cmd("DB sqlserver://tank22\\snickers/ics_ua97?trusted_connection=yes&integrated.security=true")
--end, {})

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
