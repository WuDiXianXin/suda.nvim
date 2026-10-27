local M = {}

local temp = require('suda.temp')
local read_file_data = temp.read_file_data

local function valid_utf8(data, allow_incomplete)
  local i = 1
  local len = #data
  while i <= len do
    local b1 = data:byte(i)
    if b1 <= 0x7F then
      i = i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
      local b2 = data:byte(i + 1)
      if b2 == nil then
        return allow_incomplete == true
      end
      if b2 < 0x80 or b2 > 0xBF then
        return false
      end
      i = i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then
      local b2, b3 = data:byte(i + 1, i + 2)
      if b2 == nil or b3 == nil then
        return allow_incomplete == true
      end
      local min2, max2 = 0x80, 0xBF
      if b1 == 0xE0 then
        min2 = 0xA0
      elseif b1 == 0xED then
        max2 = 0x9F
      end
      if b2 < min2 or b2 > max2 or b3 < 0x80 or b3 > 0xBF then
        return false
      end
      i = i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4 then
      local b2, b3, b4 = data:byte(i + 1, i + 2, i + 3)
      if b2 == nil or b3 == nil or b4 == nil then
        return allow_incomplete == true
      end
      local min2, max2 = 0x80, 0xBF
      if b1 == 0xF0 then
        min2 = 0x90
      elseif b1 == 0xF4 then
        max2 = 0x8F
      end
      if b2 < min2 or b2 > max2 or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then
        return false
      end
      i = i + 4
    else
      return false
    end
  end
  return true
end

--- Validate a whole file as UTF-8 without loading it into memory.
--- @param path string
--- @return boolean|nil valid
--- @return string|nil err
local function valid_utf8_stream(path)
  local file, open_err = io.open(path, 'rb')
  if file == nil then
    return nil, open_err
  end

  local expected = 0
  local first_continuation = false
  local min2, max2 = 0x80, 0xBF

  local function feed(data)
    local i = 1
    while i <= #data do
      local byte = data:byte(i)
      if expected == 0 then
        if byte <= 0x7F then
          -- ASCII
        elseif byte >= 0xC2 and byte <= 0xDF then
          expected = 1
          first_continuation = true
          min2, max2 = 0x80, 0xBF
        elseif byte >= 0xE0 and byte <= 0xEF then
          expected = 2
          first_continuation = true
          min2, max2 = 0x80, 0xBF
          if byte == 0xE0 then
            min2 = 0xA0
          elseif byte == 0xED then
            max2 = 0x9F
          end
        elseif byte >= 0xF0 and byte <= 0xF4 then
          expected = 3
          first_continuation = true
          min2, max2 = 0x80, 0xBF
          if byte == 0xF0 then
            min2 = 0x90
          elseif byte == 0xF4 then
            max2 = 0x8F
          end
        else
          return false
        end
      else
        local low = first_continuation and min2 or 0x80
        local high = first_continuation and max2 or 0xBF
        if byte < low or byte > high then
          return false
        end
        expected = expected - 1
        first_continuation = false
      end
      i = i + 1
    end
    return true
  end

  while true do
    local data, read_err = file:read(65536)
    if data == nil then
      if read_err ~= nil then
        file:close()
        return nil, read_err
      end
      break
    end
    if not feed(data) then
      file:close()
      return false
    end
  end

  local close_ok, close_err = file:close()
  if not close_ok then
    return nil, close_err
  end
  return expected == 0
end

local encoding_boms = {
  { bytes = '\0\0\254\255', encoding = 'utf-32be' },
  { bytes = '\255\254\0\0', encoding = 'utf-32le' },
  { bytes = '\254\255', encoding = 'utf-16be' },
  { bytes = '\255\254', encoding = 'utf-16le' },
  { bytes = '\239\187\191', encoding = 'utf-8' },
}

local function is_wide_encoding(encoding)
  return encoding == 'utf-16le'
    or encoding == 'utf-16be'
    or encoding == 'utf-32le'
    or encoding == 'utf-32be'
end

--- Detect a supported BOM.
--- @param data string|nil
--- @return table|nil { fileencoding: string, bomb: boolean }
local function detect_bom(data)
  if data == nil then
    return nil
  end
  for _, bom in ipairs(encoding_boms) do
    if data:sub(1, #bom.bytes) == bom.bytes then
      return { fileencoding = bom.encoding, bomb = true }
    end
  end
  return nil
end

--- Detect a BOM or fall back to UTF-8/Latin-1, matching the common Vim
--- 'fileencodings' default. Other encodings can be selected with ++enc.
--- @param data string|nil
--- @param allow_incomplete boolean|nil
--- @return table|nil { fileencoding: string, bomb: boolean }
local function detect_encoding(data, allow_incomplete)
  if data == nil then
    return nil
  end
  local bom = detect_bom(data)
  if bom ~= nil then
    return bom
  end
  if valid_utf8(data, allow_incomplete) then
    return { fileencoding = 'utf-8', bomb = false }
  end
  return { fileencoding = 'latin1', bomb = false }
end

--- Detect BOM/UTF-8/Latin-1 for a readable file. The UTF-8 check streams over
--- the whole file so a Latin-1 byte after the first megabyte is not missed.
--- @param path string
--- @param bom_only boolean|nil
--- @return table|nil
--- @return string|nil err
local function detect_encoding_readable(path, bom_only)
  local header, header_err = read_file_data(path, 4)
  if header == nil then
    return nil, header_err
  end

  local detected = detect_encoding(header, true)
  if detected and detected.bomb then
    return detected
  end
  if bom_only then
    return nil
  end

  local valid, stream_err = valid_utf8_stream(path)
  if valid == nil then
    return nil, stream_err
  end
  if valid then
    return { fileencoding = 'utf-8', bomb = false }
  end
  return { fileencoding = 'latin1', bomb = false }
end

--- @param encoding string
--- @return integer
local function wide_unit_size(encoding)
  if encoding == 'utf-32le' or encoding == 'utf-32be' then
    return 4
  end
  return 2
end

--- @param data string
--- @param index integer 1-based byte offset
--- @param encoding string
--- @return integer|nil
local function wide_codepoint(data, index, encoding)
  if encoding == 'utf-16le' then
    local b1, b2 = data:byte(index, index + 1)
    if b1 == nil or b2 == nil then
      return nil
    end
    return b1 + b2 * 256
  end
  if encoding == 'utf-16be' then
    local b1, b2 = data:byte(index, index + 1)
    if b1 == nil or b2 == nil then
      return nil
    end
    return b1 * 256 + b2
  end
  if encoding == 'utf-32le' then
    local b1, b2, b3, b4 = data:byte(index, index + 3)
    if b1 == nil or b2 == nil or b3 == nil or b4 == nil then
      return nil
    end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  end
  if encoding == 'utf-32be' then
    local b1, b2, b3, b4 = data:byte(index, index + 3)
    if b1 == nil or b2 == nil or b3 == nil or b4 == nil then
      return nil
    end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  end
  return nil
end

--- Detect the fileformat of UTF-16/32 data without converting NUL bytes
--- through Vimscript, which cannot represent them as strings.
--- @param data string|nil
--- @param encoding string|nil
--- @return 'unix'|'dos'|'mac'
local function wide_fileformat(data, encoding)
  data = data or ''
  local step = wide_unit_size(encoding)
  local index = 1
  local previous = nil
  while index + step - 1 <= #data do
    local codepoint = wide_codepoint(data, index, encoding)
    if codepoint == 0x0A then
      return previous == 0x0D and 'dos' or 'unix'
    end
    previous = codepoint
    index = index + step
  end

  index = 1
  while index + step - 1 <= #data do
    if wide_codepoint(data, index, encoding) == 0x0D then
      return 'mac'
    end
    index = index + step
  end
  return 'unix'
end

--- Streaming variant of wide_fileformat() for readable files.
--- @param path string
--- @param encoding string
--- @return 'unix'|'dos'|'mac'|nil
--- @return string|nil err
local function wide_fileformat_file(path, encoding)
  local file, open_err = io.open(path, 'rb')
  if file == nil then
    return nil, open_err
  end

  local step = wide_unit_size(encoding)
  local pending = ''
  local previous = nil
  local saw_cr = false

  while true do
    local data, read_err = file:read(65536)
    if data == nil then
      if read_err ~= nil then
        file:close()
        return nil, read_err
      end
      break
    end

    pending = pending .. data
    local index = 1
    while index + step - 1 <= #pending do
      local codepoint = wide_codepoint(pending, index, encoding)
      if codepoint == 0x0A then
        file:close()
        return previous == 0x0D and 'dos' or 'unix'
      end
      if codepoint == 0x0D then
        saw_cr = true
      end
      previous = codepoint
      index = index + step
    end
    pending = pending:sub(index)
  end

  local close_ok, close_err = file:close()
  if not close_ok then
    return nil, close_err
  end
  return saw_cr and 'mac' or 'unix'
end

--- @param data string|nil
--- @param encoding string|nil
--- @param fileformat string|nil
--- @return boolean
local function wide_endofline(data, encoding, fileformat)
  data = data or ''
  local step = wide_unit_size(encoding)
  if #data < step then
    return true
  end
  if #data == step and wide_codepoint(data, 1, encoding) == 0xFEFF then
    return true
  end
  local codepoint = wide_codepoint(data, #data - step + 1, encoding)
  if codepoint == nil then
    return true
  end
  return codepoint == 0x0A or (fileformat == 'mac' and codepoint == 0x0D)
end

--- Replace CR code units with LF for legacy Mac files, preserving the
--- original UTF-16/32 byte order.
--- @param data string
--- @param encoding string
--- @return string
local function wide_cr_to_lf(data, encoding)
  local step = wide_unit_size(encoding)
  local lf
  if encoding == 'utf-16le' then
    lf = '\n\0'
  elseif encoding == 'utf-16be' then
    lf = '\0\n'
  elseif encoding == 'utf-32le' then
    lf = '\n\0\0\0'
  else
    lf = '\0\0\0\n'
  end

  local out = {}
  local index = 1
  while index + step - 1 <= #data do
    if wide_codepoint(data, index, encoding) == 0x0D then
      out[#out + 1] = lf
    else
      out[#out + 1] = data:sub(index, index + step - 1)
    end
    index = index + step
  end
  if index <= #data then
    out[#out + 1] = data:sub(index)
  end
  return table.concat(out)
end

--- Add ++enc to a :read/:write cmdarg unless the caller already supplied one.
--- @param cmdarg string|nil
--- @param encoding string|nil
--- @return string|nil
local function append_encoding(cmdarg, encoding)
  if encoding == nil or encoding == '' then
    return cmdarg
  end
  if cmdarg ~= nil and cmdarg:match('%+%+enc=') then
    return cmdarg
  end
  if cmdarg == nil or cmdarg == '' then
    return '++enc=' .. encoding
  end
  return cmdarg .. ' ++enc=' .. encoding
end

--- Whether a file ends with a line ending. :read does not update 'endofline'
--- from the file it reads, so BufReadCmd has to restore that information.
--- @param path string
--- @param fileformat string|nil
--- @param bomb boolean|nil
--- @return boolean
local function file_endofline(path, fileformat, bomb)
  local file = io.open(path, 'rb')
  if file == nil then
    return true
  end
  local size = file:seek('end')
  if size == nil or size == 0 then
    file:close()
    return true
  end
  if bomb == true and size == 3 then
    -- A file containing only a UTF-8 BOM is an empty file, like :edit treats it.
    file:close()
    return true
  end
  local pos = file:seek('end', -1)
  if pos == nil then
    file:close()
    return true
  end
  local last = file:read(1)
  file:close()
  return last == '\n' or (fileformat == 'mac' and last == '\r')
end

--- @param data string
--- @param fileformat string|nil
--- @param bomb boolean|nil
--- @return boolean
local function data_endofline(data, fileformat, bomb)
  if data == '' then
    return true
  end
  if bomb == true and #data == 3 then
    return true
  end
  local last = data:sub(-1)
  return last == '\n' or (fileformat == 'mac' and last == '\r')
end

--- Detect the fileformat in the same way as :edit: the first line decides.
--- @param data string
--- @return 'unix'|'dos'|'mac'
local function data_fileformat(data)
  local newline = data:find('\n', 1, true)
  if newline == nil then
    if data:find('\r', 1, true) ~= nil then
      return 'mac'
    end
    return 'unix'
  end
  if newline > 1 and data:sub(newline - 1, newline - 1) == '\r' then
    return 'dos'
  end
  return 'unix'
end

--- @param path string
--- @return 'unix'|'dos'|'mac'|nil
local function file_fileformat(path)
  local file = io.open(path, 'rb')
  if file == nil then
    return nil
  end

  local previous = nil
  local saw_cr = false
  while true do
    local data, read_err = file:read(8192)
    if data == nil then
      if read_err ~= nil then
        file:close()
        return nil
      end
      break
    end
    for i = 1, #data do
      local byte = data:byte(i)
      if byte == 0x0A then
        file:close()
        return previous == 0x0D and 'dos' or 'unix'
      end
      if byte == 0x0D then
        saw_cr = true
      end
      previous = byte
    end
  end

  local close_ok = file:close()
  if not close_ok then
    return nil
  end
  return saw_cr and 'mac' or 'unix'
end

M.is_wide_encoding = is_wide_encoding
M.detect_bom = detect_bom
M.detect_encoding = detect_encoding
M.detect_encoding_readable = detect_encoding_readable
M.wide_fileformat = wide_fileformat
M.wide_fileformat_file = wide_fileformat_file
M.wide_endofline = wide_endofline
M.wide_cr_to_lf = wide_cr_to_lf
M.append_encoding = append_encoding
M.file_endofline = file_endofline
M.data_endofline = data_endofline
M.data_fileformat = data_fileformat
M.file_fileformat = file_fileformat

return M
