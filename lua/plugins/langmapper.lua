-- Русская и украинская раскладки: команды работают, не переключая язык.
--
-- Двумя частями, потому что одной не выходит:
--   'langmap' переводит клавиши для встроенных команд (dd, ciw, hjkl) — этого хватает
--   для всего, что зашито в сам vim, но маппинги он не трогает: <leader>ff, gd от LSP,
--   gcc и прочее ищутся по тому, что реально нажато, и с кириллицей не находятся;
--   langmapper.nvim подменяет vim.keymap.set и регистрирует каждому маппингу
--   кириллический вариант — в том числе для плагинов, которые грузятся позже.
--
-- Таблица снята с раскладок, которые стоят в системе (ToUnicodeEx по скан-кодам):
--   A0020409  United States - Colemak-DH Matrix
--   A0000419  Русская (Colemak)      — кириллица разложена под Colemak, не под ЙЦУКЕН
--   A0000422  Ukrainian - DH
-- Поэтому пары не такие, как в любом примере из интернета: d — это «м» (клавиша QWERTY
-- «v»), а не «в». Если раскладки поменяются, таблицу надо снять заново, иначе всё
-- разъедется. Строки одинаковой длины, символ в символ по одной и той же клавише.
--
-- 2026-09-01: Ukrainian - DH пересобрана — её первая клавиша (QWERTY «`») даёт
-- теперь ' и ₴ вместо ё и Ё, как в штатной 00020422. Апостроф ASCII, поэтому пара
-- ' -> ` отбрасывается ниже: иначе перевод сломал бы ' во всех раскладках сразу.
local en = [[`qwfpbjluy;[]\arstgmneio'zxcdvkh,./]]
local en_shift = [[~QWFPBJLUY:{}|ARSTGMNEIO"ZXCDVKH<>?#]]
local ru = [[ёйцукенгшщзхъ\фывапролджэячсмитьбю.]]
local ru_shift = [[ЁЙЦУКЕНГШЩЗХЪ/ФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,№]]
local uk = [['йцукенгшщзхї\фівапролджєячсмитьбю.]]
local uk_shift = [[₴ЙЦУКЕНГШЩЗХЇ/ФІВАПРОЛДЖЄЯЧСМИТЬБЮ,№]]

---Пары «нажато -> латиница», в которых нажатое не ASCII.
---Пары с ASCII слева выбрасываем, и это не мелочь: в русской раскладке «.» стоит на
---клавише «/», а «/» — на «\». Пара «.» -> «/» превратила бы повтор в поиск, а
---«/» -> «|» убила бы поиск — причём в любой раскладке, потому что и 'langmap', и
---langmapper переводят сам символ, не зная, какая раскладка включена. Ничего при этом
---не теряется: такие клавиши и так дают ровно тот символ, который нужен vim.
local function cyrillic_pairs(from, to)
  local from_chars, to_chars = vim.fn.split(from, "\\zs"), vim.fn.split(to, "\\zs")
  local left, right = {}, {}
  for i, char in ipairs(from_chars) do
    if #char > 1 then -- многобайтный символ = не ASCII
      left[#left + 1] = char
      right[#right + 1] = to_chars[i]
    end
  end
  return table.concat(left), table.concat(right)
end

---В 'langmap' запятая, точка с запятой и обратный слэш разделяют части — экранируем.
local function escape(str)
  return vim.fn.escape(str, [[;,."|\]])
end

local ru_from, ru_to = cyrillic_pairs(ru_shift .. ru, en_shift .. en)
local uk_from, uk_to = cyrillic_pairs(uk_shift .. uk, en_shift .. en)

-- Слева то, что нажато, справа — во что превратить.
vim.opt.langmap = vim.fn.join({
  escape(ru_from) .. ";" .. escape(ru_to),
  escape(uk_from) .. ";" .. escape(uk_to),
}, ",")

return {
  "Wansmer/langmapper.nvim",
  lazy = false,
  priority = 1000, -- раньше остальных: подмена vim.keymap.set должна успеть до их маппингов
  opts = {
    use_layouts = { "ru", "uk" },
    -- те же пары, что и в langmap: раскладка и её английский оригинал
    layouts = {
      ru = { id = "ru", default_layout = ru_to, layout = ru_from },
      uk = { id = "uk", default_layout = uk_to, layout = uk_from },
    },
  },
  config = function(_, opts)
    require("langmapper").setup(opts)

    -- <leader>w и <leader>b (lazyvim/plugins/editor.lua) — не обычные маппинги,
    -- а which-key group-узлы: expand строит числовой список текущих окон/буферов
    -- (which-key/extras.lua, M.expand.win/.buf — цифры 0-9, они одинаковы в любой
    -- раскладке), а <leader>w вдобавок proxy = "<c-w>": любая непойманная клавиша
    -- пересылается как <c-w>+клавиша. Реального vim.keymap.set для "<leader>w"/
    -- "<leader>b" на момент automapping ещё нет — which-key заводит его позже и
    -- динамически, per-buffer (which-key/triggers.lua). Дублировать нечего.
    --
    -- Открыть сам попап под кириллицей — не проблема: which-key/triggers.lua
    -- заводит настоящий <leader>w как
    --   vim.keymap.set(mode, "<leader>w", function()
    --     require("which-key.state").start({ keys = "<leader>w" })
    --   end, ...)
    -- и это же можно вызвать напрямую. Проблема — дальше: which-key читает
    -- ВТОРУЮ клавишу (после <leader>w) через свой vim.fn.getcharstr(), а это
    -- Lua-примитив, до которого перевод 'langmap' не долетает (langmap работает
    -- на уровне обработки команд самого vim, см. шапку файла). Не найдя узел
    -- под сырой кириллической буквой, which-key сдаётся и переигрывает ВСЮ
    -- последовательность через feedkeys — но свои триггеры на "<leader>" и
    -- "<leader>w" к этому моменту уже снял (иначе поймал бы то же самое по
    -- кругу), так что голые <Space> и "w" отрабатывают как встроенные команды
    -- (движение вправо, слово вперёд) — то есть каша, а не нужная команда окна.
    -- Проверено вживую (which-key/wk.log, opts.debug = true) — воспроизводится
    -- стабильно что для "<leader>w" (proxy), что для "<leader>b" (expand).
    --
    -- Чинить сам proxy незачем: вместо этого заводим настоящие vim.keymap.set
    -- на нужные <c-w>-команды под "<leader>ц" (кириллический дубль "w") —
    -- заведомо латинские буквы после <c-w>, remap = true как и в родном
    -- lazyvim/config/keymaps.lua:201 ("<leader>wd" = "<C-W>c"). Для реального
    -- keymap which-key сам построит рабочую группу без proxy — и заодно
    -- подхватит уже существующие кириллические дубли настоящих LazyVim-маппингов
    -- (<leader>цd, <leader>цm — automapping их и так дублирует, это обычные
    -- vim.keymap.set, а не proxy/expand).
    --
    -- Буквы берём из тех же en/ru/uk (см. шапку файла) — не печатаем кириллицу
    -- руками, чтобы не разъехаться с langmap при следующей смене раскладки.
    local en_chars, ru_chars = vim.fn.split(en, "\\zs"), vim.fn.split(ru, "\\zs")
    local latin_to_cyr = {}
    for i, latin in ipairs(en_chars) do
      latin_to_cyr[latin] = ru_chars[i]
    end
    local win_cmds = {
      h = "Window left",
      j = "Window down",
      k = "Window up",
      l = "Window right",
      s = "Split window below",
      v = "Split window right",
      o = "Close other windows",
      w = "Other window",
      p = "Previous window",
      x = "Swap window",
    }
    for latin, desc in pairs(win_cmds) do
      local cyr = latin_to_cyr[latin]
      if cyr then
        vim.keymap.set({ "n", "x" }, "<leader>ц" .. cyr, "<C-w>" .. latin, { remap = true, desc = desc })
      end
    end

    -- <leader>b (буферный список) остаётся как есть: пересылки нет вовсе,
    -- expand.buf() даёт только цифровые пункты — открыть попап напрямую
    -- достаточно, дальше цифры работают в любой раскладке без перевода.
    vim.keymap.set({ "n", "x" }, "<leader>е", function()
      require("which-key.state").start({ keys = (vim.g.mapleader or "\\") .. "b" })
    end, { desc = "which_key_ignore" })

    -- Маппинги, расставленные до загрузки плагина (дефолты nvim, keymaps самого
    -- LazyVim на VeryLazy), подмена уже не поймала — добираем их разом.
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      desc = "Кириллические варианты для уже расставленных маппингов",
      callback = function()
        -- schedule, чтобы не гадать о порядке обработчиков VeryLazy: свои клавиши
        -- LazyVim расставляет там же
        vim.schedule(function()
          require("langmapper").automapping({ global = true, buffer = true })
        end)
      end,
    })
  end,
}
