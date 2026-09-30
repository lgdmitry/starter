-- mssql — свои команды поверх dadbod и sqlcmd (plugins-local/mssql, модули mssql.*):
-- выкладка, просмотр объектов, разовые запросы, дополнение. Список подключений остался
-- в конфиге (config.sqldbs, грузится из dadbod.lua): он про эту машину, а не про плагин.
-- setup() здесь, а не в dadbod.lua: тот выполняется при разборе спеков, когда каталог
-- плагина ещё не в rtp.
return {
  {
    dir = vim.fn.stdpath("config") .. "/plugins-local/mssql",
    name = "mssql",
    lazy = false,
    config = function()
      require("mssql.conn").setup()
      require("mssql.target").setup()
      require("mssql.deploy").setup()
      require("mssql.object").setup()
      require("mssql.query").setup()
      require("mssql.complete").setup()
    end,
  },
}
