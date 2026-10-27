local M = {}

local config = require('suda.config')
local runner = require('suda.runner')
local path = require('suda.path')
local enc = require('suda.encoding')
local temp = require('suda.temp')

-- Keep the public helper names available from suda.io.
M.strip_prefix = path.strip_prefix
M.normalize_target = path.normalize_target
M.same_path = path.same_path
M.path_state = path.path_state
M.is_regular_file = path.is_regular_file
M.probe_kind = path.probe_kind

local function normalize_cmdarg(cmdarg)
  if cmdarg == nil or cmdarg == '' then
    return ''
  end
  if cmdarg:sub(1, 1) == ' ' then
    return cmdarg
  end
  return ' ' .. cmdarg
end

local function read_command(path, opts)
  local range = tostring(opts.range or '')
  local command = 'noautocmd '
    .. range
    .. 'read'
    .. normalize_cmdarg(opts.cmdarg)
    .. ' '
    .. vim.fn.fnameescape(path)
  local output = vim.api.nvim_exec2(command, { output = true }).output
  return (output:gsub('^\r?\n', ''))
end

local function write_command(path, opts)
  local range = tostring(opts.range or '')
  local bang = (opts.cmdbang == true or opts.cmdbang == 1) and '!' or ''
  local command = 'noautocmd '
    .. range
    .. 'write'
    .. bang
    .. normalize_cmdarg(opts.cmdarg)
    .. ' '
    .. vim.fn.fnameescape(path)
  local output = vim.api.nvim_exec2(command, { output = true }).output
  return (output:gsub('^\r?\n', ''))
end

local function display_path(path)
  return vim.fn.fnamemodify(path, ':~')
end

local function replace_path(message, from, to)
  return (message:gsub(vim.pesc(from), function()
    return to
  end))
end

--- Read a file into the current buffer via :read.
---
--- {opts} supports:
---   range:             range passed to :read
---   cmdarg:            v:cmdarg (for example " ++bin")
---   detect_fileformat: set 'fileformat' before reading (BufReadCmd only)
---   detect_encoding:   detect 'bomb'/'fileencoding' (BufReadCmd only)
---   detect_bomb:       detect 'bomb' when ++enc was given explicitly
---
--- @param expr string
--- @param opts table|nil
--- @return string message
--- @return table info
function M.read(expr, opts)
  opts = opts or {}
  local path = M.normalize_target(expr)

  local function detected_for(data, allow_incomplete)
    if not (opts.detect_encoding or opts.detect_bomb) then
      return nil
    end
    return enc.detect_encoding(data, allow_incomplete)
  end

  local function read_options(encoding)
    return vim.tbl_extend('force', opts, {
      cmdarg = enc.append_encoding(opts.cmdarg, encoding),
    })
  end

  local state = M.path_state(path)
  local regular, kind = M.is_regular_file(path, state)
  if regular == nil and state.missing == nil then
    local probed = M.probe_kind(path)
    if probed == 'missing' then
      error(('[suda] file not found: %s'):format(path), 0)
    elseif probed == 'other' then
      error(('[suda] not a regular file: %s'):format(path), 0)
    elseif probed == 'file' then
      regular = true
    end
  end
  if regular == false then
    if kind == 'directory' then
      error(('[suda] is a directory: %s'):format(path), 0)
    end
    error(('[suda] not a regular file: %s'):format(path), 0)
  end

  if vim.fn.filereadable(path) == 1 then
    local detected = nil
    if opts.detect_encoding or opts.detect_bomb then
      detected = enc.detect_encoding_readable(path, not opts.detect_encoding)
    end
    local encoding = detected and detected.fileencoding or nil
    local bomb = detected and detected.bomb or nil

    local fileformat
    if enc.is_wide_encoding(encoding) then
      fileformat = enc.wide_fileformat_file(path, encoding) or 'unix'
    else
      fileformat = enc.file_fileformat(path)
    end

    local endofline
    if enc.is_wide_encoding(encoding) then
      local tail = temp.file_tail_data(path, 8)
      endofline = enc.wide_endofline(tail, encoding, fileformat)
    else
      endofline = enc.file_endofline(path, fileformat, bomb)
    end

    -- :read does not split legacy Mac (CR) line endings, even after setting
    -- 'fileformat'.  Convert them to LF in a temporary file for BufReadCmd.
    if opts.detect_fileformat and fileformat == 'mac' then
      local data, read_err = temp.read_file_data(path, '*a')
      if data == nil then
        error(('[suda] failed to read %s: %s'):format(path, read_err or 'unknown error'), 0)
      end
      local converted = enc.is_wide_encoding(encoding) and enc.wide_cr_to_lf(data, encoding)
        or data:gsub('\r', '\n')
      local dir = temp.make_tempdir()
      local tempfile = dir .. '/data'
      local ok, message = pcall(function()
        temp.write_binary(tempfile, converted)
        return read_command(tempfile, read_options(encoding))
      end)
      vim.fn.delete(dir, 'rf')
      if not ok then
        error(message, 0)
      end
      return replace_path(message, tempfile, display_path(path)),
        {
          endofline = enc.is_wide_encoding(encoding)
              and enc.wide_endofline(data, encoding, fileformat)
            or enc.data_endofline(data, fileformat, bomb),
          fileformat = fileformat,
          fileencoding = encoding,
          bomb = bomb,
        }
    end

    -- BufReadCmd needs 'fileformat' set before :read so that CRLF files are
    -- split correctly.  FileReadCmd and suda.read() leave the buffer option
    -- alone.
    if opts.detect_fileformat and fileformat ~= nil then
      vim.bo.fileformat = fileformat
    end
    local message = read_command(path, read_options(encoding))
    return message,
      {
        endofline = endofline,
        fileformat = fileformat,
        fileencoding = encoding,
        bomb = bomb,
      }
  end

  if state.missing == true then
    error(('[suda] file not found: %s'):format(path), 0)
  end
  if vim.fn.isdirectory(path) == 1 then
    error(('[suda] is a directory: %s'):format(path), 0)
  end

  local dir = temp.make_tempdir()
  local tempfile = dir .. '/data'
  local ok, result, info = pcall(function()
    local res = runner.run({ 'cat', path })
    local data = res.stdout
    local detected = detected_for(data, false)
    local encoding = detected and detected.fileencoding or nil
    local bomb = detected and detected.bomb or nil
    local fileformat
    local endofline
    if enc.is_wide_encoding(encoding) then
      fileformat = enc.wide_fileformat(data, encoding)
      endofline = enc.wide_endofline(data, encoding, fileformat)
    else
      fileformat = enc.data_fileformat(data)
      endofline = enc.data_endofline(data, fileformat, bomb)
    end

    if opts.detect_fileformat and fileformat == 'mac' then
      local converted = enc.is_wide_encoding(encoding) and enc.wide_cr_to_lf(data, encoding)
        or data:gsub('\r', '\n')
      temp.write_binary(tempfile, converted)
      local message = read_command(tempfile, read_options(encoding))
      return message,
        {
          endofline = endofline,
          fileformat = fileformat,
          fileencoding = encoding,
          bomb = bomb,
        }
    elseif opts.detect_fileformat and fileformat ~= nil then
      vim.bo.fileformat = fileformat
    end

    temp.write_binary(tempfile, data)
    local message = read_command(tempfile, read_options(encoding))
    return message,
      {
        endofline = endofline,
        fileformat = fileformat,
        fileencoding = encoding,
        bomb = bomb,
      }
  end)
  vim.fn.delete(dir, 'rf')

  if not ok then
    error(result, 0)
  end
  return replace_path(result, tempfile, display_path(path)), info
end

local function strip_new_marker(message, path)
  local display = display_path(path)
  local quoted = '"' .. display .. '"'
  if message:sub(1, #quoted) ~= quoted then
    return message
  end

  -- The temporary file used to produce the message is always new, so the
  -- first flag is [New] (translated).  Later flags such as [dos] or [noeol]
  -- describe the real target and must be preserved.
  local rest = message:sub(#quoted + 1):gsub('^%s+', '')
  local stripped = rest:gsub('^%[[^%]]+%]%s*', '', 1)
  if stripped == rest then
    return message
  end
  return quoted .. ' ' .. stripped
end

local dd_append_supported = nil

--- Whether the dd visible to the current process really supports append mode.
---
--- The probe uses files in a private temporary directory and verifies the
--- resulting bytes, so a dd that merely accepts (but ignores) oflag=append is
--- handled correctly.  It never touches the real target and needs no sudo.
--- The result is cached for the lifetime of the plugin.
--- @return boolean
local function has_dd_append()
  if dd_append_supported ~= nil then
    return dd_append_supported
  end

  local dir = temp.make_tempdir()
  local source = dir .. '/source'
  local target = dir .. '/target'
  local ok, supported = pcall(function()
    temp.write_binary(source, 'B')
    temp.write_binary(target, 'A')
    local res = vim
      .system({
        'dd',
        'if=' .. source,
        'of=' .. target,
        'bs=1',
        'oflag=append',
        'conv=notrunc',
      }, { text = true, timeout = 5000 })
      :wait()
    if res == nil or res.code ~= 0 or (res.signal ~= nil and res.signal ~= 0) then
      return false
    end
    return temp.read_binary(target) == 'AB'
  end)
  vim.fn.delete(dir, 'rf')

  dd_append_supported = ok and supported == true
  return dd_append_supported
end

--- @param tempfile string
--- @param path string
--- @param append boolean
local function tee_to_target(tempfile, path, append)
  local tee = 'tee'
  if vim.fn.executable(tee) ~= 1 then
    error('[suda] tee executable not found', 0)
  end
  local argv = { tee }
  if append then
    argv[#argv + 1] = '-a'
  end
  argv[#argv + 1] = path
  runner.run(argv, { stdin = temp.read_binary(tempfile) })
end

--- @param tempfile string
--- @param path string
--- @param append boolean
local function dd_to_target(tempfile, path, append)
  local argv = { 'dd', 'if=' .. tempfile, 'of=' .. path, 'bs=1048576' }
  if append then
    -- GNU and BSD dd both understand oflag=append.  Keep the existing
    -- contents and write through the inode.
    vim.list_extend(argv, { 'oflag=append', 'conv=notrunc' })
  end
  runner.run(argv)
end

local function copy_to_target(tempfile, path, append)
  -- Scheme D: prefer dd for streaming append, but fall back to tee -a when
  -- the local dd (for example an old BusyBox) does not support oflag=append.
  if append and not has_dd_append() then
    tee_to_target(tempfile, path, true)
    return
  end

  dd_to_target(tempfile, path, append)
end

--- Shared implementation for M.write() and M.append().
--- @param expr string
--- @param opts table|nil
--- @param append boolean
--- @return string message
local function write_file(expr, opts, append)
  opts = opts or {}
  local path = M.normalize_target(expr)
  local state = M.path_state(path)
  local regular, kind = M.is_regular_file(path, state)
  if regular == nil and state.missing == nil then
    local probed = M.probe_kind(path)
    if probed == 'other' then
      error(('[suda] not a regular file: %s'):format(path), 0)
    elseif probed == 'file' then
      regular = true
    elseif probed == 'missing' then
      state.missing = true
    end
  end
  if state.missing ~= true and regular == false then
    if kind == 'directory' then
      error(('[suda] is a directory: %s'):format(path), 0)
    end
    error(('[suda] not a regular file: %s'):format(path), 0)
  end

  -- An inaccessible path is assumed to exist so the message does not claim
  -- "[New]" for a file that may have been overwritten.
  local existed = state.missing ~= true

  local dir = temp.make_tempdir()
  local tempfile = dir .. '/data'
  local ok, result = pcall(function()
    local message = write_command(tempfile, opts)
    copy_to_target(tempfile, path, append)
    return message
  end)
  vim.fn.delete(dir, 'rf')

  if not ok then
    error(result, 0)
  end

  result = replace_path(result, tempfile, display_path(path))
  if existed then
    result = strip_new_marker(result, path)
  end

  if config.get().checktime then
    vim.schedule(function()
      pcall(vim.cmd, 'checktime')
    end)
  end

  return result
end

--- Write the current buffer to a file via :write and sudo.
---
--- {opts} supports:
---   range:   range passed to :write
---   cmdarg:  v:cmdarg (for example " ++bin")
---   cmdbang: v:cmdbang (0 or 1)
---
--- @param expr string
--- @param opts table|nil
--- @return string message
function M.write(expr, opts)
  return write_file(expr, opts, false)
end

--- Append the current buffer (or the requested range) to a file with sudo.
---
--- {opts} has the same fields as |suda.write()|.
---
--- @param expr string
--- @param opts table|nil
--- @return string message
function M.append(expr, opts)
  return write_file(expr, opts, true)
end

-- Exposed for tests and for small integrations.
M.read_command = read_command
M.write_command = write_command
M._reset_dd_append_cache = function()
  dd_append_supported = nil
end

return M
