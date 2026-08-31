-- Подсказки which-key — только латиница.
--
-- langmapper каждому маппингу заводит кириллический дубль (см. plugins/langmapper.lua),
-- и в подсказках они шли вперемешку с оригиналами: <leader>ff и <leader>аа рядом.
-- Дубли остаются рабочими, просто в список не попадают.
return {
  "folke/which-key.nvim",
  opts = {
    filter = function(mapping)
      return not mapping.lhs:find("[\128-\255]")
    end,
  },
}
