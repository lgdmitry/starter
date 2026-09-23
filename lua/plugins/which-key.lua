-- Группа <leader>d: у LazyVim это debug, но extra с dap не подключён, так что группа
-- пустая — занимаем её под свой SQL-слой (:SqlDeploy, :SqlQuery и прочее). Дописываем
-- в конец opts.spec, а не задаём spec целиком: списки при слиянии заменяются, и мы бы
-- снесли все остальные имена групп LazyVim.
return {
  "folke/which-key.nvim",
  opts = function(_, opts)
    opts.spec = opts.spec or {}
    table.insert(opts.spec, { "<leader>d", group = "sql" })
    table.insert(opts.spec, { "<leader>m", group = "multicursor" })
    table.insert(opts.spec, { "<leader>y", group = "yank path" })
  end,
}
