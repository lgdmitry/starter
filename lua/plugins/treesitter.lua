-- regex просит Snacks picker (подсветка поисковых запросов) — без него
-- :checkhealth snacks пишет "Missing Treesitter languages: regex".
return {
  "nvim-treesitter/nvim-treesitter",
  opts = { ensure_installed = { "regex" } },
}
