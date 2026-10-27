-- Minimal Neovim config used by the suda test suite.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')

vim.opt.runtimepath:prepend(root)
vim.g.suda_test_root = root

vim.o.swapfile = false
vim.o.undofile = false
vim.o.shadafile = 'NONE'
vim.o.modeline = false
vim.o.more = false
vim.o.confirm = false
vim.o.writeany = false
vim.o.shortmess = vim.o.shortmess .. 'I'
