local M = {}

local config = require('suda.config')
local runner = require('suda.runner')
local smart_edit = require('suda.smart_edit')

local function run(argv)
  local ok, proc = pcall(vim.system, argv, { text = true, timeout = 5000 })
  if not ok then
    return nil, tostring(proc)
  end
  local wait_ok, res = pcall(function()
    return proc:wait()
  end)
  if not wait_ok then
    return nil, tostring(res)
  end
  if res == nil then
    return nil, 'timed out'
  end
  return res
end

local function succeeded(res)
  return res.code == 0 and (res.signal == nil or res.signal == 0)
end

function M.check()
  vim.health.start('suda')

  if vim.fn.has('nvim-0.12') == 1 then
    vim.health.ok('Neovim >= 0.12')
  else
    vim.health.error('Neovim 0.12 or newer is required')
  end

  local c = config.get()
  if vim.fn.executable(c.executable) == 1 then
    vim.health.ok(('executable found: %s'):format(c.executable))
  else
    vim.health.error(('executable not found: %s'):format(c.executable))
    return
  end

  local flavor = runner.flavor(c)
  vim.health.info(('flavor: %s'):format(flavor))

  if flavor == 'sudo' then
    local version, version_err = run({ c.executable, '-V' })
    if version == nil then
      vim.health.warn(('sudo -V failed: %s'):format(version_err or 'unknown error'))
    elseif succeeded(version) then
      local first = vim.split(vim.trim(version.stdout or ''), '\n', { plain = true })[1]
      vim.health.info(first ~= nil and first or 'sudo -V succeeded')
    else
      vim.health.warn('sudo -V failed')
    end

    local probe, probe_err = run({ c.executable, '-n', '--', 'true' })
    if probe == nil then
      vim.health.warn(('sudo probe failed: %s'):format(probe_err or 'unknown error'))
    elseif succeeded(probe) then
      vim.health.ok('sudo credentials are cached')
    elseif probe.code == 124 then
      vim.health.warn('sudo probe timed out')
    elseif c.noninteractive then
      vim.health.warn('sudo requires a password, but noninteractive mode is enabled')
    else
      vim.health.info('sudo will prompt for a password when needed')
    end
  end

  for _, exe in ipairs({ 'dd', 'cat' }) do
    if vim.fn.executable(exe) ~= 1 then
      vim.health.error(('%s executable is required'):format(exe))
    else
      vim.health.ok(('%s executable found'):format(exe))
    end
  end

  if vim.fn.executable('tee') == 1 then
    vim.health.ok('tee executable found (append fallback)')
  else
    vim.health.info('tee not found; :w >> requires dd oflag=append support')
  end

  if vim.fn.executable('test') == 1 then
    vim.health.ok('test executable found (privileged type probe)')
  else
    vim.health.warn(
      'test not found; special files below unsearchable directories may not be rejected'
    )
  end

  if smart_edit.is_enabled() then
    vim.health.info('smart_edit is enabled; unreadable/unwritable files may prompt for sudo')
  else
    vim.health.info('smart_edit is disabled')
  end
end

return M
