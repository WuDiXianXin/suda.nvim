local M = {}

local function make_tempdir()
    -- uv_fs_mkdtemp() creates the directory atomically with mode 0700, avoiding
    -- a window where another user could create and own the predicted name.
    local dir, err = vim.uv.fs_mkdtemp(vim.fn.tempname() .. '-XXXXXX')
    if dir == nil then
        error(('[suda] failed to create temporary directory: %s'):format(err or 'unknown error'), 0)
    end
    pcall(vim.uv.fs_chmod, dir, 448) -- 0700
    return dir
end

local function io_error(action, path, err)
    error(('[suda] failed to %s %s: %s'):format(action, path, tostring(err or 'unknown error')), 0)
end

local function read_binary(path)
    local file, open_err = io.open(path, 'rb')
    if file == nil then
        io_error('open', path, open_err)
    end
    local data, read_err = file:read('*a')
    local close_ok, close_err = file:close()
    if data == nil then
        if read_err ~= nil then
            io_error('read', path, read_err)
        end
        data = ''
    end
    if not close_ok then
        io_error('close', path, close_err)
    end
    return data
end

local function write_binary(path, data)
    local file, open_err = io.open(path, 'wb')
    if file == nil then
        io_error('open', path, open_err)
    end
    local ok, write_err = file:write(data)
    if not ok then
        file:close()
        io_error('write', path, write_err)
    end
    local close_ok, close_err = file:close()
    if not close_ok then
        io_error('close', path, close_err)
    end
end

--- Read a file or a prefix of it. Used for encoding detection.
--- @param path string
--- @param limit integer|string|nil
--- @return string|nil data
--- @return string|nil err
local function read_file_data(path, limit)
    local file, open_err = io.open(path, 'rb')
    if file == nil then
        return nil, open_err
    end
    local data, read_err = file:read(limit or '*a')
    local close_ok, close_err = file:close()
    if data == nil then
        if read_err ~= nil then
            return nil, read_err
        end
        data = ''
    end
    if not close_ok then
        return nil, close_err
    end
    return data
end

--- @param path string
--- @param count integer
--- @return string|nil data
--- @return string|nil err
local function file_tail_data(path, count)
    local file, open_err = io.open(path, 'rb')
    if file == nil then
        return nil, open_err
    end
    local size, seek_err = file:seek('end')
    if size == nil then
        file:close()
        return nil, seek_err
    end
    local start = math.max(0, size - count)
    local pos, set_err = file:seek('set', start)
    if pos == nil then
        file:close()
        return nil, set_err
    end
    local data, read_err = file:read('*a')
    local close_ok, close_err = file:close()
    if data == nil then
        if read_err ~= nil then
            return nil, read_err
        end
        data = ''
    end
    if not close_ok then
        return nil, close_err
    end
    return data
end

M.make_tempdir = make_tempdir
M.read_binary = read_binary
M.write_binary = write_binary
M.read_file_data = read_file_data
M.file_tail_data = file_tail_data

return M
