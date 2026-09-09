-- Discord binary framing, platform transports, handshake, and protocol.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local CLIENT_ID = modules.config.CLIENT_ID
local PID = modules.config.PID
local byte = modules.helpers.byte
local char = modules.helpers.char
local floor = modules.helpers.floor
local format = modules.helpers.format
local format_json = modules.helpers.format_json
local log_error = modules.helpers.log_error
local log_info = modules.helpers.log_info
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local parse_json = modules.helpers.parse_json
local sub = modules.helpers.sub

-- Binary framing
----------------------------------------------------------------
local function pack(op, body)
    local n = #body
    return char(
        op % 256, floor(op / 256) % 256,
        floor(op / 65536) % 256, floor(op / 16777216) % 256,
        n % 256, floor(n / 256) % 256,
        floor(n / 65536) % 256, floor(n / 16777216) % 256
    ) .. body
end

local function unpack_header(data)
    return byte(data, 1) + byte(data, 2) * 256 + byte(data, 3) * 65536 + byte(data, 4) * 16777216,
           byte(data, 5) + byte(data, 6) * 256 + byte(data, 7) * 65536 + byte(data, 8) * 16777216
end

local MAX_RPC_FRAME = 1024 * 1024 -- Discord payloads should be far below this.
local function valid_rpc_header(hdr)
    if not hdr or #hdr < 8 then return false end
    local op, len = unpack_header(hdr)
    if op < 0 or op > 0x7fffffff or len < 0 or len > MAX_RPC_FRAME then
        return false
    end
    return true, op, len
end

local nonce_counter = 0
local function next_nonce()
    nonce_counter = nonce_counter + 1
    return tostring(nonce_counter)
end

----------------------------------------------------------------
-- Discord IPC transport
----------------------------------------------------------------
local RPC = {
    socket = nil,
    pid    = PID,
    unix   = package.config:sub(1, 1) == '/',
    pending = {},
}

local ffi = _G.jit and require 'ffi' or nil
local bit = ffi and require 'bit' or nil

local function ipc_paths()
    local list = {}
    if RPC.unix then
        local base = os.getenv('XDG_RUNTIME_DIR') or os.getenv('TMPDIR')
                  or os.getenv('TMP') or os.getenv('TEMP') or '/tmp'
        for i = 0, 9 do
            list[#list + 1] = base .. '/discord-ipc-' .. i
        end
        for _, prefix in ipairs({
            base .. '/app/com.discordapp.Discord/discord-ipc-',
            base .. '/snap.discord/discord-ipc-',
        }) do
            for i = 0, 9 do
                list[#list + 1] = prefix .. i
            end
        end
    else
        for i = 0, 9 do
            list[#list + 1] = format('\\\\.\\pipe\\discord-ipc-%d', i)
        end
    end
    return list
end

if ffi and RPC.unix then
    local IS_OSX = ffi.os == 'OSX'
    if IS_OSX then
        ffi.cdef[[
        struct sockaddr_un { unsigned char sun_len; unsigned char sun_family; char sun_path[104]; };
        int poll(struct pollfd*, unsigned int, int);
        ]]
    else
        ffi.cdef[[
        struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
        int poll(struct pollfd*, unsigned long, int);
        ]]
    end
    ffi.cdef[[
        int socket(int, int, int);
        int connect(int, const void*, unsigned);
        int send(int, const void*, size_t, int);
        int recv(int, void*, size_t, int);
        int close(int);
        int fcntl(int, int, int);
        struct pollfd { int fd; short events; short revents; };
    ]]
    local C = ffi.C
    local const_byte_ptr = ffi.typeof('const uint8_t*')
    local sockaddr_un_t = ffi.typeof('struct sockaddr_un')
    local RECV_SIZE = 4096
    local recv_buf = ffi.new('char[?]', RECV_SIZE)
    local SUN_PATH_MAX = IS_OSX and 104 or 108
    local O_NONBLOCK = IS_OSX and 0x4 or 0x800
    local F_GETFL, F_SETFL = 3, 4

    function RPC:connect()
        local paths = ipc_paths()
        for i = 1, #paths do
            if #paths[i] >= SUN_PATH_MAX then
                log_verbose('Discord IPC path is too long: ' .. paths[i])
            else
                local fd = C.socket(1, 1, 0)
                if fd ~= -1 then
                    local addr = sockaddr_un_t()
                    addr.sun_family = 1
                    ffi.copy(addr.sun_path, paths[i], #paths[i])
                    local addr_len = ffi.sizeof(addr)
                    if IS_OSX then
                        addr_len = 2 + #paths[i] + 1
                        addr.sun_len = addr_len
                    end
                    if C.connect(fd, addr, addr_len) == 0 then
                        pcall(function()
                            local fl = C.fcntl(fd, F_GETFL, 0)
                            if fl >= 0 then
                                C.fcntl(fd, F_SETFL, bit.bor(fl, O_NONBLOCK))
                            end
                        end)
                        self.socket = fd
                        log_verbose('connected ' .. paths[i])
                        return true
                    end
                    C.close(fd)
                end
            end
        end
        return false
    end

    local POLLIN = 0x001
    local POLLOUT = 0x004
    local POLLERR = 0x008
    local POLLHUP = 0x010

    local pfd = ffi.new('struct pollfd[1]')
    local function wait_fd(fd, events, timeout_ms)
        pfd[0].fd = fd
        pfd[0].events = events
        pfd[0].revents = 0
        local r = C.poll(pfd, 1, timeout_ms)
        if r <= 0 then return false end
        if bit.band(pfd[0].revents,POLLERR+POLLHUP)~=0 then return false end
        return bit.band(pfd[0].revents,events)~=0
    end

    local function wait_readable(fd, timeout_ms)
        pfd[0].fd = fd
        pfd[0].events = POLLIN
        pfd[0].revents = 0
        local r = C.poll(pfd, 1, timeout_ms)
        if r <= 0 then return false end
        return bit.band(pfd[0].revents, POLLIN + POLLERR + POLLHUP) ~= 0
    end

    function RPC:read_available()
        pfd[0].fd, pfd[0].events = self.socket, POLLIN
        pfd[0].revents = 0
        local ready = C.poll(pfd, 1, 0)
        if ready == 0 then return '' end
        if ready < 0 then return nil end
        local n = C.recv(self.socket, recv_buf, RECV_SIZE, 0)
        if n > 0 then return ffi.string(recv_buf, n) end
        if n < 0 then
            local err = ffi.errno()
            if err == 4 or err == 11 or err == 35 then return '' end
        end
        return nil
    end

    local SEND_SIZE = 65536
    function RPC:send_raw(data)
        if not self.socket then return false end
        local total = #data
        local sent = 0
        local data_ptr = ffi.cast(const_byte_ptr, data)
        local deadline = mp.get_time() + 1.5
        while sent < total do
            local chunk = math.min(SEND_SIZE, total - sent)
            local n = C.send(self.socket, data_ptr + sent, chunk, 0)
            if n > 0 then
                sent = sent + n
            else
                if n == 0 then return false end
                local err = ffi.errno()
                if err == 4 then
                    -- EINTR: retry immediately.
                elseif err ~= 11 and err ~= 35 then
                    -- Only EAGAIN/EWOULDBLOCK represents backpressure. Broken
                    -- pipes and reset sockets must fail without a 1.5s wait.
                    return false
                else
                    local remaining_ms = floor((deadline - mp.get_time()) * 1000)
                    if remaining_ms <= 0
                        or not wait_fd(self.socket, POLLOUT, remaining_ms) then
                        return false
                    end
                end
            end
        end
        return true
    end

    function RPC:recv_raw(n)
        if not self.socket or n <= 0 then return nil end

        local buf = n <= RECV_SIZE and recv_buf or ffi.new('char[?]', n)
        local parts = {}
        local received = 0
        local deadline = mp.get_time() + 1.5

        while received < n do
            local remaining_ms = floor((deadline - mp.get_time()) * 1000)
            if remaining_ms <= 0 then return nil end
            if not wait_readable(self.socket, remaining_ms) then return nil end

            local r = C.recv(self.socket, buf, n - received, 0)
            if r <= 0 then return nil end

            if received == 0 and r == n then
                return ffi.string(buf, n)
            end

            parts[#parts + 1] = ffi.string(buf, r)
            received = received + r
        end

        return table.concat(parts)
    end

    function RPC:close()
        if self.socket then
            C.close(self.socket)
            self.socket = nil
        end
    end

elseif ffi and not RPC.unix then
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
    local const_byte_ptr = ffi.typeof('const uint8_t*')
    local INVALID = ffi.cast('HANDLE', -1)
    local GENERIC_READ  = 0x80000000
    local GENERIC_WRITE = 0x40000000
    local OPEN_EXISTING = 3
    local recv_buf = ffi.new('char[?]', 4096)
    local written  = ffi.new('DWORD[1]')
    local readn    = ffi.new('DWORD[1]')
    local available = ffi.new('DWORD[1]')

    function RPC:read_available()
        if C.PeekNamedPipe(self.socket, nil, 0, nil, available, nil) == 0 then
            return nil
        end
        if available[0] == 0 then return '' end
        local want = math.min(4096, tonumber(available[0]))
        if C.ReadFile(self.socket, recv_buf, want, readn, nil) == 0 or readn[0] == 0 then
            return nil
        end
        return ffi.string(recv_buf, readn[0])
    end

    -- UTF-8 -> UTF-16 for Windows wide-character APIs.
    -- Windows wchar_t is a 16-bit UTF-16 code unit, so supplementary
    -- Unicode code points must be emitted as surrogate pairs. Invalid or
    -- truncated UTF-8 is replaced with U+FFFD rather than copied as bytes.
    local function to_wide(s)
        local units = {}
        local i, len = 1, #s

        while i <= len do
            local b1 = byte(s, i)
            local cp

            if b1 < 0x80 then
                cp = b1
                i = i + 1
            elseif b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= len then
                local b2 = byte(s, i + 1)
                if b2 >= 0x80 and b2 <= 0xBF then
                    cp = (b1 - 0xC0) * 0x40 + (b2 - 0x80)
                    i = i + 2
                end
            elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= len then
                local b2, b3 = byte(s, i + 1), byte(s, i + 2)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                    cp = (b1 - 0xE0) * 0x1000
                       + (b2 - 0x80) * 0x40
                       + (b3 - 0x80)
                    if cp >= 0x800 and not (cp >= 0xD800 and cp <= 0xDFFF) then
                        i = i + 3
                    else
                        cp = nil
                    end
                end
            elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= len then
                local b2, b3, b4 = byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
                    and b4 >= 0x80 and b4 <= 0xBF then
                    cp = (b1 - 0xF0) * 0x40000
                       + (b2 - 0x80) * 0x1000
                       + (b3 - 0x80) * 0x40
                       + (b4 - 0x80)
                    if cp >= 0x10000 and cp <= 0x10FFFF then
                        i = i + 4
                    else
                        cp = nil
                    end
                end
            end

            if not cp then
                cp = 0xFFFD
                i = i + 1
            end

            if cp <= 0xFFFF then
                units[#units + 1] = cp
            else
                cp = cp - 0x10000
                units[#units + 1] = 0xD800 + floor(cp / 0x400)
                units[#units + 1] = 0xDC00 + (cp % 0x400)
            end
        end

        local buf = ffi.new('wchar_t[?]', #units + 1)
        for n = 1, #units do
            buf[n - 1] = units[n]
        end
        buf[#units] = 0
        return buf
    end

    function RPC:connect()
        for i = 0, 9 do
            local path = format('\\\\.\\pipe\\discord-ipc-%d', i)
            local h = C.CreateFileW(
                to_wide(path),
                bit.bor(GENERIC_READ, GENERIC_WRITE),
                0, nil, OPEN_EXISTING, 0, nil
            )
            if h ~= INVALID then
                self.socket = h
                log_verbose('connected ' .. path)
                return true
            end
        end
        return false
    end

    function RPC:send_raw(data)
        if not self.socket then return false end
        local total = #data
        local sent = 0
        local data_ptr = ffi.cast(const_byte_ptr, data)
        while sent < total do
            local chunk = math.min(65536, total - sent)
            if C.WriteFile(self.socket, data_ptr + sent, chunk, written, nil) == 0
                or written[0] == 0 then
                return false
            end
            sent = sent + written[0]
        end
        return true
    end

    function RPC:recv_raw(n)
        if not self.socket or n <= 0 then return nil end

        local parts = {}
        local received = 0
        while received < n do
            local want = math.min(4096, n - received)
            local buf = want == 4096 and recv_buf or ffi.new('char[?]', want)
            if C.ReadFile(self.socket, buf, want, readn, nil) == 0 or readn[0] == 0 then
                return nil
            end
            parts[#parts + 1] = ffi.string(buf, readn[0])
            received = received + readn[0]
        end
        return table.concat(parts)
    end

    function RPC:close()
        if self.socket then
            C.CloseHandle(self.socket)
            self.socket = nil
        end
    end

elseif not RPC.unix then
    function RPC:connect()
        for i = 0, 9 do
            local path = format('\\\\.\\pipe\\discord-ipc-%d', i)
            local f = io.open(path, 'r+b')
            if f then
                self.socket = f
                log_verbose('connected ' .. path)
                return true
            end
        end
        return false
    end

    function RPC:send_raw(data)
        if not self.socket then return false end
        local ok, err = pcall(function()
            assert(self.socket:write(data))
            assert(self.socket:flush())
        end)
        return ok and err == nil
    end

    function RPC:recv_raw(n)
        if not self.socket or n <= 0 then return nil end
        local ok, data = pcall(function() return self.socket:read(n) end)
        if not ok or not data or #data ~= n then return nil end
        return data
    end

    function RPC:close()
        if self.socket then
            pcall(function() self.socket:close() end)
            self.socket = nil
        end
    end

else
    local ok, socket = pcall(require, 'socket.unix')
    if not ok then
        log_error('need LuaJIT or LuaSocket')
        return
    end

    function RPC:connect()
        local paths = ipc_paths()
        for i = 1, #paths do
            local s = socket()
            s:settimeout(1.5)
            if s:connect(paths[i]) then
                self.socket = s
                log_verbose('connected ' .. paths[i])
                return true
            end
            s:close()
        end
        return false
    end

    function RPC:read_available()
        self.socket:settimeout(0)
        local data, err, partial = self.socket:receive(4096)
        self.socket:settimeout(1.5)
        local chunk = data or partial
        if chunk and #chunk > 0 then return chunk end
        if err == 'timeout' then return '' end
        return nil
    end

    function RPC:send_raw(data)
        if not self.socket then return false end
        -- LuaSocket returns the absolute last byte index, including on a
        -- partial send. A failed send closes the connection at the caller.
        local last_byte = self.socket:send(data)
        return last_byte == #data
    end

    function RPC:recv_raw(n)
        if not self.socket or n <= 0 then return nil end
        self.socket:settimeout(1.5)
        local parts, received = {}, 0
        while received < n do
            local want = n - received
            local data, err, partial = self.socket:receive(want)
            local chunk = data or partial
            if chunk and #chunk > 0 then
                parts[#parts + 1] = chunk
                received = received + #chunk
            end
            if received >= n then
                return table.concat(parts)
            end
            if err then
                return nil
            end
        end
        return table.concat(parts)
    end

    function RPC:close()
        if self.socket then
            pcall(function() self.socket:close() end)
            self.socket = nil
        end
    end
end

----------------------------------------------------------------
-- Protocol
----------------------------------------------------------------
local rpc_backoff_until = 0
local rpc_backoff_sec = 1
local RPC_BACKOFF_MAX = 30

local function rpc_backoff_active()
    return mp.get_time() < rpc_backoff_until
end

local function rpc_note_failure()
    rpc_backoff_until = mp.get_time() + rpc_backoff_sec
    rpc_backoff_sec = math.min(rpc_backoff_sec * 2, RPC_BACKOFF_MAX)
end

local function rpc_note_success()
    rpc_backoff_until = 0
    rpc_backoff_sec = 1
end

do
    local transport_close = RPC.close
    function RPC:close()
        if self.reader_timer then self.reader_timer:kill() end
        self.reader_timer = nil
        self.rx_buffer = ''
        self.rx_started_at = nil
        self.pending = {}
        transport_close(self)
    end
end

function RPC:connection_failed(reason)
    log_warn(reason)
    self:close()
    rpc_note_failure()
    if self.on_disconnect then self.on_disconnect() end
end

local function prune_pending(self)
    local now=mp.get_time()
    for nonce,item in pairs(self.pending) do
        if type(item)~='table' or now-(item.sent_at or now)>30 then
            self.pending[nonce]=nil
        end
    end
end

function RPC:drain_frames()
    -- Bound work per callback; preserve fragmented headers and bodies.
    for _ = 1, 64 do
        if #self.rx_buffer < 8 then return true end
        local valid, op, len = valid_rpc_header(sub(self.rx_buffer, 1, 8))
        if not valid or op < 1 or op > 4 then return false end
        if #self.rx_buffer < 8 + len then return true end
        local payload = sub(self.rx_buffer, 9, 8 + len)
        self.rx_buffer = sub(self.rx_buffer, 9 + len)
        self.rx_started_at = #self.rx_buffer > 0 and mp.get_time() or nil
        if op == 2 then
            log_verbose('Discord sent a close frame: ' .. payload)
            return false
        elseif op == 3 then
            if not self:send_raw(pack(4, payload)) then return false end
        elseif op == 1 then
            local response = parse_json(payload)
            if type(response) ~= 'table' then return false end
            local nonce=response.nonce and tostring(response.nonce) or nil
            local pending=nonce and self.pending[nonce] or nil
            if nonce then self.pending[nonce]=nil end
            if response.evt == 'ERROR' then
                local data = type(response.data) == 'table' and response.data or {}
                log_warn('Discord RPC error (nonce=' .. tostring(response.nonce)
                    .. '): ' .. tostring(data.message or data.code or 'unknown'))
                if self.on_error then
                    local ok,err=pcall(self.on_error,response,pending)
                    if not ok then log_warn('Discord RPC error callback failed: '..tostring(err)) end
                end
            elseif pending and self.on_response then
                local ok,err=pcall(self.on_response,response,pending)
                if not ok then log_warn('Discord RPC response callback failed: '..tostring(err)) end
            end
        end
    end
    prune_pending(self)
    return true
end

function RPC:start_reader()
    if self.reader_timer then return end
    if not self.read_available then
        log_warn('LuaJIT is required on Windows for background IPC disconnect detection')
        return
    end
    self.rx_buffer = ''
    self.reader_timer = mp.add_periodic_timer(0.25, function()
        if not self.socket then return end
        for _ = 1, 32 do
            local chunk = self:read_available()
            if chunk == nil then
                self:connection_failed('Discord IPC disconnected')
                return
            end
            if chunk ~= '' then
                if #self.rx_buffer == 0 then self.rx_started_at = mp.get_time() end
                self.rx_buffer = self.rx_buffer .. chunk
            end
            if not self:drain_frames() or #self.rx_buffer > MAX_RPC_FRAME + 8 then
                self:connection_failed('Discord IPC received an invalid frame')
                return
            end
            if chunk == '' then break end
        end
        if self.rx_started_at and mp.get_time() - self.rx_started_at > 5 then
            self:connection_failed('Discord IPC partial frame timed out')
        end
    end)
end

function RPC:handshake()
    if self.socket then return true end
    if rpc_backoff_active() then
        return false
    end
    if not self:connect() then
        rpc_note_failure()
        log_verbose('no Discord IPC pipe (is Discord running?)')
        return false
    end

    local body = format_json{ v = 1, client_id = CLIENT_ID }
    if not self:send_raw(pack(0, body)) then
        log_error('handshake send failed')
        self:close()
        rpc_note_failure()
        return false
    end

    local hdr = self:recv_raw(8)
    if not hdr or #hdr < 8 then
        log_error('handshake recv failed')
        self:close()
        rpc_note_failure()
        return false
    end

    local valid, op, len = valid_rpc_header(hdr)
    if not valid then
        log_error('handshake received invalid IPC frame')
        self:close()
        rpc_note_failure()
        return false
    end
    if op ~= 1 then
        log_error('handshake received unexpected IPC opcode ' .. tostring(op))
        self:close()
        rpc_note_failure()
        return false
    end

    local payload = self:recv_raw(len)
    if not payload then
        log_error('handshake payload recv failed')
        self:close()
        rpc_note_failure()
        return false
    end
    local res = parse_json(payload)
    if not res or res.evt ~= 'READY' then
        log_error('handshake not READY (check client_id)')
        self:close()
        rpc_note_failure()
        return false
    end

    rpc_note_success()
    self:start_reader()
    log_info('connected to Discord')
    return true
end

function RPC:set_activity(activity, context)
    if not self.socket and not self:handshake() then
        return false
    end

    local encoded = 'null'
    if activity ~= nil then
        encoded = format_json(activity)
        if not encoded then return false end
    end
    local nonce=next_nonce()
    local body = '{"cmd":"SET_ACTIVITY","nonce":' .. format_json(nonce)
        .. ',"args":{"pid":' .. tostring(PID) .. ',"activity":' .. encoded .. '}}'

    prune_pending(self)
    self.pending[nonce]={
        command='SET_ACTIVITY',nonce=nonce,context=context,sent_at=mp.get_time()
    }
    if not self:send_raw(pack(1, body)) then
        self.pending[nonce]=nil
        self:connection_failed('Discord IPC send failed')
        return false
    end
    return true,nonce
end

function RPC:shutdown_fast()
    self:close()
end

return {
    RPC = RPC,
    rpc_backoff_active = rpc_backoff_active,
}
end
