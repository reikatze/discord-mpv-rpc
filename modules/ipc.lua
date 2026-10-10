-- Discord binary framing, handshake, and protocol.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local CLIENT_ID = modules.config.CLIENT_ID
local PID = modules.config.PID
local byte = modules.helpers.byte
local char = modules.helpers.char
local floor = modules.helpers.floor
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
    pending = {},
}
if not modules.ipc_transport then return nil end
modules.ipc_transport.install(RPC)

----------------------------------------------------------------
-- Protocol
----------------------------------------------------------------
local rpc_backoff_until = 0
local rpc_backoff_sec = 1
local RPC_BACKOFF_MAX = 30

local function rpc_retry_delay()
    return math.max(0, rpc_backoff_until - mp.get_time())
end

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
        self.handshaking = false
        self.handshake_deadline = nil
        self.tx_queue = {}
        self.tx_bytes = 0
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
    -- Expire unanswered commands even while the connection is otherwise
    -- quiet. Previously the early return for an empty receive buffer skipped
    -- pruning until another command or complete frame arrived.
    prune_pending(self)
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
            if self.handshaking then
                if response.evt ~= 'READY' then return false end
                self.handshaking = false
                self.handshake_deadline = nil
                rpc_note_success()
                log_info('connected to Discord')
                if self.on_ready then self.on_ready() end
            end
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

-- The transport performs one nonblocking operation at a time. Queue limits
-- bound memory; every frame has a deadline, including the handshake.
function RPC:flush_writes()
    self.tx_queue = self.tx_queue or {}
    for _ = 1, 16 do
        local item = self.tx_queue[1]
        if not item then return true end
        if mp.get_time() >= item.deadline then return false end
        local count, err = self:send_some(item.data, item.offset)
        if count and count > 0 then
            item.offset = item.offset + count
            if item.offset == #item.data then
                self.tx_bytes = self.tx_bytes - #item.data
                table.remove(self.tx_queue, 1)
            elseif item.offset > #item.data then return false end
        elseif err == 'again' or err == 'interrupted' then return true
        else return false end
    end
    return true
end

function RPC:send_raw(data)
    if not self.socket or not self.send_some then return false end
    self.tx_queue = self.tx_queue or {}
    self.tx_bytes = self.tx_bytes or 0
    if self.tx_bytes + #data > MAX_RPC_FRAME or #self.tx_queue >= 64 then return false end
    self.tx_queue[#self.tx_queue + 1] = {
        data = data, offset = 0, deadline = mp.get_time() + 3,
    }
    self.tx_bytes = self.tx_bytes + #data
    return self:flush_writes()
end

function RPC:start_reader()
    if self.reader_timer then return end
    self.rx_buffer = ''
    self.reader_timer = mp.add_periodic_timer(0.25, function()
        if not self.socket then return end
        if not self:flush_writes() then
            self:connection_failed('Discord IPC write timed out or failed')
            return
        end
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
            if not self.socket then return end
            if chunk == '' then break end
        end
        if self.handshaking and mp.get_time() >= self.handshake_deadline then
            self:connection_failed('Discord IPC handshake timed out')
        elseif self.rx_started_at and mp.get_time() - self.rx_started_at > 5 then
            self:connection_failed('Discord IPC partial frame timed out')
        end
    end)
end

function RPC:handshake()
    if self.socket then return not self.handshaking end
    if rpc_backoff_active() then return false end
    if not self.read_available or not self.send_some then
        log_warn('nonblocking Discord IPC requires LuaJIT on Windows')
        rpc_note_failure()
        return false
    end
    if not self:connect() then
        rpc_note_failure()
        log_verbose('no Discord IPC pipe (is Discord running?)')
        return false
    end
    self.handshaking = true
    self.handshake_deadline = mp.get_time() + 3
    self:start_reader()
    local body = format_json{ v = 1, client_id = CLIENT_ID }
    if not body or not self:send_raw(pack(0, body)) then
        self:connection_failed('Discord IPC handshake send failed')
    end
    -- READY arrives through the reader. Callers retry publishing via on_ready.
    return false
end

function RPC:set_activity(activity, context)
    if (not self.socket or self.handshaking) and not self:handshake() then
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
    rpc_retry_delay = rpc_retry_delay,
}
end
