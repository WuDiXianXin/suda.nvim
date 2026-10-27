local M = {}

local io = require('suda.io')

local last_cmdline = nil
local cmdline_generation = 0

--- Remember the command line that is about to execute.  CmdlineLeave fires
--- before the command runs, so FileReadCmd can recognize a typed :0read without
--- trusting an unrelated command left in history.
--- @param cmdline string|nil
function M.record_cmdline(cmdline)
  if type(cmdline) ~= 'string' then
    cmdline = vim.fn.getcmdline() or ''
  end

  cmdline_generation = cmdline_generation + 1
  local generation = cmdline_generation

  cmdline = vim.trim(cmdline:gsub('^%s*:', ''))
  if cmdline ~= '' and vim.fn.match(cmdline, [[^0r\%[ead]\>]]) == 0 then
    last_cmdline = cmdline
  else
    last_cmdline = nil
  end

  vim.schedule(function()
    if cmdline_generation == generation then
      last_cmdline = nil
    end
  end)
end

--- Clear remembered command-line state.  Intended for tests.
function M._reset_cmdline()
  cmdline_generation = cmdline_generation + 1
  last_cmdline = nil
end

local function current_buf(args)
  if args.buf ~= nil and args.buf ~= 0 then
    return args.buf
  end
  return vim.api.nvim_get_current_buf()
end

--- @param expr string
--- @return string
local function canonical_suda_name(expr)
  return 'suda://' .. io.normalize_target(expr)
end

--- A buffer renamed with :saveas suda://... has not been through BufReadCmd,
--- so give it the same options as a buffer opened through suda://.
--- @param buf integer
local function ensure_suda_buffer(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if io.strip_prefix(name) == name then
    return
  end
  if vim.b[buf].suda_buffer ~= 1 then
    vim.b[buf].suda_prev_swapfile = vim.bo[buf].swapfile
    vim.b[buf].suda_prev_undofile = vim.bo[buf].undofile
    vim.b[buf].suda_buffer = 1
  end
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
end

--- Keep suda:// buffers working after :saveas and restore ordinary buffers
--- when they are renamed away from suda://.
--- @param args table
function M.after_rename(args)
  local buf = current_buf(args)
  local name = vim.api.nvim_buf_get_name(buf)

  if io.strip_prefix(name) ~= name then
    local ok, canonical = pcall(canonical_suda_name, name)
    if ok and canonical ~= name then
      local renamed = pcall(vim.cmd, 'noautocmd file! ' .. vim.fn.fnameescape(canonical))
      if renamed then
        name = canonical
      end
    end
    ensure_suda_buffer(buf)
    return
  end
  if vim.b[buf].suda_buffer ~= 1 then
    return
  end

  vim.bo[buf].buftype = ''
  local swapfile = vim.b[buf].suda_prev_swapfile
  local undofile = vim.b[buf].suda_prev_undofile
  if swapfile ~= nil then
    vim.bo[buf].swapfile = swapfile
  else
    vim.bo[buf].swapfile = vim.o.swapfile
  end
  if undofile ~= nil then
    vim.bo[buf].undofile = undofile
  else
    vim.bo[buf].undofile = vim.o.undofile
  end
  vim.b[buf].suda_buffer = nil
  vim.b[buf].suda_prev_swapfile = nil
  vim.b[buf].suda_prev_undofile = nil
end

local function echo(message)
  if message == nil or message == '' then
    return
  end
  vim.api.nvim_echo({ { message, 'None' } }, false, {})
end

local function exec_event(event, pattern, process_modeline)
  if pattern == nil or pattern == '' then
    return
  end
  vim.api.nvim_exec_autocmds(event, {
    pattern = pattern,
    modeline = process_modeline == true,
  })
end

local function report_error(err)
  local text = type(err) == 'string' and err or vim.inspect(err)
  local lines = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line ~= '' then
      if line:sub(1, 7) ~= '[suda] ' then
        line = '[suda] ' .. line
      end
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    lines = { '[suda] unknown error' }
  end

  for _, line in ipairs(lines) do
    vim.api.nvim_err_writeln(line)
  end
  -- nvim_err_writeln() makes :write/:read fail, while v:errmsg makes the
  -- failure visible to scripts as well.
  vim.v.errmsg = lines[1]
end

--- Return the range of the pending write. Neovim sets the '[ and '] marks for
--- commands executed from the command line, but not for nvim_cmd() calls.
--- @return string
local function write_range()
  local first = vim.fn.line("'[")
  local last = vim.fn.line("']")
  if first > 0 and last >= first then
    return ('%d,%d'):format(first, last)
  end
  return '1,$'
end

function M.bufread(args)
  local buf = current_buf(args)
  local raw_target = args.file or args.match or vim.api.nvim_buf_get_name(buf)
  local path = io.normalize_target(raw_target)
  local target = 'suda://' .. path

  -- Buffer names are resolved once, when the buffer is created.  Keeping a
  -- relative or unresolved suda:// name would make later writes depend on the
  -- current working directory.
  if vim.api.nvim_buf_get_name(buf) ~= target then
    local ok, err = pcall(vim.cmd, 'noautocmd file! ' .. vim.fn.fnameescape(target))
    if not ok then
      error(('[suda] failed to normalize buffer name: %s'):format(err), 0)
    end
  end

  local missing = false
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      local cmdarg = vim.v.cmdarg or ''
      local explicit_fileformat = cmdarg:match('%+%+ff=(%a+)')
      local explicit_encoding = cmdarg:match('%+%+enc=([^%s]+)')
      local binary = cmdarg:match('%+%+bin') ~= nil
      missing = io.path_state(path).missing == true

      if missing then
        -- Neovim does not fire BufNewFile for a custom BufReadCmd, but the
        -- target behaves like a new file.
        exec_event('BufNewFile', target, true)
      else
        exec_event('BufReadPre', target)
      end

      local undolevels = vim.bo[buf].undolevels
      if vim.b[buf].suda_buffer ~= 1 then
        vim.b[buf].suda_prev_swapfile = vim.bo[buf].swapfile
        vim.b[buf].suda_prev_undofile = vim.bo[buf].undofile
        vim.b[buf].suda_buffer = 1
      end
      vim.bo[buf].undolevels = -1
      vim.bo[buf].swapfile = false
      vim.bo[buf].undofile = false

      local read_ok, read_err = pcall(function()
        local info = nil
        if not missing then
          local message
          message, info = io.read(target, {
            range = '1',
            cmdarg = cmdarg,
            encoding = explicit_encoding,
            detect_fileformat = not binary and explicit_fileformat == nil,
            detect_encoding = not binary and explicit_encoding == nil,
            detect_bomb = not binary and explicit_encoding ~= nil,
          })
          vim.cmd('silent lockmarks 0delete _')
          echo(message)
        end

        vim.bo[buf].buftype = 'acwrite'
        vim.bo[buf].modified = false
        if info ~= nil then
          if info.endofline ~= nil then
            vim.bo[buf].endofline = info.endofline
          end
          -- ++bin, ++enc, and ++ff must win over autodetection, as they do
          -- for ordinary :edit.
          if not binary then
            local fileformat = explicit_fileformat or info.fileformat
            if fileformat ~= nil then
              vim.bo[buf].fileformat = fileformat
            end
            local fileencoding = explicit_encoding or info.fileencoding
            if fileencoding ~= nil then
              vim.bo[buf].fileencoding = fileencoding
            end
            if info.bomb ~= nil then
              -- With an explicit ++enc, only keep the BOM when it matches the
              -- requested encoding, as ordinary :edit does.
              if explicit_encoding == nil or info.fileencoding == explicit_encoding then
                vim.bo[buf].bomb = info.bomb
              else
                vim.bo[buf].bomb = false
              end
            end
          end
        end
      end)

      vim.bo[buf].undolevels = undolevels
      if not read_ok then
        error(read_err, 0)
      end
    end)
  end)

  if ok then
    if not missing then
      exec_event('BufReadPost', target, true)
    end
  else
    report_error(err)
  end
end

function M.fileread(args)
  local target = args.file or args.match

  -- FileReadCmd does not expose the command range directly.  A typed :0read is
  -- recognized from the command line recorded by CmdlineLeave.  Programmatic
  -- reads have no command line; they use marks (or pass range explicitly to
  -- suda.read()).
  local command = last_cmdline or ''
  last_cmdline = nil
  local first = vim.fn.line("'[")
  local range = vim.fn.match(command, [[^0r\%[ead]\>]]) == 0 and first <= 1 and '0' or "'["

  local ok, err = pcall(function()
    exec_event('FileReadPre', target)
    local message = io.read(target, {
      range = range,
      cmdarg = vim.v.cmdarg,
    })
    io.set_alternate(target)
    echo(message)
  end)

  if ok then
    exec_event('FileReadPost', target)
  else
    report_error(err)
  end
end

function M.bufwrite(args)
  local buf = current_buf(args)
  local target = args.file or args.match or vim.api.nvim_buf_get_name(buf)

  ensure_suda_buffer(buf)

  -- BufWriteCmd means the whole buffer is being written. Capture this before
  -- BufWritePre: a user autocommand may change '[ and '], but must not change
  -- the range that is saved.
  local name = vim.api.nvim_buf_get_name(buf)
  local range = '1,$'
  exec_event('BufWritePre', target)

  local ok, err = pcall(function()
    local message = vim.api.nvim_buf_call(buf, function()
      return io.write(target, {
        range = range,
        cmdarg = vim.v.cmdarg,
        cmdbang = vim.v.cmdbang,
      })
    end)

    if io.same_path(target, vim.api.nvim_buf_get_name(buf)) then
      vim.bo[buf].modified = false
    elseif name ~= '' and not io.same_path(target, name) then
      io.set_alternate(target)
    end

    echo(message)
  end)

  if ok then
    exec_event('BufWritePost', target)
  else
    report_error(err)
  end
end

function M.filewrite(args)
  local buf = current_buf(args)
  local target = args.file or args.match

  ensure_suda_buffer(buf)

  -- Capture the range before FileWritePre: the autocommand may yank, change
  -- text, or otherwise move '[ and '].
  local name = vim.api.nvim_buf_get_name(buf)
  local range = vim.api.nvim_buf_call(buf, write_range)
  exec_event('FileWritePre', target)

  local ok, err = pcall(function()
    local message = vim.api.nvim_buf_call(buf, function()
      return io.write(target, {
        range = range,
        cmdarg = vim.v.cmdarg,
        cmdbang = vim.v.cmdbang,
        preserve_state = true,
      })
    end)
    if name == '' or not io.same_path(target, name) then
      io.set_alternate(target)
    end
    echo(message)
  end)

  if ok then
    exec_event('FileWritePost', target)
  else
    report_error(err)
  end
end

function M.fileappend(args)
  local buf = current_buf(args)
  local target = args.file or args.match

  ensure_suda_buffer(buf)

  -- Capture the range before FileAppendPre for the same reason as FileWritePre.
  local name = vim.api.nvim_buf_get_name(buf)
  local range = vim.api.nvim_buf_call(buf, write_range)
  exec_event('FileAppendPre', target)

  local ok, err = pcall(function()
    local message = vim.api.nvim_buf_call(buf, function()
      return io.append(target, {
        range = range,
        cmdarg = vim.v.cmdarg,
        cmdbang = vim.v.cmdbang,
      })
    end)
    if name == '' or not io.same_path(target, name) then
      io.set_alternate(target)
    end
    echo(message)
  end)

  if ok then
    exec_event('FileAppendPost', target)
  else
    report_error(err)
  end
end

M.report_error = report_error

return M
