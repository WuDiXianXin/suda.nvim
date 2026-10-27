-- Headless integration tests for the Lua suda plugin.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua -l tests/run.lua
--
-- A fake sudo executable is used so the tests never touch real credentials or
-- real system files. Paths under the temporary run directory's `visible/` are
-- mapped by the fake sudo to `privileged/`, while the visible files themselves
-- are made unreadable (mode 000) when the test needs to force sudo.
--
-- This suite relies on POSIX permission modes and is Unix-only.

local root = vim.g.suda_test_root or vim.fn.getcwd()
local fake_sudo = root .. '/tests/bin/fake-sudo'

local H = { tests = {}, prompts = {}, prompt_reply = 'secret' }

local function oct(value)
  return tonumber(value, 8)
end

local function mkdirp(path, mode)
  vim.fn.mkdir(path, 'p')
  if mode ~= nil then
    assert(vim.uv.fs_chmod(path, mode))
  end
end

local function write_bytes(path, data)
  mkdirp(vim.fs.dirname(path))
  local file = assert(io.open(path, 'wb'))
  file:write(data)
  file:close()
end

local function read_bytes(path)
  local file = assert(io.open(path, 'rb'))
  local data = file:read('*a')
  file:close()
  return data
end

local function utf16le(text)
  local out = { string.char(0xFF, 0xFE) }
  for i = 1, #text do
    out[#out + 1] = text:sub(i, i) .. '\0'
  end
  return table.concat(out)
end

local function utf16be(text)
  local out = { string.char(0xFE, 0xFF) }
  for i = 1, #text do
    out[#out + 1] = '\0' .. text:sub(i, i)
  end
  return table.concat(out)
end

local function utf32le(text)
  local out = { string.char(0xFF, 0xFE, 0, 0) }
  for i = 1, #text do
    out[#out + 1] = text:sub(i, i) .. '\0\0\0'
  end
  return table.concat(out)
end

local temp_root = vim.fn.stdpath('cache') .. '/suda-tests'
mkdirp(temp_root)
local base = assert(vim.uv.fs_mkdtemp(temp_root .. '/run-XXXXXX'))
local mirror = base .. '/visible'
local privileged = base .. '/privileged'
local state = base .. '/state'
local undodir = base .. '/undo'

mkdirp(mirror)
mkdirp(privileged)
mkdirp(state)
mkdirp(undodir)
vim.o.undodir = undodir

vim.env.SUDA_FAKE_STATE = state
vim.env.SUDA_FAKE_ROOT = privileged
vim.env.SUDA_FAKE_PREFIX = mirror .. '/'
vim.env.SUDA_FAKE_PASSWORD = 'secret'

function H.visible(relpath)
  return mirror .. '/' .. relpath
end

function H.privileged_path(relpath)
  return privileged .. '/' .. relpath
end

function H.read_privileged(relpath)
  return read_bytes(H.privileged_path(relpath))
end

function H.log()
  local file = io.open(state .. '/log.jsonl', 'rb')
  if file == nil then
    return {}
  end
  local data = file:read('*a')
  file:close()

  local entries = {}
  for line in data:gmatch('[^\n]+') do
    local ok, entry = pcall(vim.json.decode, line)
    if ok then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

function H.find(entries, predicate)
  for _, entry in ipairs(entries) do
    if predicate(entry) then
      return entry
    end
  end
  return nil
end

function H.login()
  local path = state .. '/auth'
  write_bytes(path, 'ok\n')
  assert(vim.uv.fs_chmod(path, oct('600')))
end

function H.logout()
  os.remove(state .. '/auth')
end

function H.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      ('%s\nexpected: %s\nactual:   %s'):format(
        message or 'values differ',
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function H.ok(value, message)
  if not value then
    error(message or 'expected a truthy value', 2)
  end
end

function H.contains(haystack, needle, message)
  if type(haystack) ~= 'string' or haystack:find(needle, 1, true) == nil then
    error(
      ('%s\nneedle:   %s\nhaystack: %s'):format(
        message or 'substring not found',
        vim.inspect(needle),
        vim.inspect(haystack)
      ),
      2
    )
  end
end

function H.wait_for(predicate, message, timeout)
  local ok = vim.wait(timeout or 1000, predicate, 10)
  if not ok then
    error(message or 'timed out waiting for condition', 2)
  end
end

function H.watch(events)
  local counts = {}
  local group = vim.api.nvim_create_augroup('suda_test_events', { clear = true })
  for _, event in ipairs(events) do
    counts[event] = 0
    vim.api.nvim_create_autocmd(event, {
      group = group,
      pattern = 'suda://*',
      callback = function()
        counts[event] = counts[event] + 1
      end,
    })
  end
  return counts
end

function H.test(name, fn)
  H.tests[#H.tests + 1] = { name = name, fn = fn }
end

function H.normal_buffer(lines, cursor)
  vim.cmd('silent! noautocmd enew!')
  vim.bo.buftype = ''
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  if cursor ~= nil then
    vim.api.nvim_win_set_cursor(0, { cursor, 0 })
  end
  return vim.api.nvim_get_current_buf()
end

function H.setup(opts)
  local config = require('suda.config')
  config.reset()

  local setup_opts = vim.tbl_extend('force', {
    executable = fake_sudo,
    flavor = 'sudo',
    prompt = 'Password: ',
    noninteractive = false,
    smart_edit = false,
    checktime = false,
    debug = false,
    prompt_password = function(prompt)
      H.prompts[#H.prompts + 1] = prompt
      return H.prompt_reply
    end,
  }, opts or {})

  require('suda').setup(setup_opts)
end

function H.reset(opts)
  pcall(require('suda.smart_edit').setup, false)
  pcall(require('suda.buffer')._reset_cmdline)
  pcall(vim.api.nvim_del_augroup_by_name, 'suda_test_events')

  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  pcall(vim.cmd, 'silent! noautocmd enew!')

  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  vim.api.nvim_buf_set_lines(current, 0, -1, false, {})
  vim.bo[current].modified = false
  vim.bo[current].buftype = ''
  vim.bo[current].swapfile = false
  vim.bo[current].undofile = false

  for _, key in ipairs({
    'suda#executable',
    'suda_executable',
    'suda#prompt',
    'suda_prompt',
    'suda#noninteractive',
    'suda_noninteractive',
    'suda#nopass',
    'suda_nopass',
    'suda_smart_edit',
  }) do
    vim.g[key] = nil
  end
  vim.env.SUDA_TEST_FILE = nil
  vim.env.SUDA_TEST_DIR = nil

  H.prompts = {}
  H.prompt_reply = 'secret'
  H.logout()
  os.remove(state .. '/log.jsonl')
  vim.v.errmsg = ''

  H.setup(opts)
end

-------------------------------------------------------------------------------
-- Fixtures
-------------------------------------------------------------------------------

local function add_fixture(relpath, content, opts)
  opts = opts or {}
  local visible = H.visible(relpath)
  local hidden = H.privileged_path(relpath)

  mkdirp(vim.fs.dirname(visible))
  mkdirp(vim.fs.dirname(hidden))

  write_bytes(visible, opts.visible_content or content)
  assert(vim.uv.fs_chmod(visible, opts.visible_mode or oct('000')))
  write_bytes(hidden, content)
end

add_fixture('readonly.txt', 'root only\n', { visible_mode = 0 })
add_fixture('write.txt', 'old\n', { visible_mode = 0 })
add_fixture('range.txt', 'old range\n', { visible_mode = 0 })
add_fixture('binary.bin', 'A\0B\r\nC', { visible_mode = 0 })
add_fixture('noeol.txt', 'last line', { visible_mode = 0 })
add_fixture('crlf.txt', 'one\r\ntwo\r\n', { visible_mode = 0 })
add_fixture('crlf-explicit.txt', 'one\r\ntwo\r\n', { visible_mode = 0 })
add_fixture('bom.txt', string.char(0xEF, 0xBB, 0xBF) .. 'hello\n', { visible_mode = 0 })
add_fixture('bom-readable.txt', string.char(0xEF, 0xBB, 0xBF) .. 'hello\n', {
  visible_mode = oct('644'),
})
add_fixture('utf16le.txt', utf16le('hello\n'), { visible_mode = 0 })
add_fixture('utf16le-crlf.txt', utf16le('one\r\ntwo\r\n'), { visible_mode = 0 })
add_fixture('utf16le-noeol.txt', utf16le('last line'), { visible_mode = 0 })
add_fixture('utf16be.txt', utf16be('hello\n'), { visible_mode = 0 })
add_fixture('utf32le.txt', utf32le('hello\n'), { visible_mode = 0 })
add_fixture('latin1.txt', 'caf' .. string.char(0xE9) .. '\n', { visible_mode = 0 })
add_fixture('weird name 100% #hash | pipe $() end.txt', 'weird\n', { visible_mode = 0 })
add_fixture('smart/readonly.txt', 'smart root\n', { visible_mode = 0 })
add_fixture('smart/mode444.txt', 'readonly user\n', { visible_mode = oct('444') })
add_fixture('readable.txt', 'readable\n', { visible_mode = oct('644') })
add_fixture('scratch.txt', 'scratch\n', { visible_mode = oct('644') })
add_fixture('range-source.txt', 'source\n', { visible_mode = oct('644') })
add_fixture('append.txt', 'old\n', { visible_mode = 0 })

mkdirp(H.visible('fail/dir'))
mkdirp(H.privileged_path('fail/dir'))
mkdirp(H.visible('writable'))
mkdirp(H.privileged_path('writable'))
mkdirp(H.visible('locked'), oct('555'))
mkdirp(H.privileged_path('locked'))

--- Create a directory that cannot be searched by the current user, run {fn},
--- then restore permissions even when {fn} fails.
--- @param relpath string
--- @param fn fun(dir: string)
local function with_unsearchable_dir(relpath, fn)
  local dir = H.visible(relpath)
  mkdirp(dir)
  mkdirp(H.privileged_path(relpath))

  local ok, err = pcall(function()
    assert(vim.uv.fs_chmod(dir, 0))
    fn(dir)
  end)
  pcall(vim.uv.fs_chmod, dir, oct('755'))
  if not ok then
    error(err, 0)
  end
end

-------------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------------

H.test('plugin bootstrap registers commands and modules', function()
  H.eq(tonumber(vim.g.loaded_suda), 1)
  H.eq(vim.fn.exists(':SudaRead'), 2)
  H.eq(vim.fn.exists(':SudaWrite'), 2)
  H.eq(type(require('suda')), 'table')
  H.eq(type(require('suda.buffer')), 'table')
  H.eq(type(require('suda.runner')), 'table')
end)

H.test('config merges legacy globals and setup options', function()
  local config = require('suda.config')
  config.reset()

  vim.g['suda#executable'] = '/legacy/sudo'
  vim.g['suda#prompt'] = 'Legacy: '
  vim.g['suda#noninteractive'] = 1
  vim.g['suda_smart_edit'] = 1

  local c = config.get()
  H.eq(c.executable, '/legacy/sudo')
  H.eq(c.prompt, 'Legacy: ')
  H.eq(c.noninteractive, true)
  H.eq(c.smart_edit, true)

  vim.g['suda#nopass'] = 1
  H.eq(config.get().noninteractive, true)

  config.setup({
    executable = fake_sudo,
    noninteractive = false,
    smart_edit = false,
  })
  c = config.get()
  H.eq(c.executable, fake_sudo)
  H.eq(c.noninteractive, false)
  H.eq(c.smart_edit, false)
end)

H.test('config warns about unknown options and rejects invalid values', function()
  local config = require('suda.config')

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(message, level)
    if tostring(message):find('unknown option', 1, true) and level == vim.log.levels.WARN then
      notified = true
    end
  end
  local ok, err = pcall(config.setup, { smartedit = true })
  vim.notify = original_notify
  H.eq(ok, true)
  H.eq(notified, true)

  ok, err = pcall(config.setup, { flavor = 'typo' })
  H.eq(ok, false)
  H.contains(tostring(err), 'opts.flavor')

  ok, err = pcall(config.setup, { timeout = -1 })
  H.eq(ok, false)
  H.contains(tostring(err), 'non-negative integer')

  ok, err = pcall(config.setup, { timeout = 1.5 })
  H.eq(ok, false)
  H.contains(tostring(err), 'non-negative integer')

  ok, err = pcall(config.setup, { executable = '' })
  H.eq(ok, false)
  H.contains(tostring(err), 'must not be empty')
end)

H.test(':SudaRead authenticates and loads a root-only file', function()
  local path = H.visible('readonly.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'root only' })
  H.eq(vim.bo.buftype, 'acwrite')
  H.eq(vim.bo.modified, false)
  H.eq(vim.bo.swapfile, false)
  H.eq(vim.bo.undofile, false)
  H.eq(#H.prompts, 1)
  H.eq(H.prompts[1], 'Password: ')

  local entries = H.log()
  local probe = H.find(entries, function(entry)
    return entry.argv[4] == 'true'
  end)
  H.ok(probe ~= nil, 'expected an initial sudo -n probe')
  H.eq(probe.code, 1)

  local auth = H.find(entries, function(entry)
    return entry.validate == true
  end)
  H.ok(auth ~= nil, 'expected sudo -v authentication')
  H.eq(auth.stdin_password, true)
  H.eq(auth.password_ok, true)

  local cat = H.find(entries, function(entry)
    return entry.argv[4] == 'cat'
  end)
  H.ok(cat ~= nil, 'expected sudo cat')
  H.eq(cat.argv[5], path)
  H.eq(cat.code, 0)
  H.eq(cat.auth, true)
end)

H.test(':SudaRead reuses cached sudo credentials', function()
  H.login()
  local path = H.visible('readonly.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'root only' })
  H.eq(#H.prompts, 0)

  local entries = H.log()
  H.eq(#entries, 2)
  H.eq(entries[1].argv[4], 'true')
  H.eq(entries[1].code, 0)
  H.eq(entries[2].argv[4], 'cat')
  H.eq(entries[2].code, 0)
  H.eq(
    H.find(entries, function(entry)
      return entry.validate == true
    end),
    nil
  )
end)

H.test(':SudaRead reads readable files without sudo', function()
  local path = H.visible('readable.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'readable' })
  H.eq(vim.bo.buftype, 'acwrite')
  H.eq(#H.prompts, 0)
  H.eq(#H.log(), 0)
end)

H.test(':SudaRead expands environment variables', function()
  H.login()
  vim.env.SUDA_TEST_FILE = H.visible('readonly.txt')

  vim.cmd('SudaRead $SUDA_TEST_FILE')

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. H.visible('readonly.txt'))
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'root only' })
end)

H.test(':SudaRead without arguments reopens the current file', function()
  H.login()
  local path = H.visible('readable.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  H.eq(vim.api.nvim_buf_get_name(0), path)

  vim.cmd('SudaRead')

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'readable' })
end)

H.test(':SudaRead fires BufReadPre and BufReadPost', function()
  H.login()
  local counts = H.watch({ 'BufNewFile', 'BufReadPre', 'BufReadPost' })

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(H.visible('readonly.txt')))

  H.eq(counts.BufReadPre, 1)
  H.eq(counts.BufReadPost, 1)
  H.eq(counts.BufNewFile, 0)
end)

H.test(':SudaWrite saves a suda buffer and clears modified', function()
  H.login()
  local path = H.visible('write.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'old' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new1', 'new2' })
  H.eq(vim.bo.modified, true)

  vim.cmd('write')

  H.eq(vim.bo.modified, false)
  H.eq(H.read_privileged('write.txt'), 'new1\nnew2\n')

  local dd = H.find(H.log(), function(entry)
    return entry.argv[4] == 'dd'
  end)
  H.ok(dd ~= nil, 'expected sudo dd')
  H.eq(dd.code, 0)

  local found_target = false
  for _, arg in ipairs(dd.argv) do
    if arg == 'of=' .. path then
      found_target = true
    end
  end
  H.ok(found_target, 'dd should write the requested path')
end)

H.test(':SudaWrite to another file keeps the source modified', function()
  H.login()
  local scratch = H.visible('scratch.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'from command' })
  vim.bo.modified = true

  local target = H.visible('from-command.txt')
  vim.cmd('SudaWrite ' .. vim.fn.fnameescape(target))

  H.eq(H.read_privileged('from-command.txt'), 'from command\n')
  H.eq(vim.bo.modified, true)
  H.eq(vim.api.nvim_buf_get_name(0), scratch)
end)

H.test(':saveas suda:// creates an acwrite buffer', function()
  H.login()
  local source = H.visible('readable.txt')
  local target = H.visible('saved-as.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(source))
  vim.bo.swapfile = true
  vim.bo.undofile = true
  vim.cmd('saveas ' .. vim.fn.fnameescape('suda://' .. target))

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. target)
  H.eq(vim.bo.buftype, 'acwrite')
  H.eq(vim.bo.swapfile, false)
  H.eq(vim.bo.undofile, false)
  H.eq(H.read_privileged('saved-as.txt'), 'readable\n')

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'saved again' })
  vim.cmd('write')

  H.eq(vim.bo.modified, false)
  H.eq(H.read_privileged('saved-as.txt'), 'saved again\n')

  -- Renaming away from suda:// restores a normal buffer, so an ordinary
  -- :saveas/:write works again.
  local ordinary = H.visible('saved-out.txt')
  vim.cmd('saveas ' .. vim.fn.fnameescape(ordinary))

  H.eq(vim.api.nvim_buf_get_name(0), ordinary)
  H.eq(vim.bo.buftype, '')
  H.eq(vim.fn.readfile(ordinary), { 'saved again' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'normal write' })
  vim.cmd('write')

  H.eq(vim.bo.modified, false)
  H.eq(vim.fn.readfile(ordinary), { 'normal write' })
end)

H.test('BufWriteCmd failure reports an error and keeps modified', function()
  H.login()
  local counts = H.watch({ 'BufWritePre', 'BufWritePost' })

  local scratch = H.visible('scratch.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'cannot write' })
  vim.bo.modified = true

  local target = H.visible('fail/missing/target.txt')
  local ok, err = pcall(vim.api.nvim_cmd, {
    cmd = 'write',
    args = { 'suda://' .. target },
    bang = true,
    magic = { file = false, bar = false },
  }, {})

  H.eq(ok, false)
  H.contains(tostring(err), '[suda]')
  H.contains(vim.v.errmsg, '[suda]')
  H.eq(vim.bo.modified, true)
  H.eq(counts.BufWritePre, 1)
  H.eq(counts.BufWritePost, 0)

  local dd = H.find(H.log(), function(entry)
    return entry.argv[4] == 'dd'
  end)
  H.ok(dd ~= nil, 'expected sudo dd')
  H.eq(dd.code, 1)
end)

H.test('FileWriteCmd writes only the requested range', function()
  H.login()
  local counts = H.watch({ 'FileWritePre', 'FileWritePost' })

  local scratch = H.visible('range-source.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three' })
  vim.bo.modified = true

  local target = H.visible('range.txt')
  vim.api.nvim_cmd({
    cmd = 'write',
    args = { 'suda://' .. target },
    range = { 1, 2 },
    bang = true,
    magic = { file = false, bar = false },
  }, {})

  H.eq(H.read_privileged('range.txt'), 'one\ntwo\n')
  H.eq(counts.FileWritePre, 1)
  H.eq(counts.FileWritePost, 1)
  H.eq(vim.bo.modified, true)
end)

H.test('FileAppendCmd appends only the requested range', function()
  H.login()
  local counts = H.watch({ 'FileAppendPre', 'FileAppendPost' })

  local scratch = H.visible('range-source.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three' })
  vim.bo.modified = true

  local target = H.visible('append.txt')
  vim.cmd('2,3write >> ' .. vim.fn.fnameescape('suda://' .. target))

  H.eq(H.read_privileged('append.txt'), 'old\ntwo\nthree\n')
  H.eq(counts.FileAppendPre, 1)
  H.eq(counts.FileAppendPost, 1)
  H.eq(vim.bo.modified, true)

  local dd = H.find(H.log(), function(entry)
    return entry.argv[4] == 'dd' and entry.append == true
  end)
  H.ok(dd ~= nil, 'expected sudo dd with oflag=append')
  H.eq(dd.code, 0)
end)

H.test('FileAppendCmd creates a missing target', function()
  H.login()
  local scratch = H.visible('range-source.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'appended' })

  local target = H.visible('append-new.txt')
  vim.cmd('write >> ' .. vim.fn.fnameescape('suda://' .. target))

  H.eq(H.read_privileged('append-new.txt'), 'appended\n')
end)

H.test('suda.append() appends through the Lua API', function()
  H.login()
  local scratch = H.visible('range-source.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'api one', 'api two' })

  local target = H.visible('append-api.txt')
  require('suda').append('suda://' .. target, { range = '1,2', cmdbang = 0 })

  H.eq(H.read_privileged('append-api.txt'), 'api one\napi two\n')
end)

H.test('append falls back to tee when dd lacks oflag=append', function()
  H.login()

  local bindir = base .. '/bin'
  local fake_dd = bindir .. '/dd'
  write_bytes(
    fake_dd,
    '#!/bin/sh\n'
      .. 'for arg in "$@"; do\n'
      .. '  if [ "$arg" = "oflag=append" ] && [ "${SUDA_FAKE_DD_NO_OFLAG:-0}" = "1" ]; then\n'
      .. '    echo "dd: unrecognized option oflag=append" >&2\n'
      .. '    exit 1\n'
      .. '  fi\n'
      .. 'done\n'
      .. 'exit 0\n'
  )
  assert(vim.uv.fs_chmod(fake_dd, oct('755')))

  local old_path = vim.env.PATH
  local old_flag = vim.env.SUDA_FAKE_DD_NO_OFLAG
  vim.env.PATH = bindir .. ':' .. old_path
  vim.env.SUDA_FAKE_DD_NO_OFLAG = '1'

  local io = require('suda.io')
  io._reset_dd_append_cache()

  local ok, err = pcall(function()
    local scratch = H.visible('range-source.txt')
    vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'fallback' })

    local target = H.visible('append-fallback.txt')
    vim.cmd('write >> ' .. vim.fn.fnameescape('suda://' .. target))

    H.eq(H.read_privileged('append-fallback.txt'), 'fallback\n')

    local tee = H.find(H.log(), function(entry)
      return entry.argv[4] == 'tee' and entry.append == true
    end)
    H.ok(tee ~= nil, 'expected a tee -a fallback')
    H.eq(tee.argv[5], '-a')
    H.eq(tee.argv[6], target)
  end)

  vim.env.PATH = old_path
  vim.env.SUDA_FAKE_DD_NO_OFLAG = old_flag
  io._reset_dd_append_cache()

  if not ok then
    error(err, 0)
  end
end)

H.test('FileAppendCmd failure reports an error and skips FileAppendPost', function()
  H.login()
  local counts = H.watch({ 'FileAppendPre', 'FileAppendPost' })

  local scratch = H.visible('scratch.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(scratch))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'cannot append' })

  local target = H.visible('fail/missing/target.txt')
  local ok, err = pcall(vim.cmd, 'write >> ' .. vim.fn.fnameescape('suda://' .. target))

  H.eq(ok, false)
  H.contains(tostring(err), '[suda]')
  H.contains(vim.v.errmsg, '[suda]')
  H.eq(counts.FileAppendPre, 1)
  H.eq(counts.FileAppendPost, 0)

  local dd = H.find(H.log(), function(entry)
    return entry.argv[4] == 'dd' and entry.append == true
  end)
  H.ok(dd ~= nil, 'expected sudo dd with oflag=append')
  H.eq(dd.code, 1)
end)

H.test('FileReadCmd inserts at the requested range', function()
  H.login()
  local counts = H.watch({ 'FileReadPre', 'FileReadPost' })
  local target = 'suda://' .. H.visible('readonly.txt')
  local escaped = vim.fn.fnameescape(target)

  H.normal_buffer({ 'A', 'B', 'C', 'D' }, 3)

  vim.cmd('1read ' .. escaped)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'A', 'root only', 'B', 'C', 'D' })

  vim.cmd('1,2read ' .. escaped)
  H.eq(
    vim.api.nvim_buf_get_lines(0, 0, -1, false),
    { 'A', 'root only', 'root only', 'B', 'C', 'D' }
  )

  vim.cmd('$read ' .. escaped)
  H.eq(
    vim.api.nvim_buf_get_lines(0, 0, -1, false),
    { 'A', 'root only', 'root only', 'B', 'C', 'D', 'root only' }
  )

  -- A typed :0read is recognized from the command line recorded by
  -- CmdlineLeave.  Feed the same command line here because the test executes
  -- commands through vim.cmd() instead of the command line.
  require('suda.buffer').record_cmdline('0read ' .. target)
  vim.cmd('0read ' .. escaped)
  H.eq(
    vim.api.nvim_buf_get_lines(0, 0, -1, false),
    { 'root only', 'A', 'root only', 'root only', 'B', 'C', 'D', 'root only' }
  )

  H.normal_buffer({ 'A', 'B', 'C', 'D' }, 3)
  -- nvim_cmd() does not go through CmdlineLeave.  The marks still provide the
  -- explicit 2,3 range.
  vim.api.nvim_cmd({
    cmd = 'read',
    args = { target },
    range = { 2, 3 },
    magic = { file = false, bar = false },
  }, {})
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'A', 'B', 'C', 'root only', 'D' })

  H.eq(counts.FileReadPre, 5)
  H.eq(counts.FileReadPost, 5)
end)

H.test('FileReadCmd ignores stale 0read command history', function()
  H.login()
  local target = 'suda://' .. H.visible('readonly.txt')
  local escaped = vim.fn.fnameescape(target)

  H.normal_buffer({ 'A', 'B', 'C', 'D' }, 1)
  -- A stale history entry must not turn a plain :read into :0read.
  vim.fn.histadd('cmd', '0read ' .. target)
  require('suda.buffer').record_cmdline('read ' .. target)
  vim.cmd('read ' .. escaped)

  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'A', 'root only', 'B', 'C', 'D' })
end)

H.test('suda.read() honors an explicit zero range', function()
  H.login()
  local path = H.visible('readonly.txt')
  H.normal_buffer({ 'A', 'B' }, 2)

  require('suda').read('suda://' .. path, { range = '0' })

  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'root only', 'A', 'B' })
end)

H.test('binary files round-trip through ++bin', function()
  H.login()
  local path = H.visible('binary.bin')

  vim.cmd('edit ++bin ' .. vim.fn.fnameescape('suda://' .. path))
  H.eq(vim.bo.binary, true)
  H.eq(vim.bo.fileformat, 'unix')

  vim.cmd('write ++bin')

  H.eq(H.read_privileged('binary.bin'), 'A\0B\r\nC')
end)

H.test("a missing final newline sets 'endofline'", function()
  H.login()
  local path = H.visible('noeol.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape('suda://' .. path))
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'last line' })
  H.eq(vim.bo.endofline, false)

  -- Like :write on a normal file, suda honors 'fixeol'.  Turn it off to keep
  -- the missing newline.
  vim.bo.fixeol = false
  vim.cmd('write')

  H.eq(H.read_privileged('noeol.txt'), 'last line')
end)

H.test("a CRLF file sets 'fileformat' and round-trips", function()
  H.login()
  local path = H.visible('crlf.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape('suda://' .. path))
  H.eq(vim.bo.fileformat, 'dos')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'two' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed', 'two' })
  vim.cmd('write')

  H.eq(H.read_privileged('crlf.txt'), 'changed\r\ntwo\r\n')
end)

H.test("a UTF-8 BOM is preserved and 'bomb' is set", function()
  H.login()
  local path = H.visible('bom.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.fileencoding, 'utf-8')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  vim.cmd('write')

  H.eq(H.read_privileged('bom.txt'), string.char(0xEF, 0xBB, 0xBF) .. 'changed\n')
end)

H.test('a readable UTF-8 BOM is preserved', function()
  local path = H.visible('bom-readable.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.fileencoding, 'utf-8')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })
end)

H.test('an explicit ++enc keeps a matching BOM', function()
  H.login()
  local path = H.visible('bom.txt')
  write_bytes(H.privileged_path('bom.txt'), string.char(0xEF, 0xBB, 0xBF) .. 'hello\n')

  vim.cmd('edit ++enc=utf-8 ' .. vim.fn.fnameescape('suda://' .. path))
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.fileencoding, 'utf-8')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })
end)

H.test('a UTF-16LE file is decoded and re-encoded', function()
  H.login()
  local path = H.visible('utf16le.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileencoding, 'utf-16le')
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.endofline, true)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  vim.cmd('write')

  H.eq(H.read_privileged('utf16le.txt'), utf16le('changed\n'))
end)

H.test("a UTF-16LE CRLF file keeps 'fileformat'", function()
  H.login()
  local path = H.visible('utf16le-crlf.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileencoding, 'utf-16le')
  H.eq(vim.bo.fileformat, 'dos')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'two' })

  vim.cmd('write')
  H.eq(H.read_privileged('utf16le-crlf.txt'), utf16le('one\r\ntwo\r\n'))
end)

H.test("a UTF-16LE file without a final newline sets 'endofline'", function()
  H.login()
  local path = H.visible('utf16le-noeol.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileencoding, 'utf-16le')
  H.eq(vim.bo.endofline, false)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'last line' })

  vim.bo.fixeol = false
  vim.cmd('write')
  H.eq(H.read_privileged('utf16le-noeol.txt'), utf16le('last line'))
end)

H.test('a UTF-16BE file round-trips', function()
  H.login()
  local path = H.visible('utf16be.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.ok(vim.bo.fileencoding ~= '', 'expected a fileencoding')
  H.eq(vim.bo.bomb, true)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  vim.cmd('write')

  H.eq(H.read_privileged('utf16be.txt'), utf16be('changed\n'))
end)

H.test('a UTF-32LE file round-trips', function()
  H.login()
  local path = H.visible('utf32le.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.ok(vim.bo.fileencoding ~= '', 'expected a fileencoding')
  H.eq(vim.bo.bomb, true)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
  vim.cmd('write')

  H.eq(H.read_privileged('utf32le.txt'), utf32le('changed\n'))
end)

H.test('Latin-1 text is decoded and re-encoded', function()
  H.login()
  local path = H.visible('latin1.txt')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileencoding, 'latin1')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  H.eq(vim.fn.str2list(lines[1]), { 99, 97, 102, 233 })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'caf\195\169' })
  vim.cmd('write')
  H.eq(H.read_privileged('latin1.txt'), 'caf' .. string.char(0xE9) .. '\n')
end)

H.test('large Latin-1 files are detected without a prefix limit', function()
  local path = H.visible('large-latin1.txt')
  write_bytes(path, string.rep('a', 1048576) .. string.char(0xE9) .. '\n')
  assert(vim.uv.fs_chmod(path, oct('644')))

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileencoding, 'latin1')
  H.eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 1)
end)

H.test('modelines are applied after BufReadPost', function()
  local path = H.visible('modeline.txt')
  write_bytes(path, '# vim: set shiftwidth=7 :\nhello\n')
  assert(vim.uv.fs_chmod(path, oct('644')))

  local old_modeline = vim.o.modeline
  local old_shiftwidth = vim.bo.shiftwidth
  vim.o.modeline = true
  local ok, err = pcall(function()
    vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
    H.eq(vim.bo.shiftwidth, 7)
  end)
  vim.o.modeline = old_modeline
  vim.bo.shiftwidth = old_shiftwidth
  if not ok then
    error(err, 0)
  end
end)

H.test('an explicit ++ff is not overridden by autodetection', function()
  H.login()
  local path = H.visible('crlf-explicit.txt')

  vim.cmd('edit ++ff=unix ' .. vim.fn.fnameescape('suda://' .. path))

  H.eq(vim.bo.fileformat, 'unix')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'one\r', 'two\r' })
end)

H.test('paths with spaces and special characters work', function()
  H.login()
  local relpath = 'weird name 100% #hash | pipe $() end.txt'
  local path = H.visible(relpath)

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'weird' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed special' })
  vim.cmd('write')

  H.eq(H.read_privileged(relpath), 'changed special\n')
end)

H.test('a missing suda file behaves like a new file', function()
  H.login()
  local counts = H.watch({ 'BufNewFile', 'BufReadPre', 'BufReadPost' })
  local path = H.visible('missing.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape('suda://' .. path))

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' })
  H.eq(vim.bo.buftype, 'acwrite')
  H.eq(vim.bo.modified, false)
  H.eq(counts.BufNewFile, 1)
  H.eq(counts.BufReadPre, 0)
  H.eq(counts.BufReadPost, 0)
  H.eq(#H.log(), 0)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'created' })
  vim.cmd('write')

  H.eq(H.read_privileged('missing.txt'), 'created\n')
end)

H.test('smart edit switches unreadable files to suda://', function()
  H.setup({ smart_edit = true })
  H.login()
  local path = H.visible('smart/readonly.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))

  H.wait_for(function()
    return vim.api.nvim_buf_get_name(0) == 'suda://' .. path
  end, 'smart edit did not switch the unreadable file')

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'smart root' })
  H.eq(vim.bo.buftype, 'acwrite')
end)

H.test('smart edit switches read-only files to suda://', function()
  H.setup({ smart_edit = true })
  H.login()
  local path = H.visible('smart/mode444.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))

  H.wait_for(function()
    return vim.api.nvim_buf_get_name(0) == 'suda://' .. path
  end, 'smart edit did not switch the read-only file')

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'readonly user' })
end)

H.test('smart edit leaves writable and new writable files alone', function()
  H.setup({ smart_edit = true })
  H.login()

  local readable = H.visible('readable.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(readable))
  H.eq(vim.api.nvim_buf_get_name(0), readable)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'readable' })

  local newfile = H.visible('writable/new.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(newfile))
  H.eq(vim.api.nvim_buf_get_name(0), newfile)
  H.eq(vim.bo.buftype, '')
end)

H.test('smart edit checks the nearest existing parent directory', function()
  H.setup({ smart_edit = true })
  local path = H.visible('writable/missing/deep/new.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  -- Give the BufAdd fallback a chance to run; it must not switch the buffer.
  vim.wait(100)

  H.eq(vim.api.nvim_buf_get_name(0), path)
  H.eq(vim.bo.buftype, '')
end)

H.test('smart edit handles a new file in an unwritable directory', function()
  H.setup({ smart_edit = true })
  H.login()
  local path = H.visible('locked/new.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))

  H.wait_for(function()
    return vim.api.nvim_buf_get_name(0) == 'suda://' .. path
  end, 'smart edit did not switch the new file')

  H.eq(vim.api.nvim_buf_get_name(0), 'suda://' .. path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'locked new' })
  vim.cmd('write')

  H.eq(H.read_privileged('locked/new.txt'), 'locked new\n')
end)

H.test('smart edit disabled leaves even read-only files alone', function()
  H.setup({ smart_edit = false })
  H.login()
  local path = H.visible('smart/mode444.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))

  H.eq(vim.api.nvim_buf_get_name(0), path)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'readonly user' })
end)

H.test('smart edit does not replace a modified buffer', function()
  H.setup({ smart_edit = false })
  H.login()
  local path = H.visible('smart/mode444.txt')

  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  vim.bo.readonly = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved user changes' })
  H.eq(vim.bo.modified, true)

  local buf = vim.api.nvim_get_current_buf()
  local switched = require('suda.smart_edit').switch_to_suda(buf)

  H.eq(switched, false)
  H.eq(vim.api.nvim_buf_get_name(buf), path)
  H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'unsaved user changes' })
  H.eq(vim.bo[buf].modified, true)
end)

H.test('noninteractive mode does not prompt', function()
  H.setup({ noninteractive = true })
  H.logout()
  local path = H.visible('readonly.txt')

  local ok, err = pcall(vim.cmd, 'SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(ok, false)
  H.contains(tostring(err), '[suda]')
  H.contains(vim.v.errmsg, '[suda]')
  H.eq(#H.prompts, 0)

  local entries = H.log()
  H.eq(#entries, 1)
  H.eq(entries[1].argv[4], 'cat')
  H.eq(entries[1].code, 1)

  H.eq(
    H.find(entries, function(entry)
      return entry.validate == true
    end),
    nil
  )
end)

H.test('a wrong password fails authentication without running cat', function()
  H.logout()
  H.prompt_reply = 'wrong'
  local path = H.visible('readonly.txt')

  local ok, err = pcall(vim.cmd, 'SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(ok, false)
  H.contains(tostring(err), 'authentication failed')
  H.contains(tostring(err), 'Sorry, try again')
  H.eq(#H.prompts, 1)

  local entries = H.log()
  local auth = H.find(entries, function(entry)
    return entry.validate == true
  end)
  H.ok(auth ~= nil, 'expected sudo -v authentication')
  H.eq(auth.code, 1)
  H.eq(auth.password_ok, false)
  H.eq(
    H.find(entries, function(entry)
      return entry.argv[4] == 'cat'
    end),
    nil
  )
end)

H.test('an empty password cancels the operation', function()
  H.logout()
  H.prompt_reply = ''
  local path = H.visible('readonly.txt')

  local ok, err = pcall(vim.cmd, 'SudaRead ' .. vim.fn.fnameescape(path))

  H.eq(ok, false)
  H.contains(tostring(err), 'cancelled')
  H.eq(#H.prompts, 1)
  H.eq(#H.log(), 1)
  H.eq(H.log()[1].argv[4], 'true')
end)

H.test('system() and systemlist() run argv safely', function()
  H.login()
  local suda = require('suda')

  H.eq(suda.system({ 'printf', 'hello' }), 'hello')
  H.eq(suda.systemlist({ 'printf', 'one\ntwo\n' }), { 'one', 'two' })
  H.eq(suda.systemlist({ 'printf', 'one\r\ntwo\r\n' }), { 'one', 'two' })
  H.eq(suda.system({ 'sh', '-c', 'cat' }, 'stdin data'), 'stdin data')

  local res = require('suda.runner').run({ 'pwd' }, { cwd = temp_root })
  H.eq(vim.trim(res.stdout), temp_root)
end)

H.test('system() reports failures with stderr', function()
  H.login()
  local suda = require('suda')

  local ok, err = pcall(suda.system, { 'sh', '-c', 'echo boom >&2; exit 3' })

  H.eq(ok, false)
  H.contains(tostring(err), 'exit 3')
  H.contains(tostring(err), 'boom')
end)

H.test('system() treats signal termination as failure', function()
  H.login()
  local suda = require('suda')

  local ok, err = pcall(suda.system, { 'signal', '15' })

  H.eq(ok, false)
  H.contains(tostring(err), 'signal 15')
end)

H.test('timeout is reported as exit 124', function()
  H.setup({ noninteractive = true, timeout = 100 })
  H.login()

  local ok, err = pcall(require('suda').system, { 'sleep', '5' })

  H.eq(ok, false)
  H.contains(tostring(err), 'exit 124')
end)

H.test('a credential probe timeout does not prompt', function()
  H.setup({ noninteractive = false, timeout = 0 })
  H.logout()

  local ok, err = pcall(require('suda').system, { 'true' })

  H.eq(ok, false)
  H.contains(tostring(err), 'timed out')
  H.eq(#H.prompts, 0)
end)

H.test('doas and custom flavors build the expected argv', function()
  local suda = require('suda')

  H.setup({ flavor = 'doas', noninteractive = true })
  H.login()
  H.eq(suda.system({ 'true' }), '')
  local doas = H.log()[1]
  H.ok(doas ~= nil, 'expected a doas invocation')
  H.eq(doas.argv, { 'fake-sudo', '-n', 'true' })

  H.setup({ flavor = 'custom', noninteractive = true })
  H.login()
  H.eq(suda.system({ 'true' }), '')
  local custom = H.log()[2]
  H.ok(custom ~= nil, 'expected a custom invocation')
  H.eq(custom.argv, { 'fake-sudo', 'true' })

  H.setup({ flavor = 'auto', executable = fake_sudo })
  H.eq(suda.flavor(), 'custom')
end)

H.test('normalize helpers handle prefixes and env vars', function()
  local io = require('suda.io')

  H.eq(io.strip_prefix('suda://suda:///tmp/x'), '/tmp/x')
  H.eq(io.normalize_target('suda:///tmp/x'), '/tmp/x')

  vim.env.SUDA_TEST_DIR = temp_root .. '/suda-env'
  H.eq(io.normalize_target('suda://$SUDA_TEST_DIR/file'), temp_root .. '/suda-env/file')
  H.eq(io.normalize_target('suda://${SUDA_TEST_DIR}/file'), temp_root .. '/suda-env/file')
  H.eq(io.normalize_target('~/x'), vim.fn.expand('~') .. '/x')

  H.eq(io.same_path('/tmp/a', 'suda:///tmp/a'), true)
  H.eq(io.same_path('/tmp/a', '/tmp/b'), false)

  local current = H.visible('readable.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(current))
  H.eq(io.normalize_target('%'), current)
  H.eq(io.normalize_target('%:p'), current)
  H.eq(io.normalize_target('suda://%'), current)
end)

H.test("a readable file ending with a newline keeps 'endofline'", function()
  H.login()
  local rel = 'readable-eol.txt'
  local path = H.visible(rel)
  write_bytes(path, 'one\ntwo\n')
  assert(vim.uv.fs_chmod(path, oct('644')))
  write_bytes(H.privileged_path(rel), 'one\ntwo\n')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileformat, 'unix')
  H.eq(vim.bo.endofline, true)

  -- With the old seek('set', -1) bug, endofline was false here and this write
  -- silently dropped the final newline.
  vim.bo.fixeol = false
  vim.cmd('write')
  H.eq(H.read_privileged(rel), 'one\ntwo\n')
end)

H.test("a readable DOS file ending with a newline keeps 'endofline'", function()
  local rel = 'readable-dos-eol.txt'
  local path = H.visible(rel)
  write_bytes(path, 'one\r\ntwo\r\n')
  assert(vim.uv.fs_chmod(path, oct('644')))
  write_bytes(H.privileged_path(rel), 'one\r\ntwo\r\n')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.fileformat, 'dos')
  H.eq(vim.bo.endofline, true)
end)

H.test("a readable UTF-8 BOM-only file has 'endofline'", function()
  local rel = 'bom-only.txt'
  local path = H.visible(rel)
  local bom = string.char(0xEF, 0xBB, 0xBF)
  write_bytes(path, bom)
  assert(vim.uv.fs_chmod(path, oct('644')))
  write_bytes(H.privileged_path(rel), bom)

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.fileencoding, 'utf-8')
  H.eq(vim.bo.endofline, true)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' })
end)

H.test("an unreadable UTF-8 BOM-only file has 'endofline'", function()
  H.login()
  local rel = 'bom-only-unreadable.txt'
  local path = H.visible(rel)
  local bom = string.char(0xEF, 0xBB, 0xBF)
  write_bytes(path, bom)
  assert(vim.uv.fs_chmod(path, 0))
  write_bytes(H.privileged_path(rel), bom)

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  H.eq(vim.bo.bomb, true)
  H.eq(vim.bo.endofline, true)
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '' })
end)

H.test('BufWritePre changing marks does not truncate the write', function()
  H.login()
  local rel = 'write-pre.txt'
  local path = H.visible(rel)
  write_bytes(path, 'old\n')
  assert(vim.uv.fs_chmod(path, 0))
  write_bytes(H.privileged_path(rel), 'old\n')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three', 'four' })

  vim.api.nvim_create_augroup('suda_test_bufwrite_pre', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePre', {
    group = 'suda_test_bufwrite_pre',
    pattern = 'suda://*',
    once = true,
    callback = function()
      vim.cmd('normal! 2Gyy')
    end,
  })

  local ok, err = pcall(vim.cmd, 'write')
  pcall(vim.api.nvim_del_augroup_by_name, 'suda_test_bufwrite_pre')
  if not ok then
    error(err, 0)
  end

  H.eq(H.read_privileged(rel), 'one\ntwo\nthree\nfour\n')
  H.eq(vim.bo.modified, false)
end)

H.test('BufWritePre changing text does not truncate the write', function()
  H.login()
  local rel = 'write-pre-header.txt'
  local path = H.visible(rel)
  write_bytes(path, 'old\n')
  assert(vim.uv.fs_chmod(path, 0))
  write_bytes(H.privileged_path(rel), 'old\n')

  vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two', 'three', 'four' })

  vim.api.nvim_create_augroup('suda_test_bufwrite_header', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePre', {
    group = 'suda_test_bufwrite_header',
    pattern = 'suda://*',
    once = true,
    callback = function()
      vim.cmd('normal! ggOheader')
    end,
  })

  local ok, err = pcall(vim.cmd, 'write')
  pcall(vim.api.nvim_del_augroup_by_name, 'suda_test_bufwrite_header')
  if not ok then
    error(err, 0)
  end

  H.eq(H.read_privileged(rel), 'header\none\ntwo\nthree\nfour\n')
  H.eq(vim.bo.modified, false)
end)

H.test('FileWritePre changing marks keeps the requested range', function()
  H.login()
  local rel = 'filewrite-pre.txt'
  local path = H.visible(rel)
  write_bytes(path, 'old\n')
  assert(vim.uv.fs_chmod(path, 0))
  write_bytes(H.privileged_path(rel), 'old\n')

  H.normal_buffer({ 'one', 'two', 'three', 'four' })
  vim.api.nvim_create_augroup('suda_test_filewrite_pre', { clear = true })
  vim.api.nvim_create_autocmd('FileWritePre', {
    group = 'suda_test_filewrite_pre',
    pattern = 'suda://*',
    once = true,
    callback = function()
      vim.cmd('normal! 1Gyy')
    end,
  })

  local ok, err = pcall(vim.cmd, '2,3write! ' .. vim.fn.fnameescape('suda://' .. path))
  pcall(vim.api.nvim_del_augroup_by_name, 'suda_test_filewrite_pre')
  if not ok then
    error(err, 0)
  end

  H.eq(H.read_privileged(rel), 'two\nthree\n')
end)

H.test('FileAppendPre changing marks keeps the requested range', function()
  H.login()
  local rel = 'fileappend-pre.txt'
  local path = H.visible(rel)
  write_bytes(path, 'old\n')
  assert(vim.uv.fs_chmod(path, 0))
  write_bytes(H.privileged_path(rel), 'old\n')

  H.normal_buffer({ 'one', 'two', 'three', 'four' })
  vim.api.nvim_create_augroup('suda_test_fileappend_pre', { clear = true })
  vim.api.nvim_create_autocmd('FileAppendPre', {
    group = 'suda_test_fileappend_pre',
    pattern = 'suda://*',
    once = true,
    callback = function()
      vim.cmd('normal! 1Gyy')
    end,
  })

  local ok, err = pcall(vim.cmd, '2,3write >> ' .. vim.fn.fnameescape('suda://' .. path))
  pcall(vim.api.nvim_del_augroup_by_name, 'suda_test_fileappend_pre')
  if not ok then
    error(err, 0)
  end

  H.eq(H.read_privileged(rel), 'old\ntwo\nthree\n')
end)

H.test(':SudaRead reads a file under an unsearchable directory', function()
  H.login()
  local rel = 'unsearchable-read/secret.txt'
  local path = H.visible(rel)
  write_bytes(path, 'secret\n')
  write_bytes(H.privileged_path(rel), 'secret\n')

  with_unsearchable_dir('unsearchable-read', function()
    vim.cmd('SudaRead ' .. vim.fn.fnameescape(path))
    H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'secret' })
  end)
end)

H.test(':SudaRead does not treat an inaccessible path as a new file', function()
  H.login()
  local rel = 'unsearchable-missing/missing.txt'
  local path = H.visible(rel)

  with_unsearchable_dir('unsearchable-missing', function()
    local counts = H.watch({ 'BufNewFile', 'BufReadPre', 'BufReadPost' })
    local ok = pcall(vim.cmd, 'SudaRead ' .. vim.fn.fnameescape(path))
    local errmsg = vim.v.errmsg

    H.eq(ok, false)
    H.contains(errmsg, '[suda]')
    H.eq(counts.BufNewFile, 0)
    H.eq(counts.BufReadPre, 1)
    H.eq(counts.BufReadPost, 0)
  end)
end)

H.test('smart edit reads a file under an unsearchable directory', function()
  H.setup({ smart_edit = true })
  H.login()
  local rel = 'unsearchable-smart/secret.txt'
  local path = H.visible(rel)
  write_bytes(path, 'secret\n')
  write_bytes(H.privileged_path(rel), 'secret\n')

  with_unsearchable_dir('unsearchable-smart', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    H.wait_for(function()
      return vim.api.nvim_buf_get_name(0) == 'suda://' .. path
    end, 'smart edit did not handle the unsearchable directory')
    H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'secret' })
  end)
end)

H.test(':SudaWrite creates a file under an unsearchable directory', function()
  H.login()
  local rel = 'unsearchable-write/new.txt'

  with_unsearchable_dir('unsearchable-write', function()
    H.normal_buffer({ 'created' })
    vim.cmd('SudaWrite ' .. vim.fn.fnameescape(H.visible(rel)))
    H.eq(H.read_privileged(rel), 'created\n')
  end)
end)

H.test('privileged probe rejects a FIFO below an unsearchable directory', function()
  H.login()
  local rel = 'unsearchable-fifo/fifo'
  local visible = H.visible(rel)
  local hidden = H.privileged_path(rel)
  mkdirp(vim.fs.dirname(visible))
  mkdirp(vim.fs.dirname(hidden))
  vim.fn.system({ 'mkfifo', hidden })
  H.eq(vim.v.shell_error, 0)

  with_unsearchable_dir('unsearchable-fifo', function()
    H.eq(require('suda.io').probe_kind(visible), 'other')

    H.normal_buffer({ 'x' })
    local ok, err = pcall(require('suda.io').write, visible)
    H.eq(ok, false)
    H.contains(tostring(err), 'not a regular file')
  end)

  vim.fn.delete(hidden)
end)

H.test('reading non-regular files is rejected', function()
  local io = require('suda.io')
  local fifo = H.visible('special/fifo')
  mkdirp(vim.fs.dirname(fifo))
  vim.fn.system({ 'mkfifo', fifo })
  H.eq(vim.v.shell_error, 0)

  H.eq(io.path_state(fifo).type, 'fifo')
  H.eq(io.is_regular_file(fifo), false)
  vim.fn.delete(fifo)

  local ok, err = pcall(io.read, '/dev/null')
  H.eq(ok, false)
  H.contains(tostring(err), 'not a regular file')
end)

H.test('writing non-regular files is rejected', function()
  H.normal_buffer({ 'x' })

  local ok, err = pcall(require('suda.io').write, '/dev/null')
  H.eq(ok, false)
  H.contains(tostring(err), 'not a regular file')
end)

H.test(':checkhealth suda runs and reports the executable', function()
  H.login()

  local ok, err = pcall(vim.cmd, 'checkhealth suda')
  H.eq(ok, true, tostring(err))

  local found = false
  local found_test = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      if text:find('suda', 1, true) and text:find('executable found', 1, true) then
        found = true
      end
      if text:find('test executable found', 1, true) then
        found_test = true
      end
    end
  end
  H.ok(found, 'health output should mention suda and the executable')
  H.ok(found_test, 'health output should mention the test executable')
end)

-------------------------------------------------------------------------------
-- Runner
-------------------------------------------------------------------------------

local failures = 0

for index, test in ipairs(H.tests) do
  io.write(('%2d. %s ... '):format(index, test.name))
  io.flush()

  local ok, err = xpcall(function()
    H.reset()
    test.fn()
  end, debug.traceback)

  if ok then
    io.write('ok\n')
  else
    failures = failures + 1
    io.write('FAIL\n')
    io.write(tostring(err) .. '\n')
  end

  pcall(require('suda.smart_edit').setup, false)
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  pcall(vim.cmd, 'silent! noautocmd enew!')
end

io.write(('\n%d tests, %d failed\n'):format(#H.tests, failures))

pcall(vim.uv.fs_chmod, H.visible('locked'), oct('755'))
vim.fn.delete(base, 'rf')

if failures > 0 then
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
