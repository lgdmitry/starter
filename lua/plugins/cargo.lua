return {
  {
    "nwiizo/cargo.nvim",
    build = "cargo build --release",
    config = function()
      require("cargo").setup({
        -- Window settings
        float_window = true, -- Use floating window
        window_width = 0.8, -- Window width (80% of editor width)
        window_height = 0.8, -- Window height (80% of editor height)
        border = "rounded", -- Border style ("none", "single", "double", "rounded")
        wrap_output = true, -- Enable text wrapping in output window
        show_line_numbers = true, -- Show line numbers in output window
        show_cursor_line = true, -- Highlight current line in output window

        -- Auto-close settings
        auto_close = true, -- Auto close window on success
        close_timeout = 5000, -- Close window after 5000ms

        -- Timeout settings
        run_timeout = 300, -- Timeout for cargo run in seconds
        interactive_timeout = 30, -- Inactivity timeout for interactive mode

        -- Advanced behavior options
        force_interactive_run = true, -- Always treat cargo run as interactive mode
        max_inactivity_warnings = 3, -- Maximum number of inactivity warnings before termination
        detect_proconio = true, -- Enable detection of proconio usage
        force_smart_detection = true, -- Always use smart detection for interactive programs

        -- Key mappings (customizable)
        keymaps = {
          close = "q",
          scroll_up = "<C-u>",
          scroll_down = "<C-d>",
          scroll_top = "gg",
          scroll_bottom = "G",
          interrupt = "<C-c>",
          toggle_wrap = "w",
          copy_output = "y",
          clear_output = "c",
        },
      })
    end,
    ft = { "rust" },
    cmd = {
      "CargoBench",
      "CargoBuild",
      "CargoClean",
      "CargoDoc",
      "CargoNew",
      "CargoRun",
      "CargoRunTerm",
      "CargoTest",
      "CargoUpdate",
      "CargoCheck",
      "CargoClippy",
      "CargoAdd",
      "CargoRemove",
      "CargoFmt",
      "CargoFix",
    },
  },
}
