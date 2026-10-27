local M = {}

local path = require('suda.path')

local generation = 0
local smart_edit_enabled = false

--- Whether the nearest existing ancestor directory of {path} is writable.
---
--- A new file may be several directories below the nearest existing one (for
--- example `/etc/suda/new/file`).  Checking only the immediate parent would
--- switch such a buffer to suda:// even when the existing ancestor is writable.
--- @param path string
--- @return boolean
local function writable_ancestor(path)
  local parent = vim.fs.dirname(path)
  while parent ~= nil and parent ~= '' do
    if vim.fn.filewritable(parent) == 2 then
      return true
    end
    -- lstat() distinguishes "does not exist" (ENOENT) from "cannot inspect"
    -- (for example EACCES).  Only the former lets us keep walking up.
    local stat, _, err_name = vim.uv.fs_lstat(parent)
    if stat ~= nil or err_name ~= 'ENOENT' then
      return false
    end
    local next_parent = vim.fs.dirname(parent)
    if next_parent == parent then
      break
    end
    parent = next_parent
  end
  return false
end

local function is_uri(name)
  return name:match('^%a[%w+.-]*://') ~= nil
end

--- Whether the buffer should be replaced with a suda:// buffer.
--- @param buf integer
--- @param name string
--- @return boolean
local function needs_sudo(buf, name)
  if vim.bo[buf].buftype ~= '' then
    return false
  end

  local state = path.path_state(name)
  if is_uri(name) or state.type == 'directory' or vim.fn.isdirectory(name) == 1 then
    return false
  end
  if path.is_regular_file(name, state) == false then
    return false
  end

  local readable = vim.fn.filereadable(name) == 1
  local writable = vim.fn.filewritable(name) == 1
  if readable and writable then
    return false
  end

  -- A new file in a writable directory can be created normally; only switch
  -- to suda:// when the parent directory is not writable.  Do not treat an
  -- inaccessible path (EACCES) as new: its existence is unknown.
  if not readable and not writable and state.missing == true and writable_ancestor(name) then
    return false
  end

  return true
end

--- @param buf integer
--- @return boolean
local function switch_to_suda(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.b[buf].suda_smart_edit_checked then
    return false
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return false
  end
  -- Replacing a modified buffer with :edit could hide it and then delete it
  -- (with 'hidden' enabled), losing the user's changes.
  if vim.bo[buf].modified then
    vim.b[buf].suda_smart_edit_checked = true
    return false
  end
  if not needs_sudo(buf, name) then
    vim.b[buf].suda_smart_edit_checked = true
    return false
  end

  vim.b[buf].suda_smart_edit_checked = true
  local target = 'suda://' .. name
  local options = {}
  local readable = vim.fn.filereadable(name) == 1
  if vim.bo[buf].binary then
    options[#options + 1] = '++bin'
  else
    local encoding = vim.bo[buf].fileencoding
    if encoding ~= '' then
      options[#options + 1] = '++enc=' .. encoding
    end
    local fileformat = vim.bo[buf].fileformat
    -- A failed read leaves 'fileformat' at its default "unix" value.  Passing
    -- that as an explicit option would prevent suda from detecting the real
    -- format, so only forward it when it is meaningful.
    if fileformat ~= '' and (readable or fileformat ~= 'unix') then
      options[#options + 1] = '++ff=' .. fileformat
    end
  end
  local ok, err = pcall(function()
    local command = 'keepalt keepjumps edit'
    for _, option in ipairs(options) do
      command = command .. ' ' .. option
    end
    command = command .. ' ' .. vim.fn.fnameescape(target)
    vim.api.nvim_cmd(vim.api.nvim_parse_cmd(command, {}), {})
  end)

  if not ok then
    vim.notify(('[suda] smart edit failed: %s'):format(tostring(err)), vim.log.levels.WARN)
    return false
  end

  if
    vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_get_current_buf() ~= buf
    and #vim.fn.win_findbuf(buf) == 0
  then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return true
end

local function on_bufenter(args)
  switch_to_suda(args.buf)
end

--- BufEnter is not triggered when reading an unreadable file fails (Neovim
--- creates the buffer but keeps the previous buffer current). BufAdd schedules
--- a second check so smart edit also works for those files.
local function on_bufadd(args, my_generation)
  local buf = args.buf
  if vim.b[buf].suda_smart_edit_scheduled then
    return
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or is_uri(name) then
    return
  end

  vim.b[buf].suda_smart_edit_scheduled = true
  local origin = vim.api.nvim_get_current_buf()

  vim.schedule(function()
    if my_generation ~= generation then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return
    end

    local current = vim.api.nvim_get_current_buf()
    if current ~= origin and current ~= buf then
      return
    end

    switch_to_suda(buf)
  end)
end

--- Enable or disable smart edit.
--- @param enabled boolean
function M.setup(enabled)
  generation = generation + 1
  local my_generation = generation
  smart_edit_enabled = enabled == true

  local group = vim.api.nvim_create_augroup('suda_smart_edit', { clear = true })
  if not enabled then
    return
  end

  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    nested = true,
    callback = on_bufenter,
    desc = 'Switch unwritable files to suda:// buffers',
  })
  vim.api.nvim_create_autocmd('BufAdd', {
    group = group,
    callback = function(args)
      on_bufadd(args, my_generation)
    end,
    desc = 'Handle failed reads of unwritable files',
  })
end

M.is_enabled = function()
  return smart_edit_enabled
end
M.on_bufenter = on_bufenter
M.on_bufadd = on_bufadd
M.switch_to_suda = switch_to_suda

return M
