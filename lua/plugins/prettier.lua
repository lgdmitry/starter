-- prettier 3 по умолчанию берёт ignore-файлы .gitignore и .prettierignore, и для
-- игнорируемого файла молча отдаёт текст без изменений — без ошибки, conform
-- считает форматирование успешным. Так не форматировались, например, json из
-- c:/repo/dgsql/.claude/scratchpad/ (каталог в .gitignore). Раз файл открыт в
-- редакторе и форматирование вызвано явно, .gitignore тут ни при чём: оставляем
-- только .prettierignore проекта.
return {
  "stevearc/conform.nvim",
  optional = true,
  opts = {
    formatters = {
      prettier = {
        prepend_args = { "--ignore-path", ".prettierignore" },
      },
    },
  },
}
