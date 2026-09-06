-- Множественные курсоры (jake-stewart/multicursor.nvim).
--
-- Раскладка клавиш — не дефолт из readme плагина: там specific-мэтчинг курсоров
-- висит на bare <leader>n/<leader>s/<leader>x, а в этом конфиге это чужие клавиши
-- (LazyVim: notifications, группа +search, группа +diagnostics/quickfix). Поэтому
-- вся специфика multicursor уведена под группу <leader>m (см. plugins/which-key.lua).
--
-- Ctrl+Alt+<буква> НЕ используем: на многих раскладках (в т.ч. ru/uk) это то же
-- самое, что AltGr — комбинация ловится драйвером клавиатуры ещё до терминала и
-- либо не долетает до nvim, либо превращается в случайный юникод-символ. Это
-- касается только букв/символов — Ctrl+Alt+стрелка безопасен (AltGr работает
-- только с буквенно-символьными клавишами), поэтому он и оставлен ниже как
-- рабочий дубль для строчного add/skip.
return {
  {
    "jake-stewart/multicursor.nvim",
    branch = "1.0",
    config = function()
      local mc = require("multicursor-nvim")
      mc.setup()

      local set = vim.keymap.set

      -- Строка выше/ниже. <up>/<down> тут не годятся: LazyVim переопределяет их
      -- (и j/k) на gj/gk в lazyvim/config/keymaps.lua и накатывает это ПОСЛЕ
      -- конфига любого плагина — тот же случай гонки, что с K/hover в
      -- plugins/dadbod.lua. Ctrl+Alt+стрелка — рабочий дубль, независимый от layout.
      set({ "n", "x" }, "<leader>mj", function()
        mc.lineAddCursor(1)
      end, { desc = "Курсор строкой ниже" })
      set({ "n", "x" }, "<leader>mk", function()
        mc.lineAddCursor(-1)
      end, { desc = "Курсор строкой выше" })
      set({ "n", "x" }, "<c-a-down>", function()
        mc.lineAddCursor(1)
      end, { desc = "Курсор строкой ниже" })
      set({ "n", "x" }, "<c-a-up>", function()
        mc.lineAddCursor(-1)
      end, { desc = "Курсор строкой выше" })
      set({ "n", "x" }, "<leader>mJ", function()
        mc.lineSkipCursor(1)
      end, { desc = "Пропустить строку ниже" })
      set({ "n", "x" }, "<leader>mK", function()
        mc.lineSkipCursor(-1)
      end, { desc = "Пропустить строку выше" })

      -- Добавить/пропустить курсор по совпадению слова под курсором (или выделения).
      set({ "n", "x" }, "<leader>mn", function()
        mc.matchAddCursor(1)
      end, { desc = "Курсор на след. совпадение" })
      set({ "n", "x" }, "<leader>mN", function()
        mc.matchAddCursor(-1)
      end, { desc = "Курсор на пред. совпадение" })
      set({ "n", "x" }, "<leader>ms", function()
        mc.matchSkipCursor(1)
      end, { desc = "Прыжок на след. совпадение (без курсора)" })
      set({ "n", "x" }, "<leader>mS", function()
        mc.matchSkipCursor(-1)
      end, { desc = "Прыжок на пред. совпадение (без курсора)" })
      set(
        { "n", "x" },
        "<leader>mA",
        mc.matchAllAddCursors,
        { desc = "Курсор на все совпадения в файле" }
      )

      -- Курсор на каждую строку абзаца или визуального выделения.
      set(
        { "n", "x" },
        "ga",
        mc.addCursorOperator,
        { desc = "Курсор на каждую строку (текстовый объект)" }
      )

      -- Курсор в каждое совпадение regex внутри текстового объекта,
      -- например `<leader>moiwap` — по каждому вхождению слова внутри абзаца.
      set(
        { "n", "x" },
        "<leader>mo",
        mc.operator,
        { desc = "Курсор по regex внутри текстового объекта" }
      )

      -- Мышь: ctrl+клик добавляет/убирает курсор, ctrl+тащить — выделение.
      set("n", "<c-leftmouse>", mc.handleMouse, { desc = "Курсор мышью (ctrl+клик)" })
      set("n", "<c-leftdrag>", mc.handleMouseDrag, { desc = "Курсор мышью (ctrl+тащить)" })
      set("n", "<c-leftrelease>", mc.handleMouseRelease, { desc = "Курсор мышью (ctrl+отпустить)" })

      -- Временно отключить лишние курсоры — двигается только главный;
      -- повторное нажатие в отключённом состоянии добавляет курсор под ним.
      set(
        { "n", "x" },
        "<c-q>",
        mc.toggleCursor,
        { desc = "Включить/выключить лишние курсоры" }
      )

      set("n", "<leader>ma", mc.alignCursors, { desc = "Выровнять курсоры по колонкам" })
      set("n", "<leader>mv", mc.restoreCursors, { desc = "Вернуть сброшенные курсоры" })
      set("x", "S", mc.splitCursors, { desc = "Разбить выделение по regex" })
      set("x", "M", mc.matchCursors, { desc = "Курсор на совпадения regex в выделении" })
      set(
        "x",
        "I",
        mc.insertVisual,
        { desc = "Вставка в начало каждой строки выделения" }
      )
      set(
        "x",
        "A",
        mc.appendVisual,
        { desc = "Вставка в конец каждой строки выделения" }
      )

      -- Маппинги внутри слоя действуют, только пока курсоров больше одного —
      -- поэтому можно занимать обычные клавиши без конфликта с их обычным смыслом.
      -- В отличие от <leader>mj/mk выше, здесь j/k не воюют с lazyvim/config/keymaps.lua:
      -- слой навешивается буферно-локально уже во время работы, а не при старте,
      -- так что побеждает он. Итог: <leader>mj один раз, дальше просто j/k построчно.
      mc.addKeymapLayer(function(layerSet)
        layerSet({ "n", "x" }, "j", function()
          mc.lineAddCursor(1)
        end, { desc = "Курсор строкой ниже" })
        layerSet({ "n", "x" }, "k", function()
          mc.lineAddCursor(-1)
        end, { desc = "Курсор строкой выше" })
        layerSet({ "n", "x" }, "<left>", mc.prevCursor, { desc = "Предыдущий курсор главным" })
        layerSet({ "n", "x" }, "<right>", mc.nextCursor, { desc = "Следующий курсор главным" })
        layerSet({ "n", "x" }, "<leader>mx", mc.deleteCursor, { desc = "Удалить текущий курсор" })

        -- K (hover/:SqlDef, см. plugins/dadbod.lua) иначе реплицируется на каждый
        -- курсор через feedkeys — в sql-буфере это значит один sqlcmd на курсор.
        layerSet(
          { "n", "x" },
          "K",
          function() end,
          { desc = "Отключено, пока курсоров больше одного" }
        )

        layerSet("n", "<esc>", function()
          if not mc.cursorsEnabled() then
            mc.enableCursors()
          else
            mc.clearCursors()
          end
        end, { desc = "Включить курсоры / схлопнуть в один" })
      end)

      local hl = vim.api.nvim_set_hl
      hl(0, "MultiCursorCursor", { reverse = true })
      hl(0, "MultiCursorVisual", { link = "Visual" })
      hl(0, "MultiCursorSign", { link = "SignColumn" })
      hl(0, "MultiCursorMatchPreview", { link = "Search" })
      hl(0, "MultiCursorDisabledCursor", { reverse = true })
      hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
      hl(0, "MultiCursorDisabledSign", { link = "SignColumn" })
    end,
  },
}
