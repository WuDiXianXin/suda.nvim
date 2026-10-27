if vim.fn.has('nvim-0.12') == 0 then
  vim.notify('[suda] requires Neovim 0.12 or newer', vim.log.levels.ERROR)
  return
end

if vim.g.loaded_suda == 1 then
  return
end
vim.g.loaded_suda = 1

require('suda').setup()
