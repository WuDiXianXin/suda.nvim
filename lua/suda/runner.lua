local M = {}

local config = require('suda.config')

--- Determine how the configured executable should be called.
--- @param c table
--- @return 'sudo'|'doas'|'custom'
local function get_flavor(c)
  if c.flavor ~= nil and c.flavor ~= 'auto' then
    return c.flavor
  end

  local base = vim.fs.basename(c.executable)
  if base == 'sudo' or base == 'sudo-rs' then
    return 'sudo'
  end
  if base == 'doas' then
    return 'doas'
  end
  return 'custom'
end

local function spawn(argv, opts)
  local ok, proc = pcall(vim.system, argv, opts)
  if not ok then
    error(('[suda] cannot run %s: %s'):format(argv[1], tostring(proc)), 0)
  end

  local wait_ok, res = pcall(function()
    return proc:wait()
  end)
  if not wait_ok then
    error(('[suda] failed to wait for %s: %s'):format(argv[1], tostring(res)), 0)
  end

  -- Neovim 0.12 may return no result when a timeout expires while the process
  -- has children (the child keeps the pipe open). Treat that as a timeout
  -- instead of crashing on a nil result.
  if res == nil then
    if opts.timeout ~= nil then
      return {
        code = 124,
        signal = 0,
        stdout = '',
        stderr = 'timed out',
      }
    end
    error(('[suda] failed to wait for %s: no result'):format(argv[1]), 0)
  end
  return res
end

local function trim_detail(res)
  -- Do not fall back to stdout: it can contain data from privileged files.
  local detail = vim.trim(res.stderr or '')
  if #detail > 2000 then
    detail = detail:sub(1, 2000) .. '...'
  end
  return detail
end

local function fail(exe, res)
  local detail = trim_detail(res)
  local status
  if res.code ~= nil and res.code ~= 0 then
    status = 'exit ' .. tostring(res.code)
  elseif res.signal ~= nil and res.signal ~= 0 then
    status = 'signal ' .. tostring(res.signal)
  else
    status = 'unknown status'
  end
  local suffix = detail ~= '' and (': ' .. detail) or ''
  error(('[suda] %s failed (%s)%s'):format(exe, status, suffix), 0)
end

local function succeeded(res)
  return res.code == 0 and (res.signal == nil or res.signal == 0)
end

local function check_executable(exe)
  if vim.fn.executable(exe) ~= 1 then
    error(('[suda] executable not found: %s'):format(exe), 0)
  end
end

--- Return the effective flavor for the current config.
--- @param c table|nil
--- @return string
function M.flavor(c)
  return get_flavor(c or config.get())
end

--- @param cmd string[]
--- @param opts table
--- @param check boolean Whether a non-zero exit status should throw.
--- @return vim.SystemCompleted
local function run_command(cmd, opts, check)
  local c = config.get()
  local exe = c.executable
  local flavor = get_flavor(c)
  local stdin = opts.stdin

  check_executable(exe)

  if flavor == 'sudo' and not c.noninteractive then
    local probe_opts = { text = true }
    if c.timeout ~= nil then
      probe_opts.timeout = c.timeout
    end
    local probe = spawn({ exe, '-n', '--', 'true' }, probe_opts)
    if probe.code == 124 then
      error(('[suda] %s timed out while probing credentials'):format(exe), 0)
    end
    if not succeeded(probe) then
      local password = c.prompt_password(c.prompt)
      if password ~= nil and type(password) ~= 'string' then
        error('[suda] prompt_password must return a string, nil, or an empty string', 0)
      end
      if password == nil or password == '' then
        error('[suda] cancelled', 0)
      end

      local auth_opts = { stdin = password .. '\n', text = true }
      if c.timeout ~= nil then
        auth_opts.timeout = c.timeout
      end
      local auth = spawn({ exe, '-p', '', '-S', '-v' }, auth_opts)
      if auth.code == 124 then
        error(('[suda] %s timed out during authentication'):format(exe), 0)
      end
      if not succeeded(auth) then
        local detail = trim_detail(auth)
        error(('[suda] authentication failed%s'):format(detail ~= '' and (': ' .. detail) or ''), 0)
      end
    end
  end

  local argv = { exe }
  if flavor == 'sudo' then
    vim.list_extend(argv, { '-n', '--' })
  elseif flavor == 'doas' and c.noninteractive then
    vim.list_extend(argv, { '-n' })
  end
  vim.list_extend(argv, cmd)

  if c.debug then
    vim.notify('[suda] ' .. table.concat(argv, ' '), vim.log.levels.DEBUG)
  end

  -- Close stdin by default so a command cannot accidentally read from
  -- Neovim's terminal when no input was supplied.
  local sys_opts = { stdin = stdin or '', text = false }
  if opts.cwd ~= nil then
    sys_opts.cwd = opts.cwd
  end
  if opts.stdout ~= nil then
    sys_opts.stdout = opts.stdout
  end
  if c.timeout ~= nil then
    sys_opts.timeout = c.timeout
  end
  local res = spawn(argv, sys_opts)
  if check and not succeeded(res) then
    fail(exe, res)
  end

  return res
end

--- Run an argv list with sudo/doas if configured.
---
--- {cmd} must not contain the executable or sudo flags. For sudo, the returned
--- command is `sudo -n -- {cmd...}` after authenticating via `sudo -v`.
---
--- @param cmd string[]
--- @param opts table|nil { stdin?: string, cwd?: string, stdout?: boolean }
--- @return vim.SystemCompleted
function M.run(cmd, opts)
  return run_command(cmd, opts or {}, true)
end

--- Run a command and return its result even when it exits non-zero.
--- Authentication, spawn, and timeout errors still throw.
--- @param cmd string[]
--- @param opts table|nil { stdin?: string, cwd?: string, stdout?: boolean }
--- @return vim.SystemCompleted
function M.probe(cmd, opts)
  return run_command(cmd, opts or {}, false)
end

return M
