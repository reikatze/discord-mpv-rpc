-- Windows Discord named-pipe transport with an injectable API adapter.
return function(modules)
local byte = modules.helpers.byte
local floor = modules.helpers.floor
local format = modules.helpers.format
local log_verbose = modules.helpers.log_verbose

local function to_utf16_units(value)
    local units, i, length = {}, 1, #value
    while i <= length do
        local first, codepoint = byte(value, i)
        if first < 0x80 then
            codepoint, i = first, i + 1
        elseif first >= 0xC2 and first <= 0xDF and i + 1 <= length then
            local second = byte(value, i + 1)
            if second >= 0x80 and second <= 0xBF then
                codepoint = (first - 0xC0) * 0x40 + (second - 0x80)
                i = i + 2
            end
        elseif first >= 0xE0 and first <= 0xEF and i + 2 <= length then
            local second, third = byte(value, i + 1), byte(value, i + 2)
            if second >= 0x80 and second <= 0xBF
                and third >= 0x80 and third <= 0xBF then
                codepoint = (first - 0xE0) * 0x1000
                    + (second - 0x80) * 0x40 + (third - 0x80)
                if codepoint >= 0x800
                    and not (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
                    i = i + 3
                else
                    codepoint = nil
                end
            end
        elseif first >= 0xF0 and first <= 0xF4 and i + 3 <= length then
            local second, third, fourth = byte(value, i + 1),
                byte(value, i + 2), byte(value, i + 3)
            if second >= 0x80 and second <= 0xBF
                and third >= 0x80 and third <= 0xBF
                and fourth >= 0x80 and fourth <= 0xBF then
                codepoint = (first - 0xF0) * 0x40000
                    + (second - 0x80) * 0x1000
                    + (third - 0x80) * 0x40 + (fourth - 0x80)
                if codepoint >= 0x10000 and codepoint <= 0x10FFFF then
                    i = i + 4
                else
                    codepoint = nil
                end
            end
        end
        if not codepoint then codepoint, i = 0xFFFD, i + 1 end
        if codepoint <= 0xFFFF then
            units[#units + 1] = codepoint
        else
            codepoint = codepoint - 0x10000
            units[#units + 1] = 0xD800 + floor(codepoint / 0x400)
            units[#units + 1] = 0xDC00 + codepoint % 0x400
        end
    end
    units[#units + 1] = 0
    return units
end

local function create(api, options)
    options = options or {}
    local transport = {unix = false}
    function transport:connect()
        for i = 0, 9 do
            local path = format('\\\\.\\pipe\\discord-ipc-%d', i)
            local handle = api.open(path, to_utf16_units(path))
            if handle ~= nil then
                self.socket = handle
                log_verbose('connected ' .. path)
                return true
            end
        end
        return false
    end
    function transport:read_available()
        if not api.available then return nil end
        local available = api.available(self.socket)
        if available == nil then return nil end
        if available == 0 then return '' end
        local data = api.read(self.socket, math.min(4096, available))
        return data and #data > 0 and data or nil
    end
    function transport:send_raw(data)
        if not self.socket then return false end
        local sent = 0
        while sent < #data do
            local count = api.write(
                self.socket, data, sent, math.min(65536, #data - sent))
            if not count or count <= 0 then return false end
            sent = sent + count
        end
        return true
    end
    function transport:recv_raw(size)
        if not self.socket or size <= 0 then return nil end
        local parts, received = {}, 0
        while received < size do
            local data = api.read(self.socket, math.min(4096, size - received))
            if not data or #data == 0 then return nil end
            parts[#parts + 1], received = data, received + #data
        end
        return table.concat(parts)
    end
    function transport:close()
        if self.socket then
            api.close(self.socket)
            self.socket = nil
        end
    end
    if options.background_reader == false then transport.read_available = nil end
    return transport
end

local function native()
    if not rawget(_G, 'jit') then return nil end
    local ffi = require 'ffi'
    local bit = require 'bit'
    ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef const wchar_t* LPCWSTR;
    typedef void* LPVOID;
    typedef const void* LPCVOID;
    typedef DWORD* LPDWORD;
    HANDLE CreateFileW(LPCWSTR, DWORD, DWORD, void*, DWORD, DWORD, HANDLE);
    BOOL WriteFile(HANDLE, LPCVOID, DWORD, LPDWORD, void*);
    BOOL ReadFile(HANDLE, LPVOID, DWORD, LPDWORD, void*);
    BOOL CloseHandle(HANDLE);
    BOOL PeekNamedPipe(HANDLE, LPVOID, DWORD, LPDWORD, LPDWORD, LPDWORD);
    ]]
    local C = ffi.C
    local INVALID = ffi.cast('HANDLE', -1)
    local byte_pointer = ffi.typeof('const uint8_t*')
    local count_buffer = ffi.new('DWORD[1]')
    local api = {}
    function api.open(_, units)
        local wide = ffi.new('wchar_t[?]', #units)
        for i = 1, #units do wide[i - 1] = units[i] end
        local handle = C.CreateFileW(wide,
            bit.bor(0x80000000, 0x40000000), 0, nil, 3, 0, nil)
        return handle ~= INVALID and handle or nil
    end
    function api.available(handle)
        if C.PeekNamedPipe(handle, nil, 0, nil, count_buffer, nil) == 0 then
            return nil
        end
        return tonumber(count_buffer[0])
    end
    function api.write(handle, data, offset, count)
        if C.WriteFile(handle, ffi.cast(byte_pointer, data) + offset,
            count, count_buffer, nil) == 0 then return nil end
        return tonumber(count_buffer[0])
    end
    function api.read(handle, count)
        local buffer = ffi.new('char[?]', count)
        if C.ReadFile(handle, buffer, count, count_buffer, nil) == 0
            or count_buffer[0] == 0 then return nil end
        return ffi.string(buffer, count_buffer[0])
    end
    function api.close(handle) C.CloseHandle(handle) end
    return create(api)
end

local function file_fallback()
    local api = {}
    function api.open(path) return io.open(path, 'r+b') end
    function api.write(handle, data, offset, count)
        local chunk = data:sub(offset + 1, offset + count)
        local ok = pcall(function()
            assert(handle:write(chunk))
            assert(handle:flush())
        end)
        return ok and #chunk or nil
    end
    function api.read(handle, count)
        local ok, data = pcall(function() return handle:read(count) end)
        return ok and data or nil
    end
    function api.close(handle) pcall(function() handle:close() end) end
    return create(api, {background_reader = false})
end

return {
    create = create,
    file_fallback = file_fallback,
    native = native,
    to_utf16_units = to_utf16_units,
}
end
