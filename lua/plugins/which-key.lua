-- Группа <leader>d: у LazyVim это debug, но extra с dap не подключён, так что группа
-- пустая — занимаем её под свой SQL-слой (:SqlDeploy, :SqlQuery и прочее). Дописываем
-- в конец opts.spec, а не задаём spec целиком: списки при слиянии заменяются, и мы бы
-- снесли все остальные имена групп LazyVim.
--
-- Иконки задаём явно: which-key подбирает их по правилам на английские слова в описании
-- ("debug", "file", ...), а у наших маппингов описания русские. Сами маппинги заданы в
-- других местах, здесь только иконки к ним. real = true: без него which-key показывал бы
-- пункт и там, где маппинга нет, — а часть из них буферные (K/gf в sql, <leader>dx в
-- буфере запроса, <leader>mx только при нескольких курсорах).
local function icon(glyph, color)
  return { icon = glyph, color = color }
end

return {
  "folke/which-key.nvim",
  opts = function(_, opts)
    opts.spec = opts.spec or {}
    table.insert(opts.spec, {
      mode = { "n", "x" },
      real = true,
      -- mode включает x, иначе в visual группа видна без имени, хотя маппинги там есть.
      { "<leader>d", group = "sql", icon = { cat = "filetype", name = "sql" }, real = false },
      { "<leader>dd", icon = icon("󰕒", "azure") },
      { "<leader>dD", icon = icon("󰕒", "azure") },
      { "<leader>dq", icon = icon("󰆼", "azure") },
      { "<leader>dQ", icon = icon("󰆼", "azure") },
      { "<leader>dx", icon = icon("󰐊", "green") },
      { "<leader>dr", icon = icon("󰓫", "cyan") },
      { "<leader>de", icon = icon("󰉻", "cyan") },
      { "<leader>du", icon = icon("󰍉", "green") },
      { "<leader>dU", icon = icon("󰍉", "green") },
      { "<leader>dc", icon = icon("󰓛", "red") },
      { "<leader>di", icon = icon("󰋼", "cyan") },
      { "gK", icon = icon("󰅩", "azure") },
      { "gf", icon = icon("󰈮", "cyan") },

      { "<leader>m", group = "multicursor", icon = icon("󰗧", "purple"), real = false },
      { "<leader>mj", icon = icon("󰁅", "purple") },
      { "<leader>mk", icon = icon("󰁝", "purple") },
      { "<leader>mJ", icon = icon("󰒭", "grey") },
      { "<leader>mK", icon = icon("󰒮", "grey") },
      { "<leader>mn", icon = icon("󰐕", "purple") },
      { "<leader>mN", icon = icon("󰐕", "purple") },
      { "<leader>ms", icon = icon("󰅂", "grey") },
      { "<leader>mS", icon = icon("󰅁", "grey") },
      { "<leader>mA", icon = icon("󰒆", "purple") },
      { "<leader>mo", icon = icon("󰑑", "purple") },
      { "<leader>ma", icon = icon("󰉢", "purple") },
      { "<leader>mv", icon = icon("󰦛", "purple") },
      { "<leader>mx", icon = icon("󰅖", "red") },
      { "ga", icon = icon("󰉹", "purple") },

      { "<leader>y", group = "yank path", icon = icon("󰆏", "yellow"), real = false },
      { "<leader>yp", icon = icon("󰙅", "yellow") },
      { "<leader>yP", icon = icon("󰉋", "yellow") },
      { "<leader>yf", icon = icon("󰈔", "yellow") },
      { "<leader>fS", icon = icon("󰆓", "cyan") },
    })
  end,
}
