local M = {}

local runner = require('suda.runner')

--- Remove all leading suda:// prefixes from a buffer/path string.
--- @param expr string|nil
--- @return string
function M.strip_prefix(expr)
  local path = tostring(expr or '')
  while path:sub(1, 7) == 'suda://' do
    path = path:sub(8)
  end
  return path
end

--- Expand Vim's special file names in paths supplied by callers.  Command
--- arguments are expanded by 'complete=file', but the Lua and legacy APIs
--- still need to accept names such as "%", "%:p", and "#".
--- @param path string
--- @return string
local function expand_special(path)
  local first = path:sub(1, 1)
  if first == '%' or first == '#' then
    return vim.fn.expand(path)
  end
  local special = path:match('^(<[%w_]+>)')
  if special == '<cfile>' or special == '<afile>' or special == '<amatch>' then
    return vim.fn.expand(path)
  end
  return path
end

--- Expand ~ and ~user without letting expand() interpret the rest of the path
--- (a literal "$()" or "%" in a file name must stay intact).
--- @param path string
--- @return string
local function expand_tilde(path)
  if path:sub(1, 1) ~= '~' then
    return path
  end
  local name, rest = path:match('^~([^/\\]*)(.*)$')
  if name == nil then
    return path
  end
  local tilde = '~' .. name
  local base = name == '' and (vim.env.HOME or vim.fn.expand('~')) or vim.fn.expand(tilde)
  if base == '' or base == tilde then
    return path
  end
  return base .. rest
end

--- Expand environment variables, ~, special Vim file names, and turn a
--- suda:// name into an absolute path.
--- @param expr string
--- @return string
function M.normalize_target(expr)
  local path = expand_special(M.strip_prefix(expr))
  if path == '' then
    error('[suda] empty path', 0)
  end
  path = path:gsub('%${([%w_]+)}', function(name)
    return vim.env[name] or ('${' .. name .. '}')
  end)
  path = path:gsub('%$([%w_]+)', function(name)
    return vim.env[name] or ('$' .. name)
  end)
  return vim.fs.abspath(expand_tilde(path))
end

--- Whether two buffer names/paths refer to the same file.
--- @param left string|nil
--- @param right string|nil
--- @return boolean
function M.same_path(left, right)
  local function canonical(path)
    local ok, normalized = pcall(M.normalize_target, path)
    if not ok then
      return nil
    end
    return vim.uv.fs_realpath(normalized) or vim.fs.normalize(normalized)
  end

  local left_path = canonical(left)
  local right_path = canonical(right)
  return left_path ~= nil and right_path ~= nil and left_path == right_path
end

--- Return what is known about a path without following a final symlink.
---
--- Only ENOENT means the path is definitely missing. Other errors, especially
--- EACCES and EPERM, mean that suda cannot tell whether the path exists; callers
--- must not treat those paths as new files.
--- @param path string
--- @return { type: string|nil, missing: boolean|nil, err: string|nil }
function M.path_state(path)
  local stat, err, err_name = vim.uv.fs_lstat(path)
  if stat ~= nil then
    return { type = stat.type, missing = false }
  end
  if err_name == 'ENOENT' then
    return { missing = true }
  end
  return { missing = nil, err = err or err_name }
end

--- Whether {path} is a regular file, following a final symlink.
---
--- Returns nil when the target type cannot be determined (for example when an
--- ancestor directory is not searchable).  Callers should attempt the operation
--- in that case rather than rejecting a read-only file below /root.
--- @param path string
--- @param state table|nil Result of M.path_state(), if already available.
--- @return boolean|nil regular
--- @return string|nil kind
function M.is_regular_file(path, state)
  state = state or M.path_state(path)
  if state.missing == true then
    return nil, nil
  end

  local kind = state.type
  if kind == 'link' then
    local stat = vim.uv.fs_stat(path)
    if stat == nil then
      return nil, nil
    end
    kind = stat.type
  end
  if kind == nil then
    return nil, nil
  end
  return kind == 'file', kind
end

--- @param args string[]
--- @return integer|nil
local function probe_code(args)
  if vim.fn.executable('test') ~= 1 then
    return nil
  end
  local res = runner.probe(args)
  if res.signal ~= nil and res.signal ~= 0 then
    return nil
  end
  return res.code
end

--- Determine whether a path that the current user cannot inspect is a regular
--- file using a privileged `test` command.
--- @param path string
--- @return 'file'|'missing'|'other'|nil
function M.probe_kind(path)
  local exists = probe_code({ 'test', '-e', path })
  if exists == nil then
    return nil
  end
  if exists == 1 then
    return 'missing'
  end
  if exists ~= 0 then
    return nil
  end

  local regular = probe_code({ 'test', '-f', path })
  if regular == nil then
    return nil
  end
  if regular == 0 then
    return 'file'
  end
  if regular == 1 then
    return 'other'
  end
  return nil
end

return M
