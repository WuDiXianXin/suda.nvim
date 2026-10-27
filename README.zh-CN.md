# suda.nvim

[English](README.md) | 简体中文

本文是 [README.md](README.md) 的中文翻译。如中英文内容不一致，以英文版为准。

在 Neovim 中读写需要 `sudo` 权限的文件，无需经过 shell。

本项目是 [lambdalisue/vim-suda](https://github.com/lambdalisue/vim-suda) 的 Neovim 0.12+ Lua 移植版。

项目实现完全使用 Lua；不支持 Vim 本身。

维护者：[WuDiXianXin](https://github.com/WuDiXianXin)

## 功能

- 提供 `:SudaRead` 和 `:SudaWrite` 命令。
- `suda://` 缓冲区可用于 `:edit`、`:read`、`:write`、`:w >>` 和 `:saveas`。
- 智能编辑：自动以 sudo 重新打开不可读或不可写的文件。
- 支持 `sudo`、`sudo-rs`、`doas` 以及自定义提权包装脚本。
- 不经过 shell，因此文件名中的空格、引号、`%`、`#`、`|` 和 `$()` 都是安全的。
- 密码通过 stdin 传给 sudo，绝不会通过 argv 或环境变量传递。
- 会触发常规的读取/写入/追加自动命令（`BufReadPre`、`BufWritePost`、`FileAppendPost` 等）。

## 环境要求

- Neovim 0.12 或更高版本。
- 一个提权命令：
  - `sudo` 或 `sudo-rs`；或
  - 配置为免密的 `doas`；或
  - 接受命令及其参数的自定义包装脚本。
- Unix 类系统：`dd`（通常来自 coreutils 或 busybox）以及用于特权读取的 `cat`。当 `dd` 不支持 `oflag=append` 时，`:w >>` 会回退使用 `tee`。
- 可选：`test`（通常来自 coreutils 或 busybox），用于不可搜索目录下的特权类型探测。
- 可选：sudo 1.8.21+，并在 sudoers 中设置 `Defaults timestamp_type = global`，以复用缓存的凭据。

## 安装

使用 `lazy.nvim`：

```lua
-- ~/.config/nvim/lua/plugins/suda.lua
return {
  {
    'WuDiXianXin/suda.nvim',
    -- 启动时加载，确保命令立即注册。
    lazy = false,
    config = function()
      require('suda').setup({
        smart_edit = true,
      })
    end,
  }
}
```

使用 `vim.pack`（Neovim 0.12+）：

```lua
vim.pack.add({
  'https://github.com/WuDiXianXin/suda.nvim',
})

require('suda').setup({
  smart_edit = true,
})
```

插件会在启动时注册命令。只有需要修改默认配置时才需要调用 `setup()`；全部选项见[配置](#配置)。

验证安装：

```vim
:checkhealth suda
```

完整手册见 `:help suda` 或 [doc/suda.txt](doc/suda.txt)。

## 用法

启用智能编辑（`smart_edit = true`）后，照常使用 `:e` 和 `:w` 编辑、保存文件即可。suda 仅在文件不可读或不可写时切换到 `suda://` 缓冲区。

详情见[智能编辑](#智能编辑)。

如果只想对单次操作提权，或已关闭智能编辑，可以使用以下命令：

```vim
" 以 sudo 重新打开当前文件
:SudaRead

" 打开仅 root 可读的文件
:SudaRead /etc/sudoers

" 以 sudo 保存当前缓冲区
:SudaWrite

" 以 sudo 将当前缓冲区写入另一个文件
:SudaWrite /etc/profile
```

这些操作也可以通过 `suda://` 名称完成：

```vim
" 通过 suda 打开当前文件
:e suda://%

" 编辑 /etc/sudoers
:e suda:///etc/sudoers

" 在当前光标位置下方读取 /etc/sudoers
:r suda:///etc/sudoers

" 在缓冲区末尾读取 /etc/sudoers
:$r suda:///etc/sudoers

" 写入整个缓冲区
:w suda:///etc/profile

" 写入第 1-10 行（指定范围需要 !）
:1,10w! suda:///etc/profile

" 以 sudo 将整个缓冲区追加到日志文件
:w >> suda:///var/log/example.log

" 重命名缓冲区并以 sudo 保存
:saveas suda:///etc/profile
```

`suda://` 缓冲区的 `'buftype'` 为 `acwrite`，会禁用 `'swapfile'` 和 `'undofile'`，并在缓冲区名称中保留真实路径。

目标文件不存在时，会以空缓冲区打开，并在首次成功写入时创建。

如果祖先目录不可搜索（例如 `/root`），suda 无法区分“文件不存在”和“没有权限检查”，此时不会静默打开空缓冲区；
请使用 `:SudaWrite` 在此类目录中创建文件。使用 `:saveas` 或 `:file` 将缓冲区重命名为普通路径后，会恢复为普通缓冲区。

检测到的 `'bomb'`、`'fileencoding'`、`'fileformat'` 和 `'endofline'` 会被保留。

UTF-8、UTF-16、UTF-32 BOM 以及 UTF-8/Latin-1 文本会自动识别。
其他编码可以在打开缓冲区时显式指定，例如 `:edit ++enc=latin1 suda:///path/to/file`。
二进制文件请使用 `:edit ++bin suda:///path/to/file`，跳过编码和换行符转换。

在 Unix 上，现有文件通过 `dd` 覆盖写入，因此会保留 inode、所有者、权限和符号链接。

`:w >>` 优先使用 `dd oflag=append`；如果本地的 `dd` 不支持追加模式，则回退到 `tee -a`。

写入不是原子操作；复制中断可能留下不完整的文件。

## 配置

```lua
require('suda').setup({
  executable = 'sudo',      -- 提权命令或绝对路径
  flavor = 'auto',          -- 'auto' | 'sudo' | 'doas' | 'custom'
  prompt = 'Password: ',    -- 默认密码输入函数的提示符
  noninteractive = false,   -- 永不提示密码；使用缓存凭据或免密配置
  smart_edit = false,       -- 将不可读/不可写的文件重新打开为 suda:// 缓冲区
  checktime = true,         -- 写入成功后执行 :checktime
  timeout = nil,            -- 外部命令超时时间（毫秒）；nil 表示不限制
  debug = false,            -- 记录完整命令行
  prompt_password = function(prompt)
    return vim.fn.inputsecret(prompt)
  end,
})
```

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `executable` | `"sudo"` | 提权命令或绝对路径。 |
| `flavor` | `"auto"` | 调用方式。`auto` 会自动识别 `sudo`、`sudo-rs` 和 `doas`。 |
| `prompt` | `"Password: "` | 默认密码输入函数使用的提示符。 |
| `noninteractive` | `false` | 永不提示密码；依赖缓存凭据或免密配置。 |
| `smart_edit` | `false` | 将不可读/不可写的文件重新打开为 `suda://` 缓冲区。 |
| `checktime` | `true` | 写入成功后执行 `:checktime`。 |
| `timeout` | `nil` | 每个外部命令的超时时间，单位毫秒。必须是非负整数。 |
| `debug` | `false` | 使用 `vim.notify()` 记录完整命令行。 |
| `prompt_password` | `inputsecret()` | 返回密码；返回 `nil`/`""` 表示取消。 |

未知选项会被忽略，并输出一条警告。`timeout = 0` 会立即超时；如需禁用命令超时，请保持 `nil`。

`flavor = "sudo"` 会先用 `sudo -n -- true` 探测；
如有需要则提示输入密码，并通过 `sudo -p '' -S -v` 验证，然后以 `sudo -n -- ...` 执行真正的命令。

`flavor = "doas"` 直接调用 `doas`，在非交互模式下会加上 `-n`。
`flavor = "custom"` 不添加任何选项，由包装脚本自行处理认证。

### 旧版变量

旧版全局变量仍然有效。大多数变量会在每次执行命令时读取；`g:suda_smart_edit` 需要在插件加载前设置，或在修改后调用 `setup()`。显式传入 `setup()` 的选项优先级更高。

| 变量 | 说明 |
| --- | --- |
| `g:suda#executable`, `g:suda_executable` | 提权命令。 |
| `g:suda#prompt`, `g:suda_prompt` | 密码提示符。 |
| `g:suda#noninteractive`, `g:suda_noninteractive`, `g:suda#nopass`, `g:suda_nopass` | 禁用密码提示。 |
| `g:suda_smart_edit` | 启用智能编辑。 |

在 Lua 中，名称包含 `#` 时需要使用方括号语法：

```lua
vim.g['suda#executable'] = '/usr/local/bin/sudo'
```

## 智能编辑

启用方式：

```lua
require('suda').setup({ smart_edit = true })
```

或者：

```vim
let g:suda_smart_edit = 1
```

之后使用 `nvim /etc/hosts` 或 `:e /etc/shadow` 时，文件会通过 `suda://` 打开。

该检查比较保守：

- 可读且可写的文件保持普通缓冲区；
- 如果新文件最近的现有父目录可写，则不会拦截；
- 已修改的缓冲区不会被处理。

目录和 URI 形式的缓冲区名称会被忽略。

当读取不可读文件失败时，Neovim 不会触发 `BufEnter`，因此 suda 还会在 `BufAdd` 时安排一次检查。所以切换可能发生在 `:edit` 返回后不久。

## Lua API

```lua
local suda = require('suda')

suda.setup(opts)                 -- 配置并注册命令
suda.read(expr, opts)            -- 读取到当前缓冲区
suda.write(expr, opts)           -- 写入当前缓冲区
suda.append(expr, opts)          -- 追加当前缓冲区
suda.system(cmd, input)          -- 以 sudo 运行 argv，返回标准输出
suda.systemlist(cmd, input)      -- 同上，将标准输出拆分为行
suda.strip_prefix(expr)          -- 移除 suda:// 前缀
suda.normalize_target(expr)      -- 展开 $VAR、~、%、#，并转换为绝对路径
suda.same_path(left, right)      -- 比较缓冲区名称/路径
suda.flavor()                    -- 实际生效的 flavor
```

`suda.read()` 接受 `range`、`cmdarg` 和 `encoding` 选项。`encoding` 用于显式指定文件编码（例如 `utf-16le`）。在命令行输入的 `:0read suda://...` 可以被识别；
映射或脚本中的直接 `:0read` 不会被识别，如需 `:0read` 语义请调用 `suda.read(..., { range = '0' })`。

`suda.write()` 和 `suda.append()` 还接受 `cmdbang`。

Lua 辅助函数会像对应的内置命令一样更新 alternate file 和 `'modified'`，但会直接执行 I/O，不会触发 `Buf*`/`File*` 自动命令；需要自动命令时请使用命令或 `suda://` 缓冲区。

`read()` 返回 `:read` 的消息，以及包含 `endofline`、`fileformat`、`fileencoding` 和 `bomb` 字段的信息表；

`write()` 和 `append()` 返回 `:write` 的消息。

这三个函数在失败时都会抛出错误；

`system()` 在退出状态非零时抛出错误。

当 `system()` 没有传入输入参数时，stdin 为空，而不是继承终端输入。

## 安全说明

- 每个外部命令都接收 argv 列表；不会调用 shell。
- 密码通过 `-S` 写入 sudo 的 stdin，不会被存储。
- 临时文件位于权限为 0700 的私有目录中，并在使用后删除。其内容仍会短暂存在于磁盘上。
- `dd`/`tee` 通过现有 inode 写入，但不是原子操作。
- 缓存 sudo 凭据是一种安全权衡。建议使用较短的 `timestamp_timeout`，并评估 `timestamp_type = global` 是否适合你的系统。
- `debug = true` 会记录命令行（包括文件名），但绝不会记录密码。

## 故障排查

- **`E37: No write since last change`**：`:SudaRead` 使用 `:edit`。请先保存或放弃修改。
- **`E139: File is loaded in another buffer`**：目标文件（包括其 `suda://` 缓冲区）已经在另一个缓冲区中打开。请切换到该缓冲区，或使用 `:bdelete` 删除它。
- **`E140: Use ! to write partial buffer`**：按范围写入需要加 `!`，例如 `:1,10w! suda:///etc/profile`。
- **`[suda] authentication failed`**：检查在终端中执行 `sudo -v` 是否正常，并确认 sudoers 没有使用 `requiretty`。
- **智能编辑没有切换**：该功能默认关闭；可写目录中的新文件会被有意跳过。
- **写入成功但缓冲区仍显示已修改**：目标文件不是该缓冲区自身的文件，或使用了范围写入。请不带参数执行 `:SudaWrite`，将整个缓冲区写回。

运行 `:checkhealth suda` 查看诊断报告。

## 测试

测试套件以无头模式（headless）运行，并使用一个模拟的 sudo 实现。模拟的可执行文件需要 Python 3。
测试套件以普通用户身份运行于 Unix 类系统，因为它使用权限模式模拟特权文件。它还需要 `dd`、`cat`、`tee`、`test`、`mkfifo` 以及 POSIX shell。

```bash
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
stylua --check lua plugin tests
```

`doc/tags` 已提交到仓库，因此无需额外步骤即可使用 `:help suda`。修改 `doc/suda.txt` 后，请重新生成：

```bash
nvim --headless -u NONE -c 'helptags doc' -c 'qa!'
```

## 限制

- 仅支持 Neovim 0.12+；不支持 Vim。
- 未实现交互式 doas 认证；请使用免密 doas。
- 只读写普通文件及其符号链接；FIFO、socket 和设备文件会被拒绝。
- 不可搜索目录下的路径会在可用时通过特权 `test` 探测类型；没有 `test` 的系统无法识别其中的特殊文件，请防御性设置 `timeout`。
- 特权类型探测和随后的读/写是两个独立操作，路径可能在两者之间被替换；对于其他用户可写的目录，请设置 `timeout`。
- 写入和追加不是原子操作。
- 读写会把整个文件放入内存；超大文件可能较慢或占用较多内存。编码检测会扫描可读文件以校验 UTF-8。
- 外部命令默认没有超时。如果命令可能挂起，请设置 `timeout`。
- append 探测使用 Neovim PATH 中的 `dd`；如果 sudo 的 `secure_path` 选择了不同的 `dd`，可能需要 `tee -a` 回退。
- 智能编辑会保留 `++bin` 和已加载缓冲区的选项。读取失败后 Neovim 不会暴露显式的 `++enc`，因此智能编辑重新打开不可读文件时无法恢复该选项。

## 许可证

MIT 许可证。详见 [LICENSE](LICENSE)。

原始项目版权 2017 Alisue, hashnote.net。
Neovim 移植版权 2026 WuDiXianXin。
