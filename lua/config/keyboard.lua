-- Раскладку переключает сама Windows: на выходе из insert принудительно ставим
-- английскую, на входе — возвращаем ту, из которой вышли.
--
-- Так дешевле, чем кириллические дубли маппингов, которыми занимался langmapper.nvim:
-- в normal-режиме кириллицы физически не бывает, поэтому LazyVim, which-key, LSP и
-- любой плагин, который заведёт клавишу завтра, работают нативно — дублировать нечего
-- и синхронизировать таблицы раскладок не с чем. Дубли же чинить было нечем: which-key
-- читает вторую клавишу последовательности своим vim.fn.getcharstr() (which-key/state.lua),
-- а точки расширения для нажатой клавиши у него нет вовсе — ни фильтра, ни хука; поиск
-- узла это индексирование таблицы (which-key/node.lua). Не найдя кириллицу, which-key
-- переигрывал всю последовательность через feedkeys уже без своих триггеров.
--
-- 'langmap' ниже при этом остаётся страховкой: PostMessage асинхронен, и клавиши,
-- попавшие в очередь терминала в первые миллисекунды после <Esc>, ещё транслируются
-- старой раскладкой. Он закрывает встроенные команды (hjkl, dd, ciw) — то есть ровно
-- то, что успевает проскочить; маппинги в этот зазор всё равно не попадают.

local M = {}

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
---«/» -> «|» убила бы поиск — причём в любой раскладке, потому что 'langmap' переводит
---сам символ, не зная, какая раскладка включена. Ничего при этом не теряется: такие
---клавиши и так дают ровно тот символ, который нужен vim.
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

local function set_langmap()
  local ru_from, ru_to = cyrillic_pairs(ru_shift .. ru, en_shift .. en)
  local uk_from, uk_to = cyrillic_pairs(uk_shift .. uk, en_shift .. en)

  -- Слева то, что нажато, справа — во что превратить.
  vim.opt.langmap = vim.fn.join({
    escape(ru_from) .. ";" .. escape(ru_to),
    escape(uk_from) .. ";" .. escape(uk_to),
  }, ",")
end

local WM_INPUTLANGCHANGEREQUEST = 0x0050
local EN_LANGID = 0x0409 -- младшее слово HKL = идентификатор языка; 0x0409 = en-US
local MAX_LAYOUTS = 16

local win -- ffi-хозяйство; false = не завелось, второй раз не пробуем
local saved -- HKL, снятый на выходе из insert
local known_en -- английская раскладка, которую видели активной (см. english_layout)
local focused = true -- окно nvim в фокусе (FocusLost/FocusGained)

---Всё общение с ffi — здесь и ровно один раз за сессию: любая ошибка навсегда
---превращает модуль в пустышку, а не роняет nvim на каждом InsertLeave.
local function api()
  if win ~= nil then
    return win or nil
  end
  win = false

  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil
  end

  -- cdef под pcall не «на всякий случай»: при перезагрузке модуля из-под отладки
  -- (package.loaded[...] = nil) повторное объявление тех же имён бросает
  -- "attempt to redefine", хотя типы уже объявлены и всё работает.
  pcall(
    ffi.cdef,
    [[
      typedef void* HKL;
      void* GetForegroundWindow(void);
      unsigned long GetWindowThreadProcessId(void* hWnd, unsigned long* lpdwProcessId);
      HKL GetKeyboardLayout(unsigned long idThread);
      int GetKeyboardLayoutList(int nBuff, HKL* lpList);
      int PostMessageA(void* hWnd, unsigned int Msg, uintptr_t wParam, uintptr_t lParam);
    ]]
  )

  local loaded, user32 = pcall(ffi.load, "user32")
  if not loaded then
    return nil
  end
  -- Пробный вызов: если cdef выше не прошёл, обращение к полю упало бы уже внутри
  -- автокоманды. Лучше узнать сейчас и выключиться молча.
  if not pcall(function()
    return user32.GetForegroundWindow()
  end) then
    return nil
  end

  win = {
    ffi = ffi,
    user32 = user32,
    -- буфер под список раскладок выделяем один раз: он живёт всю сессию и не
    -- плодит мусор на каждом переключении режима
    list = ffi.new("HKL[?]", MAX_LAYOUTS),
  }
  return win
end

---Идентификатор языка из HKL. Целиком HKL в число не переводим: реальный HKL приходит
---знакорасширенным (0xfffffffff0c20409), в double такое уже не лезет — отсюда остаток
---от деления над 64-битной cdata вместо tonumber.
local function langid(w, hkl)
  return tonumber(w.ffi.cast("uintptr_t", hkl) % 0x10000)
end

---Окно, которому шлём запрос, и поток, у которого спрашиваем текущую раскладку.
---Окно берём каждый раз заново: терминал мог смениться (alacritty, wt, conhost, neovide).
local function target()
  local w = api()
  if not w or not focused then
    return nil
  end
  local hwnd = w.user32.GetForegroundWindow()
  if hwnd == nil then
    return nil
  end
  local tid = w.user32.GetWindowThreadProcessId(hwnd, nil)
  if tid == 0 then
    return nil
  end
  return w, hwnd, tid
end

---HKL английской ищем перебором, а не LoadKeyboardLayoutA("00000409"): в системе стоят
---substitute-раскладки (HKCU\Keyboard Layout\Substitutes), и канонический 0x04090409,
---который вернёт LoadKeyboardLayout, не загружен вовсе — реально активен 0xf0c20409.
---Совпадает у них только младшее слово, по нему и ищем.
---
---Список перечитываем на каждом переключении, а не кэшируем: вызов стоит микросекунды,
---зато не приходится ловить протухший HKL после того, как раскладку переставили в
---параметрах Windows. Кэш тут дал бы именно тихий отказ: PostMessage всё равно вернёт
---успех (сообщение-то поставлено в очередь), просто адресат его проигнорирует.
---
---Раскладок с одним и тем же языком в списке может оказаться несколько: любая программа
---вправе подгрузить себе каноническую 0x04090409 рядом с нашей substitute-версией, и
---тогда «первая попавшаяся английская» — это чужая QWERTY вместо Colemak-DH. Поэтому
---предпочитаем ту, которую видели активной у самого пользователя (known_en), и всё
---равно сверяемся со списком: раскладку могли удалить в параметрах Windows.
local function english_layout(w)
  local n = w.user32.GetKeyboardLayoutList(MAX_LAYOUTS, w.list)
  local first
  for i = 0, n - 1 do
    if langid(w, w.list[i]) == EN_LANGID then
      if known_en and w.list[i] == known_en then
        return known_en
      end
      first = first or w.list[i]
    end
  end
  return first
end

---Переключаем не свою раскладку, а раскладку ОКНА С ФОКУСОМ, и именно сообщением.
---Консольный nvim клавиатуру не читает: физические нажатия транслирует поток окна
---терминала, и ActivateKeyboardLayout, меняющая раскладку вызывающего потока, не
---повлияла бы ни на что. Для GUI (neovide) прямой вызов тоже плох: система не получит
---WM_INPUTLANGCHANGE и индикатор языка в трее разойдётся с реальностью. У
---WM_INPUTLANGCHANGEREQUEST этим занимается DefWindowProc окна-получателя.
---
---PostMessage, а не SendMessage: окно чужого процесса, и SendMessage висел бы до тех
---пор, пока терминал не разберёт свою очередь, — то есть подвешивал бы nvim на <Esc>.
---
---wParam = 0 сознательно: INPUTLANGCHANGE_FORWARD/BACKWARD означают «следующая в
---списке» и lParam при них не при делах, а INPUTLANGCHANGE_SYSCHARSET просит систему
---сверить раскладку с ANSI-кодовой страницей и даёт ей право запрос отклонить.
local function post(w, hwnd, hkl)
  return w.user32.PostMessageA(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, w.ffi.cast("uintptr_t", hkl)) ~= 0
end

---Английская раскладка. remember = true — запомнить текущую, чтобы вернуть её на входе
---в insert. Запоминаем только на InsertLeave: раскладка, выбранная для /-поиска или для
---терминального буфера, не должна подменять ту, в которой печатали текст.
function M.english(remember)
  local w, hwnd, tid = target()
  if not w then
    return
  end
  local current = w.user32.GetKeyboardLayout(tid)
  if langid(w, current) == EN_LANGID then
    known_en = current -- вот этой английской человек и пользуется
    if remember then
      saved = nil -- печатали латиницей — возвращать нечего
    end
    return
  end
  if remember then
    saved = current
  end
  local en_hkl = english_layout(w)
  if en_hkl then
    post(w, hwnd, en_hkl)
  end
end

---Вернуть раскладку, из которой вышли. Если пользователь сам переключился в
---normal-режиме (искал кириллицу через /, например) — его выбор не перебиваем.
function M.restore()
  if saved == nil then
    return
  end
  local w, hwnd, tid = target()
  if not w then
    return
  end
  if langid(w, w.user32.GetKeyboardLayout(tid)) ~= EN_LANGID then
    return
  end
  post(w, hwnd, saved)
end

---Ничего не переключает — показывает, что модуль видит. Для проверки вживую:
---:lua vim.print(require("config.keyboard").debug())
function M.debug()
  local w, hwnd, tid = target()
  if not w then
    return { enabled = api() ~= nil, focused = focused }
  end
  -- Печатаем младшие 32 бита: HKL значим ровно в них, а целиком через tonumber его не
  -- показать — знакорасширенное значение не влезает в double и округляется (0x...0409
  -- превращается в 0x...0800).
  local hex = function(hkl)
    if not hkl then
      return nil
    end
    local u = w.ffi.cast("uintptr_t", hkl)
    return string.format("0x%04x%04x", tonumber(u / 0x10000 % 0x10000), tonumber(u % 0x10000))
  end
  local list = {}
  local n = w.user32.GetKeyboardLayoutList(MAX_LAYOUTS, w.list)
  for i = 0, n - 1 do
    list[i + 1] = hex(w.list[i])
  end
  return {
    hwnd = tostring(hwnd),
    tid = tonumber(tid),
    current = hex(w.user32.GetKeyboardLayout(tid)),
    english = hex(english_layout(w)),
    known_english = hex(known_en),
    list = list,
    saved = hex(saved),
    focused = focused,
  }
end

function M.setup()
  set_langmap()

  -- Вне Windows переключать нечего: ни ffi, ни автокоманд.
  if vim.fn.has("win32") ~= 1 then
    return
  end

  local group = vim.api.nvim_create_augroup("keyboard_layout", { clear = true })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    desc = "Запомнить раскладку и переключиться на английскую",
    callback = function()
      M.english(true)
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    desc = "Вернуть раскладку, в которой печатали",
    callback = function()
      M.restore()
    end,
  })

  -- CmdlineLeave: искать кириллицу через / — законный повод её включить, но в
  -- normal-режим она утечь не должна. CmdlineEnter не нужен: в normal раскладка уже
  -- английская, а форсировать её на входе значило бы гоняться с самим пользователем,
  -- который нажал / и переключается на русский.
  -- TermLeave: терминальный буфер InsertLeave не даёт. Обратного переключения на
  -- TermEnter нет сознательно — в shell и lazygit команды латинские.
  vim.api.nvim_create_autocmd({ "CmdlineLeave", "TermLeave" }, {
    group = group,
    desc = "Английская раскладка на выходе из cmdline и терминала",
    callback = function()
      M.english(false)
    end,
  })

  -- Без флага фокуса автокоманда, выстрелившая по скрипту при неактивном nvim
  -- (форматтер, макрос, плагин, выходящий из insert), переключила бы раскладку в
  -- ЧУЖОМ приложении: GetForegroundWindow вернёт его окно.
  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    desc = "Не трогать раскладку чужого окна",
    callback = function()
      focused = false
    end,
  })

  -- Windows умеет держать раскладку одну на всю систему, а не на окно: тогда
  -- переключение в чужом окне протекает к нам, и после Alt-Tab normal-режим окажется
  -- кириллическим. Проверка режима обязательна: фокус мог вернуться прямо в insert.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "Вернулись в nvim: в командных режимах раскладка должна быть английской",
    callback = function()
      focused = true
      local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
      if mode ~= "i" and mode ~= "R" and mode ~= "t" and mode ~= "c" then
        M.english(false)
      end
    end,
  })

  -- nvim стартует в normal-режиме, а раскладка при запуске какая угодно.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    desc = "Английская раскладка на старте",
    callback = function()
      vim.schedule(function()
        M.english(false)
      end)
    end,
  })
end

return M
