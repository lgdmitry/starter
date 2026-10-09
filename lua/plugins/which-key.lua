-- Группа <leader>d: у LazyVim это debug, но extra с dap не подключён, так что группа
-- пустая — занимаем её под свой SQL-слой (:SqlDeploy, :SqlQuery и прочее). Дописываем
-- в конец opts.spec, а не задаём spec целиком: списки при слиянии заменяются, и мы бы
-- снесли все остальные имена групп LazyVim.
--
-- Иконки задаём явно: which-key подбирает их по правилам на английские слова в описании
-- ("debug", "file", ...), а у наших маппингов описания русские. Сами маппинги заданы в
-- других местах, здесь только иконки к ним. real = true: без него which-key показывал бы
-- пункт и там, где маппинга нет, — а часть из них буферные (K/gf/<leader>df в sql, <leader>dx в
-- буфере запроса, <leader>mx только при нескольких курсорах).
local function icon(glyph, color)
  return { icon = glyph, color = color }
end

-- Окно which-key открывает его буферный триггер <Space> с nowait. Но nowait срабатывает,
-- только если триггер задан позже остальных буферных маппингов на <Space>… (:h map-nowait).
-- LazyVim ставит LSP-маппинги (<leader>c…) через 100 мс после LspAttach, когда which-key
-- уже пересобрал триггеры. Тогда Vim ждёт продолжения, сочетание срабатывает напрямую, а
-- окна нет. Поэтому после каждого буферного маппинга сбрасываем кэш which-key для этого
-- буфера: он пересобирается (для текущего буфера — по своему таймеру в 50 мс, для
-- остальных — на BufEnter) и ставит триггеры заново, уже после маппинга. Перехватываем
-- vim.keymap.set: хука на «появился маппинг» нет, а маппинги ставят и LazyVim, и наш
-- SQL-слой, и плагины.
local function refresh_on_buffer_maps()
  local pending = {}
  local set = vim.keymap.set
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(mode, lhs, rhs, opts)
    set(mode, lhs, rhs, opts)
    local buf = opts and opts.buffer
    -- триггеры which-key ставит этой же функцией — на них не реагируем, иначе цикл
    if not buf or (opts.desc or ""):find("which-key-trigger", 1, true) then
      return
    end
    buf = (buf == true or buf == 0) and vim.api.nvim_get_current_buf() or buf
    if pending[buf] then
      return
    end
    -- LazyVim ставит маппинги пачкой — сбрасываем один раз на всю пачку
    pending[buf] = true
    vim.schedule(function()
      pending[buf] = nil
      if package.loaded["which-key"] and vim.api.nvim_buf_is_valid(buf) then
        require("which-key.buf").clear({ buf = buf })
      end
    end)
  end
end

return {
  "folke/which-key.nvim",
  init = refresh_on_buffer_maps,
  opts = function(_, opts)
    opts.spec = opts.spec or {}
    table.insert(opts.spec, {
      mode = { "n", "x" },
      real = true,
      -- mode включает x, иначе в visual группа видна без имени, хотя маппинги там есть.
      { "<leader>d", group = "sql", icon = { cat = "filetype", name = "sql" }, real = false },
      { "<leader>dd", icon = icon("󰕒", "azure") },
      { "<leader>dD", icon = icon("󰕒", "azure") },
      { "<leader>dq", icon = icon("󰆼", "azure") },
      { "<leader>dQ", icon = icon("󰆼", "azure") },
      { "<leader>dt", icon = icon("󰆓", "azure") },
      { "<leader>dT", icon = icon("󰆓", "azure") },
      { "<leader>ds", icon = icon("󰒍", "yellow") },
      { "<leader>dx", icon = icon("󰐊", "green") },
      { "<leader>dr", icon = icon("󰓫", "cyan") },
      { "<leader>de", icon = icon("󰉻", "cyan") },
      { "<leader>du", icon = icon("󰍉", "green") },
      { "<leader>dU", icon = icon("󰍉", "green") },
      { "<leader>do", icon = icon("󰈝", "green") },
      { "<leader>dc", icon = icon("󰓛", "red") },
      { "<leader>di", icon = icon("󰋼", "cyan") },
      { "<leader>df", icon = icon("󰉼", "yellow") },
      { "gK", icon = icon("󰅩", "azure") },
      { "gf", icon = icon("󰈮", "cyan") },

      { "<leader>m", group = "multicursor", icon = icon("󰗧", "purple"), real = false },
      { "<leader>mj", icon = icon("󰁅", "purple") },
      { "<leader>mk", icon = icon("󰁝", "purple") },
      { "<leader>mJ", icon = icon("󰒭", "grey") },
      { "<leader>mK", icon = icon("󰒮", "grey") },
      { "<leader>mn", icon = icon("󰐕", "purple") },
      { "<leader>mN", icon = icon("󰐕", "purple") },
      { "<leader>ms", icon = icon("󰅂", "grey") },
      { "<leader>mS", icon = icon("󰅁", "grey") },
      { "<leader>mA", icon = icon("󰒆", "purple") },
      { "<leader>mo", icon = icon("󰑑", "purple") },
      { "<leader>ma", icon = icon("󰉢", "purple") },
      { "<leader>mv", icon = icon("󰦛", "purple") },
      { "<leader>mx", icon = icon("󰅖", "red") },
      { "ga", icon = icon("󰉹", "purple") },

      { "<leader>y", group = "yank path", icon = icon("󰆏", "yellow"), real = false },
      { "<leader>yp", icon = icon("󰙅", "yellow") },
      { "<leader>yP", icon = icon("󰉋", "yellow") },
      { "<leader>yf", icon = icon("󰈔", "yellow") },
      { "<leader>fS", icon = icon("󰆓", "cyan") },
    })
  end,
}
