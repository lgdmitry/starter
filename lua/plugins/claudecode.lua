-- Окно Claude на половину экрана: дефолтных 30% не хватает, чтобы читать ответы
-- и диффы без постоянного горизонтального переноса.
return {
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      split_width_percentage = 0.5,
    },
  },
}
