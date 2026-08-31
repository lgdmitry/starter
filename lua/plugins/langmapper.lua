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
local en = [[`qwfpbjluy;[]\arstgmneio'zxcdvkh,./]]
local en_shift = [[~QWFPBJLUY:{}|ARSTGMNEIO"ZXCDVKH<>?#]]
local ru = [[ёйцукенгшщзхъ\фывапролджэячсмитьбю.]]
local ru_shift = [[ЁЙЦУКЕНГШЩЗХЪ/ФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,№]]
local uk = [[ёйцукенгшщзхї\фівапролджєячсмитьбю.]]
local uk_shift = [[ЁЙЦУКЕНГШЩЗХЇ/ФІВАПРОЛДЖЄЯЧСМИТЬБЮ,№]]

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
