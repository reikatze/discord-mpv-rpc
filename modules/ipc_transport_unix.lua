-- Unix Discord IPC transport with an injectable system-call adapter.
return function(modules)
local floor = modules.helpers.floor
local log_verbose = modules.helpers.log_verbose

local function ipc_paths(getenv)
    local base = getenv('XDG_RUNTIME_DIR') or getenv('TMPDIR')
        or getenv('TMP') or getenv('TEMP') or '/tmp'
    local list = {}
    for i = 0, 9 do
        list[#list + 1] = base .. '/discord-ipc-' .. i
    end
    for _, prefix in ipairs({
        base .. '/app/com.discordapp.Discord/discord-ipc-',
        base .. '/snap.discord/discord-ipc-',
    }) do
        for i = 0, 9 do list[#list + 1] = prefix .. i end
    end
    return list
end

local function create(api, options)
    options = options or {}
    local is_osx = options.is_osx == true
    local path_limit = is_osx and 104 or 108
    local now = options.now or mp.get_time
    local getenv = options.getenv or os.getenv
    local transport = {unix = true}

    function transport:connect()
        for _, path in ipairs(ipc_paths(getenv)) do
            if #path >= path_limit then
                log_verbose('Discord IPC path is too long: ' .. path)
            else
                local handle = api.open(path, {
                    is_osx = is_osx,
                    address_length = is_osx and (2 + #path + 1) or nil,
                    path_limit = path_limit,
                    nonblocking_flag = is_osx and 0x4 or 0x800,
                })
                if handle ~= nil then
                    self.socket = handle
                    log_verbose('connected ' .. path)
                    return true
                end
            end
        end
        return false
    end

    function transport:read_available()
        local ready = api.wait_readable(self.socket, 0)
        if ready == false then return '' end
        if not ready then return nil end
        local data, err = api.recv(self.socket, 4096)
        if data and #data > 0 then return data end
        if err == 'interrupted' or err == 'again' then return '' end
        return nil
    end

    function transport:send_raw(data)
        if not self.socket then return false end
        local sent, deadline = 0, now() + 1.5
        while sent < #data do
            local count, err = api.send(
                self.socket, data, sent, math.min(65536, #data - sent))
            if count and count > 0 then
                sent = sent + count
            elseif err == 'interrupted' then
                -- Retry immediately.
            elseif err == 'again' then
                local remaining = floor((deadline - now()) * 1000)
                if remaining <= 0
                    or not api.wait_writable(self.socket, remaining) then
                    return false
                end
            else
                return false
            end
        end
        return true
    end

    function transport:recv_raw(size)
        if not self.socket or size <= 0 then return nil end
        local parts, received, deadline = {}, 0, now() + 1.5
        while received < size do
            local remaining = floor((deadline - now()) * 1000)
            if remaining <= 0
                or not api.wait_readable(self.socket, remaining) then
                return nil
            end
            local data = api.recv(self.socket, size - received)
            if not data or #data == 0 then return nil end
            parts[#parts + 1] = data
            received = received + #data
        end
        return table.concat(parts)
    end

    function transport:close()
        if self.socket then
            api.close(self.socket)
            self.socket = nil
        end
    end

    return transport
end

local function native()
    if not rawget(_G, 'jit') then return nil end
    local ffi = require 'ffi'
    local bit = require 'bit'
    local is_osx = ffi.os == 'OSX'
    if is_osx then
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
    local sockaddr_un_t = ffi.typeof('struct sockaddr_un')
    local byte_pointer = ffi.typeof('const uint8_t*')
    local poll_fd = ffi.new('struct pollfd[1]')
    local receive_buffer = ffi.new('char[?]', 4096)
    local POLLIN, POLLOUT, POLLERR, POLLHUP = 0x001, 0x004, 0x008, 0x010
    local api = {}

    function api.open(path, settings)
        local fd = C.socket(1, 1, 0)
        if fd == -1 then return nil end
        local address = sockaddr_un_t()
        address.sun_family = 1
        ffi.copy(address.sun_path, path, #path)
        local address_length = ffi.sizeof(address)
        if settings.is_osx then
            address.sun_len = settings.address_length
            address_length = settings.address_length
        end
        if C.connect(fd, address, address_length) ~= 0 then
            C.close(fd)
            return nil
        end
        local flags = C.fcntl(fd, 3, 0)
        if flags >= 0 then C.fcntl(fd, 4, bit.bor(flags, settings.nonblocking_flag)) end
        return fd
    end

    local function poll(handle, events, timeout, include_failures)
        poll_fd[0].fd, poll_fd[0].events, poll_fd[0].revents = handle, events, 0
        local result = C.poll(poll_fd, 1, timeout)
        if result == 0 then return false end
        if result < 0 then return nil end
        if not include_failures
            and bit.band(poll_fd[0].revents, POLLERR + POLLHUP) ~= 0 then
            return nil
        end
        return bit.band(poll_fd[0].revents,
            include_failures and (events + POLLERR + POLLHUP) or events) ~= 0
    end
    function api.wait_readable(handle, timeout)
        return poll(handle, POLLIN, timeout, true)
    end
    function api.wait_writable(handle, timeout)
        return poll(handle, POLLOUT, timeout, false)
    end
    function api.send(handle, data, offset, count)
        local result = C.send(handle, ffi.cast(byte_pointer, data) + offset, count, 0)
        if result > 0 then return tonumber(result) end
        local err = ffi.errno()
        if err == 4 then return nil, 'interrupted' end
        if err == 11 or err == 35 then return nil, 'again' end
        return nil, 'failed'
    end
    function api.recv(handle, count)
        local buffer = count <= 4096 and receive_buffer or ffi.new('char[?]', count)
        local result = C.recv(handle, buffer, count, 0)
        if result > 0 then return ffi.string(buffer, result) end
        local err = ffi.errno()
        if result < 0 and err == 4 then return nil, 'interrupted' end
        if result < 0 and (err == 11 or err == 35) then return nil, 'again' end
        return nil, 'failed'
    end
    function api.close(handle) C.close(handle) end

    return create(api, {is_osx = is_osx})
end

local function luasocket()
    local ok, socket_factory = pcall(require, 'socket.unix')
    if not ok then return nil end
    local transport = {unix = true}
    function transport:connect()
        for _, path in ipairs(ipc_paths(os.getenv)) do
            local socket = socket_factory()
            socket:settimeout(1.5)
            if socket:connect(path) then
                self.socket = socket
                log_verbose('connected ' .. path)
                return true
            end
            socket:close()
        end
        return false
    end
    function transport:read_available()
        self.socket:settimeout(0)
        local data, err, partial = self.socket:receive(4096)
        self.socket:settimeout(1.5)
        local chunk = data or partial
        if chunk and #chunk > 0 then return chunk end
        return err == 'timeout' and '' or nil
    end
    function transport:send_raw(data)
        if not self.socket then return false end
        return self.socket:send(data) == #data
    end
    function transport:recv_raw(size)
        if not self.socket or size <= 0 then return nil end
        self.socket:settimeout(1.5)
        local parts, received = {}, 0
        while received < size do
            local data, err, partial = self.socket:receive(size - received)
            local chunk = data or partial
            if chunk and #chunk > 0 then
                parts[#parts + 1], received = chunk, received + #chunk
            end
            if received >= size then return table.concat(parts) end
            if err then return nil end
        end
    end
    function transport:close()
        if self.socket then
            pcall(function() self.socket:close() end)
            self.socket = nil
        end
    end
    return transport
end

return {
    create = create,
    ipc_paths = ipc_paths,
    native = native,
    luasocket = luasocket,
}
end
