-- Подсказки which-key: кириллические дубли не скрываем, но показываем последними.
--
-- langmapper каждому маппингу заводит кириллический дубль (см. plugins/langmapper.lua),
-- и раньше они выбрасывались из подсказок фильтром по не-ASCII байтам. Так делать
-- нельзя: opts.filter вызывается при построении дерева (which-key/tree.lua), а не при
-- отрисовке, поэтому which-key о дублях не знал вовсе. Нажатие кириллической клавиши
-- после <leader> в дереве не находилось, which-key закрывал окно и скармливал
-- <leader>+клавишу обратно через feedkeys (which-key/state.lua) — остаток
-- последовательности приходилось добирать за timeoutlen (300мс) и уже без подсказок.
-- Успел — команда сработала, задумался — префикс выброшен: ровно то, что выглядело
-- как «на русской раскладке leader работает через раз».
--
-- Дерево теперь полное, а список не смешивается: своё правило сортировки уводит всё
-- с не-ASCII байтами в конец, поэтому сверху идут привычные латинские варианты.
-- sort принимает не только имена встроенных полей, но и функцию (which-key/view.lua).
--
-- Исключение — <leader>w и <leader>b (lazyvim/plugins/editor.lua): это which-key
-- group-узлы с proxy/expand, а не обычные маппинги, и automapping их не дублирует
-- (см. plugins/langmapper.lua). Для <leader>w (кириллический дубль "<leader>ц")
-- там заведены настоящие vim.keymap.set на нужные <c-w>-команды — which-key сам
-- строит из них рабочую группу, proxy в обход не участвует. Для <leader>b
-- (дубль "<leader>е") proxy и не нужен был: это просто открытие попапа с
-- цифровым списком буферов, цифры одинаковы в любой раскладке — но открывающий
-- keymap там всё равно с desc = "which_key_ignore" (which-key прячет такие узлы
-- из дерева сам, tree.lua), отдельный filter тут не нужен.
--
-- Группа <leader>d: у LazyVim это debug, но extra с dap не подключён, так что группа
-- пустая — занимаем её под свой SQL-слой (:SqlDeploy, :SqlQuery и прочее). Дописываем
-- в конец opts.spec, а не задаём spec целиком: списки при слиянии заменяются, и мы бы
-- снесли все остальные имена групп LazyVim.
return {
  "folke/which-key.nvim",
  opts = function(_, opts)
    opts.sort = {
      function(item)
        return item.key:find("[\128-\255]") and 1 or 0
      end,
      "local",
      "order",
      "group",
      "alphanum",
      "mod",
    }

    opts.spec = opts.spec or {}
    table.insert(opts.spec, { "<leader>d", group = "sql" })
    table.insert(opts.spec, { "<leader>ц", group = "windows" })
    table.insert(opts.spec, { "<leader>m", group = "multicursor" })
  end,
}
