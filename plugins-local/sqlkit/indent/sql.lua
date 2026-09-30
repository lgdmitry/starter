-- Свой отступ для T-SQL (sqlkit.indent) вместо родного indent/sql.vim и treesitter.
-- Каталог конфига в runtimepath раньше $VIMRUNTIME, поэтому этот файл грузится первым, и
-- b:did_indent выключает родной. LazyVim свой treesitter-indentexpr поверх не ставит:
-- LazyVim.set_default не трогает опцию, выставленную не из $VIMRUNTIME.
if vim.b.did_indent then
  return
end
vim.b.did_indent = true

require("sqlkit.indent").attach(0)
vim.b.undo_indent = "setl indentexpr< indentkeys< autoindent< smartindent<"
