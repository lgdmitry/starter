-- Extra ai.copilot поднимает подсказки copilot над всем остальным (score_offset = 100), и
-- они заслоняют сниппет, имя которого набрано целиком: его хотели развернуть, а первым
-- стоит длинное предложение copilot. Опускать сам copilot смещением нельзя — в blink
-- место определяется нечётким счётом плюс смещение источника, и copilot тогда уходит под
-- всё, вплоть до слов из буфера. Поэтому copilot оставляем наверху, а сниппеты с точным
-- совпадением (item.exact: набранное слово == label) ставим перед всеми отдельной
-- сортировкой, до счёта.
local function exact_snippet_first(a, b)
  local ea = a.exact and a.source_id == "snippets"
  local eb = b.exact and b.source_id == "snippets"
  if ea ~= eb then
    return ea
  end
end

return {
  "saghen/blink.cmp",
  optional = true,
  opts = function(_, opts)
    opts.fuzzy = opts.fuzzy or {}
    opts.fuzzy.sorts = vim.list_extend({ exact_snippet_first }, opts.fuzzy.sorts or { "score", "sort_text" })
  end,
}
