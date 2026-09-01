-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
--
vim.opt.fileencodings = "utf-8,cp1251"
vim.g.lazyvim_rust_diagnostics = "rust-analyzer"

-- Провайдеры не используются (плагинов на python/perl/ruby/node нет), а checkhealth
-- на каждый ругается; для Python 3.14 без модуля neovim проверка ещё и падает.
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.snacks_animate = false

-- ftplugin/sql.vim из runtime вешает в insert-режиме <C-Left>/<C-Right> на
-- sqlcomplete#DrillOutOfColumns()/DrillIntoTable(), но extras/lang/sql.lua из
-- LazyVim выставляет g:loaded_sql_completion, из-за чего autoload/sqlcomplete.vim
-- завершается до объявления функций -> E117 при движении курсора по словам.
vim.g.omni_sql_no_default_maps = 1
