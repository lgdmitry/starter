-- Открывать при старте последнюю сессию вместо дашборда (логика — в config.session).
return {
  "folke/persistence.nvim",
  -- init выполняется на старте, до VimEnter. В lua/config/autocmds.lua это положить
  -- нельзя: LazyVim грузит его на VeryLazy, то есть уже после VimEnter.
  init = function()
    require("config.session").setup()
  end,
}
