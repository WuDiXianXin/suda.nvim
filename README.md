# suda.nvim

English | [简体中文](README.zh-CN.md)

Read and write files that require `sudo` from Neovim, without going through a shell.

This is a Neovim 0.12+ Lua port of [lambdalisue/vim-suda](https://github.com/lambdalisue/vim-suda).
The implementation is Lua only; Vim itself is not supported.

Maintainer: [WuDiXianXin](https://github.com/WuDiXianXin)

## Features

- `:SudaRead` and `:SudaWrite` commands.
- `suda://` buffers usable with `:edit`, `:read`, `:write`, `:w >>`, and `:saveas`.
- Smart edit: automatically reopen unreadable or unwritable files with sudo.
- Supports `sudo`, `sudo-rs`, `doas`, and custom privilege wrappers.
- No shell is involved, so spaces, quotes, `%`, `#`, `|`, and `$()` in file names are safe.
- Passwords are sent to sudo over stdin, never through argv or the environment.
- Fires the usual read/write/append autocommands (`BufReadPre`, `BufWritePost`, `FileAppendPost`, ...).

## Requirements

- Neovim 0.12 or newer.
- A privilege escalation command:
  - `sudo` or `sudo-rs`, or
  - `doas` with passwordless configuration, or
  - a custom wrapper that accepts a command and its arguments.
- Unix-like systems: `dd` (usually from coreutils or busybox) and `cat` for privileged reads. `tee` is used as a fallback for `:w >>` when `dd` does not support `oflag=append`.
- Optional: `test` (normally from coreutils or busybox) for privileged type probing below unsearchable directories.
- Optional: sudo 1.8.21+ with `Defaults timestamp_type = global` in sudoers to reuse cached credentials.

## Installation

With `lazy.nvim`:

```lua
-- ~/.config/nvim/lua/plugins/suda.lua
return {
  {
    'WuDiXianXin/suda.nvim',
    -- Load at startup so the commands are registered immediately.
    lazy = false,
    config = function()
      require('suda').setup({
        smart_edit = true,
      })
    end,
  }
}
```

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({
  'https://github.com/WuDiXianXin/suda.nvim',
})

require('suda').setup({
  smart_edit = true,
})
```

The plugin registers its commands at startup. `setup()` is only needed to change the defaults;
see [Configuration](#configuration) for all options.

Verify the installation with:

```vim
:checkhealth suda
```

See `:help suda` or [doc/suda.txt](doc/suda.txt) for the full manual.

## Usage

With smart edit enabled (`smart_edit = true`), edit and write files as usual with `:e` and `:w`.
suda switches to a `suda://` buffer only when the file is not readable or writable.

See [Smart edit](#smart-edit) for details.

Use the commands below to escalate a single operation,
or when smart edit is disabled:

```vim
" Re-open the current file with sudo
:SudaRead

" Open a root-only file
:SudaRead /etc/sudoers

" Save the current buffer with sudo
:SudaWrite

" Write the current buffer to another file with sudo
:SudaWrite /etc/profile
```

The same operations work through `suda://` names:

```vim
" Open the current file through suda
:e suda://%

" Edit /etc/sudoers
:e suda:///etc/sudoers

" Read /etc/sudoers below the cursor
:r suda:///etc/sudoers

" Read /etc/sudoers at the end of the buffer
:$r suda:///etc/sudoers

" Write the whole buffer
:w suda:///etc/profile

" Write lines 1-10 (a range requires !)
:1,10w! suda:///etc/profile

" Append the whole buffer to a log file with sudo
:w >> suda:///var/log/example.log

" Rename the buffer and save it with sudo
:saveas suda:///etc/profile
```

A `suda://` buffer uses `'buftype'` `acwrite`,
disables `'swapfile'` and `'undofile'`,
and keeps the real path inside the buffer name.
A missing target opens as an empty buffer and is created by the first successful write.
If an ancestor directory is not searchable (for example `/root`),
suda cannot tell a missing file from an inaccessible one and does not silently open an empty buffer;
use `:SudaWrite` to create a file in such a directory.
Renaming the buffer to an ordinary path with `:saveas` or `:file` restores a normal buffer.

Detected `'bomb'`, `'fileencoding'`, `'fileformat'`, and `'endofline'` are preserved.
UTF-8, UTF-16, and UTF-32 BOMs and UTF-8/Latin-1 text are detected automatically.
For other encodings, open the buffer with an explicit encoding,
for example `:edit ++enc=latin1 suda:///path/to/file`.
For binary files, use `:edit ++bin suda:///path/to/file` to skip encoding and line-ending conversion.

On Unix, existing files are overwritten with `dd`,
which preserves the inode, owner, permissions, and symlinks.
`:w >>` prefers `dd oflag=append` and falls back to `tee -a` when the local `dd` does not support append mode.
Writes are not atomic;
an interrupted copy can leave a partial file.

## Configuration

```lua
require('suda').setup({
  executable = 'sudo',      -- privilege command or absolute path
  flavor = 'auto',          -- 'auto' | 'sudo' | 'doas' | 'custom'
  prompt = 'Password: ',    -- prompt for the default password function
  noninteractive = false,   -- never prompt; use cached or NOPASSWD credentials
  smart_edit = false,       -- reopen unreadable/unwritable files via suda
  checktime = true,         -- run :checktime after a successful write
  timeout = nil,            -- external command timeout in ms; nil disables
  debug = false,            -- log full command lines
  prompt_password = function(prompt)
    return vim.fn.inputsecret(prompt)
  end,
})
```

| Option            | Default          | Description                                                                 |
| ----------------- | ---------------- | --------------------------------------------------------------------------- |
| `executable`      | `"sudo"`         | Privilege command or an absolute path.                                      |
| `flavor`          | `"auto"`         | How to invoke it. `auto` detects `sudo`, `sudo-rs`, and `doas`.             |
| `prompt`          | `"Password: "`   | Prompt used by the default password function.                               |
| `noninteractive`  | `false`          | Never prompt; rely on cached or passwordless credentials.                   |
| `smart_edit`      | `false`          | Reopen unreadable/unwritable files as `suda://` buffers.                    |
| `checktime`       | `true`           | Run `:checktime` after a successful write.                                  |
| `timeout`         | `nil`            | Timeout for each external command, in milliseconds. Must be a non-negative integer. |
| `debug`           | `false`          | Log full command lines with `vim.notify()`.                                 |
| `prompt_password` | `inputsecret()`  | Return a password, or `nil`/`""` to cancel.                                 |

Unknown option keys are ignored with a warning. A `timeout` of `0` expires immediately;
leave it `nil` to disable command timeouts.

`flavor = "sudo"` probes with `sudo -n -- true`,
prompts if needed, validates with `sudo -p '' -S -v`,
then runs the real command as `sudo -n -- ...`.
`flavor = "doas"` calls `doas` directly,
adding `-n` in noninteractive mode.
`flavor = "custom"` adds no options and lets the wrapper handle authentication.

### Legacy variables

The old globals are still honored.
Most are checked each time a command runs.
Set `g:suda_smart_edit` before the plugin loads,
or call `setup()` after changing it.
Explicit `setup()` options take precedence.

| Variable                                                                                  | Description          |
| ----------------------------------------------------------------------------------------- | -------------------- |
| `g:suda#executable`, `g:suda_executable`                                                  | Privilege command.   |
| `g:suda#prompt`, `g:suda_prompt`                                                          | Password prompt.     |
| `g:suda#noninteractive`, `g:suda_noninteractive`, `g:suda#nopass`, `g:suda_nopass`        | Disable prompting.   |
| `g:suda_smart_edit`                                                                       | Enable smart edit.   |

In Lua, use bracket syntax for names containing `#`:

```lua
vim.g['suda#executable'] = '/usr/local/bin/sudo'
```

## Smart edit

Enable it with:

```lua
require('suda').setup({ smart_edit = true })
```

or:

```vim
let g:suda_smart_edit = 1
```

Then `nvim /etc/hosts` or `:e /etc/shadow` opens the file through `suda://`.
The check is conservative: readable and writable files stay normal,
a new file whose nearest existing parent directory is writable is not intercepted,
and modified buffers are left alone.
Directories and URI-style buffer names are ignored.

Neovim does not fire `BufEnter` when reading an unreadable file fails,
so suda also schedules a check from `BufAdd`.
The switch can therefore happen just after `:edit` returns.

## Lua API

```lua
local suda = require('suda')

suda.setup(opts)                 -- configure and register commands
suda.read(expr, opts)            -- read into the current buffer
suda.write(expr, opts)           -- write the current buffer
suda.append(expr, opts)          -- append the current buffer
suda.system(cmd, input)          -- run argv with sudo, return stdout
suda.systemlist(cmd, input)      -- same, split stdout into lines
suda.strip_prefix(expr)          -- remove suda:// prefixes
suda.normalize_target(expr)      -- expand $VAR, ~, %, #, and make absolute
suda.same_path(left, right)      -- compare buffer names/paths
suda.flavor()                    -- effective flavor
```

`suda.read()` accepts `range`, `cmdarg`, and `encoding` options.
`encoding` selects an explicit file encoding (for example `utf-16le`).
A typed `:0read suda://...` is recognized from the command line.
Direct `:0read` from mappings or scripts is not detected;
use `suda.read(..., { range = '0' })` instead.
`suda.write()` and `suda.append()` also accept `cmdbang`.
The Lua helpers update the alternate file and `'modified'` like the
corresponding built-in commands, but they perform the I/O directly and do not
fire `Buf*`/`File*` autocommands; use the commands or `suda://` buffers when
autocommands are required.
`read()` returns the `:read` message plus an info table with `endofline`, `fileformat`, `fileencoding`, and `bomb` fields;
`write()` and `append()` return the `:write` message.
All three throw an error on failure;
`system()` throws on a non-zero exit status.
When `system()` has no input argument,
stdin is empty rather than inherited from the terminal.

## Security notes

- Every external command receives an argv list; no shell is invoked.
- The password is written to sudo's stdin with `-S` and is not stored.
- Temporary files live in a private 0700 directory and are deleted after use. Their contents are still on disk briefly.
- `dd`/`tee` write through the existing inode but are not atomic.
- Cached sudo credentials are a security trade-off.
  Prefer a short `timestamp_timeout` and review whether `timestamp_type = global` is appropriate for your system.
- `debug = true` logs command lines, including file names, but never passwords.

## Troubleshooting

- **`E37: No write since last change`**: `:SudaRead` uses `:edit`. Save or discard changes first.
- **`E139: File is loaded in another buffer`**: the target, including its `suda://` buffer, is already open.
  Switch to that buffer or delete it with `:bdelete`.
- **`E140: Use ! to write partial buffer`**: ranged writes need a bang, e.g. `:1,10w! suda:///etc/profile`.
- **`[suda] authentication failed`**: check that `sudo -v` works in a terminal, and that sudoers does not use `requiretty`.
- **Smart edit does not switch**: it is disabled by default, and new files in writable directories are intentionally left alone.
- **A write succeeds but the buffer stays modified**: the target is not the buffer's own file, or a ranged write was used.
  Use `:SudaWrite` with no argument to write the whole buffer back.

Run `:checkhealth suda` for a diagnostic report.

## Testing

The test suite is headless and uses a fake sudo implementation. Python 3 is
required for the fake executable. The suite runs on Unix-like systems as a
normal user, because it uses permission modes to simulate privileged files.
It also requires `dd`, `cat`, `tee`, `test`, `mkfifo`, and a POSIX shell.

```bash
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
stylua --check lua plugin tests
```

`doc/tags` is committed so `:help suda` works without extra setup. After
editing `doc/suda.txt`, regenerate it with:

```bash
nvim --headless -u NONE -c 'helptags doc' -c 'qa!'
```

## Limitations

- Neovim 0.12+ only; Vim is not supported.
- Interactive doas authentication is not implemented; use passwordless doas.
- Only regular files and symlinks to them are read or written. FIFOs, sockets,
  and device files are rejected.
- Paths below an unsearchable directory are classified with a privileged `test`
  probe when available. Systems without `test` cannot detect special files
  there; set `timeout` defensively.
- The privileged type probe and the following read/write are separate
  operations; a path can change between them. Use `timeout` for paths in
  directories writable by other users.
- Writes and appends are not atomic.
- Reads and writes buffer the whole file in memory; very large files may be
  slow or memory-heavy. Encoding detection scans readable files for UTF-8.
- External commands have no timeout by default. Set `timeout` if a command may
  hang.
- The append probe uses the `dd` found on Neovim's PATH. A different `dd`
  selected by sudo's `secure_path` may require the `tee -a` fallback.
- Smart edit preserves `++bin` and the options of a loaded buffer. Neovim does
  not expose an explicit `++enc` after a failed read, so that option cannot be
  recovered when smart edit reopens an unreadable file.

## License

MIT license. See [LICENSE](LICENSE).

Original project copyright 2017 Alisue, hashnote.net.
Neovim port copyright 2026 WuDiXianXin.
