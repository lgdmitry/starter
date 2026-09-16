-- Список проектов (<leader>fp, кнопка Projects на дашборде) Snacks собирает из
-- git-корней недавних файлов, а недавние файлы берутся из shada. Пока запись shada
-- была сломана (E138), список замер на старом снимке: c:/repo/dgsql в него попал,
-- а c:/repo/esql — нет. Чтобы список не зависел от истории, объявляем c:/repo
-- каталогом с проектами: fd сам найдёт в нём все репозитории по .git.

-- Сортировка файлов по времени изменения. fd/rg отдают файлы в порядке обхода
-- каталогов, и в items нет ничего, кроме пути, — поэтому mtime дописываем сами
-- в transform (он вызывается для каждого найденного файла).
local by_mtime = {
  transform = function(item)
    local stat = (vim.uv or vim.loop).fs_stat(Snacks.picker.util.path(item) or "")
    item.mtime = stat and stat.mtime.sec or 0
  end,
  -- score первым: пока запрос пуст, он одинаков у всех и порядок решает mtime;
  -- как только начали печатать — важнее качество совпадения, а mtime разводит
  -- файлы с равным score.
  sort = { fields = { "score:desc", "mtime:desc", "idx" } },
  -- без sort_empty матчер не сортирует вообще, пока строка поиска пуста
  matcher = { sort_empty = true },
}

return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        -- dev перекрывает дефолт целиком, поэтому дефолтные каталоги повторяем
        projects = { dev = { "~/dev", "~/projects", "c:/repo" } },
        files = vim.deepcopy(by_mtime),
        git_files = vim.deepcopy(by_mtime),
        -- дефолт explorer рисует превью в узкой (40 колонок) панели под деревом;
        -- preview = "main" вместо неё показывает файл в главном окне редактора
        explorer = { layout = { preview = "main" } },
      },
    },
  },
}
