-- Перевод текста прямо в nvim (uga-rosa/translate.nvim).
--
-- Бэкенд google не требует ключа API: плагин дергает публичный endpoint через curl,
-- поэтому на Windows нужен curl в PATH (он есть в Win 10/11 и в Git for Windows).
--
-- Использование:
--   :Translate ru          — перевод выделения (или строки) в плавающее окно
--   :Translate en -output=replace — заменить выделение переводом
return {
  {
    "uga-rosa/translate.nvim",
    cmd = "Translate",
    -- Нормальный режим переводит текущую строку, визуальный — выделение.
    keys = {
      { "<leader>tt", "<cmd>Translate ru<cr>", mode = "n", desc = "Translate to RU (float)" },
      { "<leader>tt", ":'<,'>Translate ru<cr>", mode = "x", desc = "Translate to RU (float)" },
      { "<leader>tr", "<cmd>Translate ru -output=replace<cr>", mode = "n", desc = "Translate to RU (replace)" },
      { "<leader>tr", ":'<,'>Translate ru -output=replace<cr>", mode = "x", desc = "Translate to RU (replace)" },
      -- Слово под курсором: выделяем его через viw и переводим как визуальное выделение.
      {
        "<leader>tw",
        function()
          vim.cmd("normal! viw\27")
          vim.cmd("'<,'>Translate ru")
        end,
        mode = "n",
        desc = "Translate word under cursor to RU (float)",
      },
    },
    config = function()
      -- Плагин читает ключ из vim.g, а не из окружения: переносим из DEEPL_API_KEY.
      -- Ключи бесплатного тарифа заканчиваются на ":fx" и работают с другим endpoint.
      local key = vim.env.DEEPL_API_KEY
      vim.g.deepl_api_auth_key = key
      require("translate").setup({
        default = {
          command = key and (key:match(":fx$") and "deepl_free" or "deepl_pro") or "google",
          output = "floating",
        },
      })
    end,
  },
}
