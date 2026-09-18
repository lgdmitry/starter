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

-- Выкладка выделенного: отметить записи Tab и нажать <leader>dd — файлы уедут в базы
-- по тем же правилам, что и :SqlDeploy для открытого файла (config.sqldeploy).
-- Маппинг буферный и такой же, как глобальный: без него <leader>dd в окне пикера
-- сработал бы глобальный и попробовал выложить сам буфер пикера, то есть ничего.
local deploy = {
  actions = {
    sql_deploy = function(picker)
      -- fallback: без выделения выкладывается запись под курсором
      local files = vim.tbl_map(Snacks.picker.util.path, picker:selected({ fallback = true }))
      picker.list:set_selected() -- выделение съедено действием, как в explorer_del
      -- explorer живёт дальше (это сайдбар), разовый список — закрывается: иначе он
      -- закроет собой окно с ответом sqlcmd
      if picker.opts.source ~= "explorer" then
        picker:close()
      end
      require("config.sqldeploy").deploy_files(files)
    end,
  },
  win = {
    list = { keys = { ["<leader>dd"] = { "sql_deploy", desc = "выложить .sql (SqlDeploy)" } } },
    -- в строке поиска — только в нормальном режиме: в insert <leader> это обычный символ
    input = { keys = { ["<leader>dd"] = { "sql_deploy", desc = "выложить .sql (SqlDeploy)", mode = { "n" } } } },
  },
}

return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        -- dev перекрывает дефолт целиком, поэтому дефолтные каталоги повторяем
        projects = { dev = { "~/dev", "~/projects", "c:/repo" } },
        files = vim.tbl_deep_extend("force", vim.deepcopy(by_mtime), vim.deepcopy(deploy)),
        git_files = vim.tbl_deep_extend("force", vim.deepcopy(by_mtime), vim.deepcopy(deploy)),
        -- дефолт explorer рисует превью в узкой (40 колонок) панели под деревом;
        -- preview = "main" вместо неё показывает файл в главном окне редактора
        explorer = vim.tbl_deep_extend("force", { layout = { preview = "main" } }, vim.deepcopy(deploy)),
      },
    },
  },
}
