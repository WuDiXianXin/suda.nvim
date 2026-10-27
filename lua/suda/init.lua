local M = {}

local config = require('suda.config')
local io = require('suda.io')
local runner = require('suda.runner')
local buffer = require('suda.buffer')
local smart_edit = require('suda.smart_edit')

local function expand_target(path)
    return io.normalize_target(tostring(path or ''))
end

local function command_target(arg)
    local path = arg ~= '' and arg or vim.api.nvim_buf_get_name(0)
    if path == '' then
        error('[suda] current buffer has no file name', 0)
    end
    return expand_target(path)
end

local function suda_read_command(args)
    local path = command_target(args.args)
    vim.api.nvim_cmd({
        cmd = 'edit',
        args = { 'suda://' .. path },
        magic = { file = false, bar = false },
    }, {})
end

local function suda_write_command(args)
    local path = command_target(args.args)
    vim.api.nvim_cmd({
        cmd = 'write',
        args = { 'suda://' .. path },
        magic = { file = false, bar = false },
    }, {})
end

--- Configure and initialize suda. Safe to call multiple times.
--- @param opts table|nil
function M.setup(opts)
    config.setup(opts)

    local group = vim.api.nvim_create_augroup('suda', { clear = true })
    local handlers = {
        BufReadCmd = buffer.bufread,
        FileReadCmd = buffer.fileread,
        BufWriteCmd = buffer.bufwrite,
        FileWriteCmd = buffer.filewrite,
        FileAppendCmd = buffer.fileappend,
    }

    vim.api.nvim_create_autocmd(vim.tbl_keys(handlers), {
        group = group,
        pattern = 'suda://*',
        callback = function(args)
            local handler = handlers[args.event]
            if handler ~= nil then
                handler(args)
            end
        end,
        desc = 'Read and write suda:// buffers',
    })

    vim.api.nvim_create_autocmd('BufFilePost', {
        group = group,
        callback = buffer.after_rename,
        desc = 'Keep suda:// buffers consistent after :saveas or :file',
    })

    vim.api.nvim_create_autocmd('CmdlineLeave', {
        group = group,
        callback = function()
            buffer.record_cmdline()
        end,
        desc = 'Remember typed :0read commands',
    })

    vim.api.nvim_create_user_command('SudaRead', suda_read_command, {
        nargs = '?',
        complete = 'file',
        desc = 'Edit a file with sudo',
        force = true,
    })
    vim.api.nvim_create_user_command('SudaWrite', suda_write_command, {
        nargs = '?',
        complete = 'file',
        desc = 'Write the current buffer with sudo',
        force = true,
    })

    smart_edit.setup(config.get().smart_edit)
end

--- Read a file into the current buffer using sudo if necessary.
--- @param expr string
--- @param opts table|nil
--- @return string message
--- @return table info
function M.read(expr, opts)
    local message, info = io.read(expr, opts)
    io.set_alternate(expr)
    return message, info
end

--- Write the current buffer to a file using sudo if necessary.
--- @param expr string
--- @param opts table|nil
--- @return string
function M.write(expr, opts)
    local name = vim.api.nvim_buf_get_name(0)
    local message = io.write(expr, opts)
    if name ~= '' and not io.same_path(expr, name) then
        io.set_alternate(expr)
    end
    return message
end

--- Append the current buffer to a file using sudo if necessary.
--- @param expr string
--- @param opts table|nil
--- @return string
function M.append(expr, opts)
    local name = vim.api.nvim_buf_get_name(0)
    local message = io.append(expr, opts)
    if name == '' or not io.same_path(expr, name) then
        io.set_alternate(expr)
    end
    return message
end

--- Run an argv list with sudo. Throws on a non-zero exit code.
--- @param cmd string[]
--- @param input string|nil
--- @return string stdout
function M.system(cmd, input)
    if type(cmd) ~= 'table' or #cmd == 0 then
        error('[suda] system() expects a non-empty list of arguments', 0)
    end
    for _, arg in ipairs(cmd) do
        if type(arg) ~= 'string' then
            error('[suda] system() arguments must be strings', 0)
        end
    end
    local res = runner.run(cmd, { stdin = input })
    return res.stdout
end

--- Run an argv list with sudo and split stdout into lines.
--- @param cmd string[]
--- @param input string|nil
--- @return string[]
function M.systemlist(cmd, input)
    local output = M.system(cmd, input):gsub('\r\n', '\n')
    local lines = vim.split(output, '\n', { plain = true })
    if lines[#lines] == '' then
        table.remove(lines)
    end
    return lines
end

M.strip_prefix = io.strip_prefix
M.normalize_target = io.normalize_target
M.same_path = io.same_path
M.flavor = runner.flavor

return M
