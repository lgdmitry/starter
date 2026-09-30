-- sqlkit — форматтер, линтер и отступ T-SQL (plugins-local/sqlkit). Выделены из слоя
-- config.sql*: от dadbod, sqlcmd и правил подключений не зависят. setup() здесь, а не в
-- dadbod.lua: тот выполняется при разборе спеков, когда каталог плагина ещё не в rtp.
return {
  {
    dir = vim.fn.stdpath("config") .. "/plugins-local/sqlkit",
    name = "sqlkit",
    lazy = false,
    config = function()
      require("sqlkit.format").setup()
      require("sqlkit.lint").setup()
    end,
  },
}
