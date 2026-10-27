local M = {}

local defaults = {
  executable = 'sudo',
  prompt = 'Password: ',
  noninteractive = false,
  smart_edit = false,
  checktime = true,
  flavor = 'auto',
  debug = false,
  timeout = nil,
}

local state = {
  opts = {},
}

local known_options = {}
for key in pairs(defaults) do
  known_options[key] = true
end
-- `timeout = nil` is not present in the defaults table, so pairs() omits it.
known_options.timeout = true
known_options.prompt_password = true

local valid_flavors = {
  auto = true,
  sudo = true,
  doas = true,
  custom = true,
}

local function default_prompt_password(prompt)
  vim.fn.inputsave()
  local ok, password = pcall(vim.fn.inputsecret, prompt)
  vim.fn.inputrestore()
  if not ok then
    error('[suda] password prompt cancelled', 0)
  end
  return password
end

local function tobool(value)
  if value == nil then
    return nil
  end
  if value == false or value == 0 or value == '' or value == '0' then
    return false
  end
  return true
end

local function legacy_value(keys)
  for _, key in ipairs(keys) do
    local value = vim.g[key]
    if value ~= nil then
      return value
    end
  end
  return nil
end

--- Configure suda. May be called more than once.
--- @param opts table|nil
function M.setup(opts)
  if opts == nil then
    return
  end

  vim.validate('opts', opts, 'table')

  local filtered = {}
  for key, value in pairs(opts) do
    if known_options[key] then
      filtered[key] = value
    else
      vim.notify(('[suda] unknown option ignored: %s'):format(key), vim.log.levels.WARN)
    end
  end
  opts = filtered

  if opts.executable ~= nil then
    vim.validate('opts.executable', opts.executable, 'string')
    if opts.executable == '' then
      error('[suda] opts.executable must not be empty', 0)
    end
  end
  if opts.prompt ~= nil then
    vim.validate('opts.prompt', opts.prompt, 'string')
  end
  if opts.noninteractive ~= nil then
    vim.validate('opts.noninteractive', opts.noninteractive, 'boolean')
  end
  if opts.smart_edit ~= nil then
    vim.validate('opts.smart_edit', opts.smart_edit, 'boolean')
  end
  if opts.checktime ~= nil then
    vim.validate('opts.checktime', opts.checktime, 'boolean')
  end
  if opts.flavor ~= nil then
    vim.validate('opts.flavor', opts.flavor, 'string')
    if not valid_flavors[opts.flavor] then
      error(
        ('[suda] opts.flavor must be one of auto, sudo, doas, custom (got %q)'):format(opts.flavor),
        0
      )
    end
  end
  if opts.debug ~= nil then
    vim.validate('opts.debug', opts.debug, 'boolean')
  end
  if opts.timeout ~= nil then
    vim.validate('opts.timeout', opts.timeout, 'number')
    if opts.timeout < 0 or opts.timeout % 1 ~= 0 then
      error('[suda] opts.timeout must be a non-negative integer', 0)
    end
  end
  if opts.prompt_password ~= nil then
    vim.validate('opts.prompt_password', opts.prompt_password, 'function')
  end

  state.opts = vim.tbl_deep_extend('force', state.opts, opts)
end

--- Return a resolved config table. Legacy g: variables are read every time so
--- that users can still set them before the plugin loads.
--- @return table
function M.get()
  local config = vim.deepcopy(defaults)

  local executable = legacy_value({ 'suda#executable', 'suda_executable' })
  if executable ~= nil then
    config.executable = executable
  end

  local prompt = legacy_value({ 'suda#prompt', 'suda_prompt' })
  if prompt ~= nil then
    config.prompt = prompt
  end

  local noninteractive = legacy_value({
    'suda#noninteractive',
    'suda_noninteractive',
    'suda#nopass',
    'suda_nopass',
  })
  if noninteractive ~= nil then
    config.noninteractive = noninteractive
  end

  local smart_edit = legacy_value({ 'suda_smart_edit' })
  if smart_edit ~= nil then
    config.smart_edit = smart_edit
  end

  for key, value in pairs(state.opts) do
    config[key] = value
  end

  if config.prompt_password == nil then
    config.prompt_password = default_prompt_password
  end

  config.noninteractive = tobool(config.noninteractive) == true
  config.smart_edit = tobool(config.smart_edit) == true
  config.checktime = config.checktime ~= false
  config.debug = tobool(config.debug) == true
  config.flavor = config.flavor or 'auto'

  return config
end

--- Reset configured options. Intended for tests.
function M.reset()
  state.opts = {}
end

--- Default prompt function, exposed for users who want to wrap it.
M.default_prompt_password = default_prompt_password

return M
