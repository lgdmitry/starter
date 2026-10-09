-- Миникарта справа, как в VS Code / Sublime (Isrothy/neominimap.nvim).
--
-- Выбран neominimap, а не mini.map: он рисует силуэт кода с treesitter-цветами
-- и метками git/диагностик/поиска — ближе всего к VS Code. Своего extra для
-- миникарты в LazyVim нет.
--
-- Тоггл на <leader>uM: <leader>um уже занят render-markdown из extra lang.markdown.
return {
  {
    "Isrothy/neominimap.nvim",
    version = "v3.x.x",
    -- Плагин ленится сам; при отложенной загрузке карта не появляется в первом буфере.
    lazy = false,
    keys = {
      { "<leader>uM", "<cmd>Neominimap Toggle<cr>", desc = "Toggle Minimap" },
    },
    init = function()
      vim.g.neominimap = {
        auto_enable = true,
        -- float — карта у каждого окна, как в VS Code; split дал бы одну на вкладку.
        layout = "float",
        float = { minimap_width = 16, window_border = "none" },
        -- Выгрузки и дампы SQL на десятки тысяч строк тормозят пересчёт карты.
        buf_filter = function(bufnr)
          return vim.api.nvim_buf_line_count(bufnr) < 20000
        end,
        -- dbui, lazy, дашборд и т.п. отсекаются дефолтным exclude_buftypes (nofile).
        exclude_filetypes = { "help", "bigfile", "dbout" },
        click = { enabled = true },
        search = { enabled = true },
      }
    end,
  },
}
