return {
  -- add gruvbox
  { "ellisonleao/gruvbox.nvim" },

  -- kanagawa на пробу; вернуться на gruvbox — поменять colorscheme ниже
  -- (или на лету :colorscheme gruvbox).
  { "rebelot/kanagawa.nvim" },

  -- Configure LazyVim to load kanagawa
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
