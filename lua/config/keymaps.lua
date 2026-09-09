-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("n", "<leader>cp", function() vim.fn.setreg("+", vim.fn.expand("%:p")) end, { desc = "Copy full path" })
vim.keymap.set("n", "<leader>cf", function() vim.fn.setreg("+", vim.fn.expand("%:t")) end, { desc = "Copy filename" })
vim.keymap.set("n", "<leader>cr", function() vim.fn.setreg("+", vim.fn.expand("%")) end, { desc = "Copy relative path" })

vim.keymap.set("i", "nn", "<Esc>", { desc = "Exit insert mode" })
