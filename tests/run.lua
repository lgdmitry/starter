-- Раннер спеков без плагинов: busted/plenary ради пары десятков проверок тянуть не
-- стоит, а под -u NONE их всё равно нет.
--
--   "C:/Program Files/Neovim/bin/nvim.exe" --headless -u NONE -l C:/Users/<user>/AppData/Local/nvim/tests/run.lua [фильтр]
--
-- -u NONE обязателен: с конфигом lazy.nvim на старте может доставить плагины и
-- переписать lazy-lock.json. Фильтр — подстрока имени файла спека.

local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")

local t = require("helpers")
local filter = arg and arg[1]

local specs = vim.fn.glob(root .. "/tests/sql/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  if not filter or spec:find(filter, 1, true) then
    t.file(vim.fs.basename(spec))
    local ok, err = pcall(dofile, spec)
    if not ok then
      t.fail_file(err)
    end
  end
end

os.exit(t.report() and 0 or 1)
