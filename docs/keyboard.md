# Keyboard layout

Not a plugin: `lua/config/keyboard.lua`, wired from `lua/config/options.lua`
(not from `autocmds.lua` — that one loads on VeryLazy, i.e. after `VimEnter`). It
forces the Windows layout back to English on `InsertLeave` and restores the one you
typed in on `InsertEnter`, by posting `WM_INPUTLANGCHANGEREQUEST` to the foreground
window through LuaJIT's FFI (`user32`). `ActivateKeyboardLayout` would do nothing
here: a console nvim does not read the keyboard, the terminal's window thread does.
The English `HKL` is found by scanning `GetKeyboardLayoutList` for language id
`0x0409` — `LoadKeyboardLayoutA` returns a canonical handle that is not the one
actually loaded, because the installed layouts are substitutes (`a0020409`,
`a0000419`, `a0000422`).

Normal mode is therefore always latin, so **do not add cyrillic duplicates of
mappings**. That is what `langmapper.nvim` used to do, and which-key cannot be made
to work with them: it reads the second key of a sequence through its own
`vim.fn.getcharstr()` and has no extension point for the pressed key, so an unknown
cyrillic key makes it replay the whole sequence through `feedkeys` — with its own
triggers already removed.

`'langmap'` is still set (tables taken off the three installed layouts with
`ToUnicodeEx`), but only as a safety net: `PostMessage` is asynchronous, so keys the
terminal queued in the first milliseconds after `<Esc>` are still translated with the
old layout. It covers built-in commands only, never mappings.
