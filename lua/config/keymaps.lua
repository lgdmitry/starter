-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Своя группа, а не <leader>c: там у LazyVim code, и <leader>cf — это Format.
-- Относительно корня проекта, а не cwd: `%:.` для файла вне cwd молча отдаёт полный
-- путь, а cwd тут часто не проект (nvim открыт из домашней папки). normalize нужен
-- и для сравнения: имя буфера бывает с `c:` и смешанными слешами, а корень — с `C:\`.
vim.keymap.set("n", "<leader>yp", function()
  local file = vim.fs.normalize(vim.fn.expand("%:p"))
  local rel = vim.fs.relpath(vim.fs.normalize(LazyVim.root()), file)
  vim.fn.setreg("+", ((rel or file):gsub("/", "\\")))
end, { desc = "Yank path from project root" })
vim.keymap.set("n", "<leader>yP", function()
  vim.fn.setreg("+", (vim.fs.normalize(vim.fn.expand("%:p")):gsub("/", "\\")))
end, { desc = "Yank full path" })
vim.keymap.set("n", "<leader>yf", function()
  vim.fn.setreg("+", vim.fn.expand("%:t"))
end, { desc = "Yank filename" })

-- Snacks.bufdelete.all() окна не трогает: сплиты остаются, просто с пустым буфером
-- в каждом. Схлопываем их до одного, чтобы вышел чистый лист.
vim.keymap.set("n", "<leader>ba", function()
  Snacks.bufdelete.all()
  vim.cmd("silent! only")
end, { desc = "Delete All Buffers and Windows" })

-- Командная строка не выполняется, а только заполняется: имя дописываешь сам.
-- Путь берём относительный к cwd — короче, и <Tab> по нему дополняет как обычно.
vim.keymap.set("n", "<leader>fS", function()
  local dir = vim.fn.expand("%:.:h")
  local prefix = (dir == "" or dir == ".") and "" or vim.fn.fnameescape(dir) .. "/"
  vim.api.nvim_feedkeys(":saveas " .. prefix, "n", false)
end, { desc = "Save As" })

vim.keymap.set("i", "hh", "<Esc>l", { desc = "Exit insert mode" })
