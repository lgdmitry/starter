-- Настройки GUI-клиента Neovide. В терминале (Alacritty) модуль ничего не делает:
-- vim.g.neovide Neovide выставляет сам, до загрузки init.lua.
local M = {}

---Шаг зума: множитель, а не прибавка, чтобы каждое нажатие меняло размер заметно
---одинаково и на мелком, и на крупном шрифте.
local ZOOM_STEP = 1.1

local function zoom(factor)
  vim.g.neovide_scale_factor = factor and vim.g.neovide_scale_factor * factor or 1.0
end

function M.setup()
  if not vim.g.neovide then
    return
  end

  -- Тот же шрифт и кегль, что в alacritty.toml, чтобы переход между ними не бил по глазам.
  vim.o.guifont = "JetBrainsMono NF:h15"

  -- Никаких анимаций: любая из них — это кадры, в которые на экране ещё не то, что уже
  -- в буфере, то есть ощущаемая задержка ввода. Та же причина, что у snacks_animate
  -- в options.lua. Нули, а не мелкие значения: при нуле Neovide рисует сразу итог.
  vim.g.neovide_cursor_animation_length = 0
  vim.g.neovide_cursor_trail_size = 0
  vim.g.neovide_cursor_animate_in_insert_mode = false
  vim.g.neovide_cursor_animate_command_line = false
  vim.g.neovide_cursor_vfx_mode = ""
  vim.g.neovide_scroll_animation_length = 0
  vim.g.neovide_scroll_animation_far_lines = 0
  vim.g.neovide_position_animation_length = 0

  -- Размытие и тени под плавающими окнами — лишние проходы GPU на каждый кадр с
  -- float (пикеры snacks, which-key, hover) и ничего не дают, кроме вида.
  vim.g.neovide_floating_blur_amount_x = 0
  vim.g.neovide_floating_blur_amount_y = 0
  vim.g.neovide_floating_shadow = false

  vim.g.neovide_hide_mouse_when_typing = true

  -- Окна Neovide для dgsql и esql в Alt+Tab и на панели задач иначе оба называются
  -- «Neovide». Ярлык задаёт только рабочую папку, по ней и различаем — как title в
  -- профилях Alacritty.
  vim.o.title = true
  vim.o.titlestring = "Neovim · %{fnamemodify(getcwd(), ':t')}"

  vim.keymap.set("n", "<C-=>", function()
    zoom(ZOOM_STEP)
  end, { desc = "Zoom in (Neovide)" })
  vim.keymap.set("n", "<C-->", function()
    zoom(1 / ZOOM_STEP)
  end, { desc = "Zoom out (Neovide)" })
  vim.keymap.set("n", "<C-0>", function()
    zoom()
  end, { desc = "Reset zoom (Neovide)" })

  vim.keymap.set("n", "<F11>", function()
    vim.g.neovide_fullscreen = not vim.g.neovide_fullscreen
  end, { desc = "Toggle fullscreen (Neovide)" })

  -- В Alacritty Ctrl+Shift+V вставляет сам терминал. У GUI терминала нет, и без этого
  -- вставить из системного буфера в insert, командную строку и :terminal было бы нечем.
  -- В normal вставка и так идёт из системного буфера: LazyVim ставит clipboard=unnamedplus.
  vim.keymap.set({ "i", "c" }, "<C-S-v>", "<C-r>+", { desc = "Paste from clipboard (Neovide)" })
  vim.keymap.set("t", "<C-S-v>", function()
    vim.api.nvim_paste(vim.fn.getreg("+"), true, -1)
  end, { desc = "Paste from clipboard (Neovide)" })
end

return M
