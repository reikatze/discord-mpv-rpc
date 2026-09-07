--[[
  mpv Discord Rich Presence + TMDb posters

  - Current file title, Playing/Paused/Idle
  - Discord progress bar (frozen while paused)
  - TMDb poster via curl (optional), else static large_image
  - Caches search results and poster URLs on disk
  - Supports %APPDATA%/mpv and portable_config
  - Install: scripts/discord-mpv-rpc/main.lua
  - Cache:   scripts/discord-mpv-rpc/discord-mpv-rpc-posters.json

  Config: script-opts/discord-mpv-rpc.conf
    client_id=
    tmdb_api_key=
    tmdb_language=en-US
    update_interval=15
    key_toggle=D
    large_image=mpv
    large_text=mpv
    enabled=yes
]]

local utils = require 'mp.utils'
local msg   = require 'mp.msg'
local opts  = require 'mp.options'

local o = {
    client_id       = '',
    large_image          = 'mpv',
    large_text           = 'mpv',
    small_image_playing  = 'play',
    small_image_paused   = 'pause',
    small_image_idle     = 'mpv',
    tmdb_api_key    = '',
    tmdb_language   = 'en-US',
    update_interval = 15,
    key_toggle      = 'D',
    enabled         = true,
    poster_fit      = 'contain',
}
opts.read_options(o, 'discord-mpv-rpc')

if o.client_id == '' then
    msg.error('discord-mpv-rpc: set client_id in script-opts/discord-mpv-rpc.conf')
    return
end

----------------------------------------------------------------
-- Locals
----------------------------------------------------------------
local floor  = math.floor
local char   = string.char
local byte   = string.byte
local sub    = string.sub
local gsub   = string.gsub
local match  = string.match
local format = string.format
local time   = os.time
local format_json = utils.format_json
local parse_json  = utils.parse_json
local create_co   = coroutine.create
local resume_co   = coroutine.resume
local yield_co    = coroutine.yield
local running_co  = coroutine.running

local get_property        = mp.get_property
local get_property_number = mp.get_property_number
local get_property_bool   = mp.get_property_bool

local CLIENT_ID    = o.client_id
local FALLBACK_IMG = o.large_image
local FALLBACK_TXT = o.large_text
local SMALL_PLAY   = o.small_image_playing
local SMALL_PAUSE  = o.small_image_paused
local SMALL_IDLE   = o.small_image_idle
local ACTIVITY_WATCHING = 3
local TMDB_KEY     = o.tmdb_api_key
local TMDB_LANG    = o.tmdb_language
local INTERVAL     = tonumber(o.update_interval) or 15
local KEY_TOGGLE   = o.key_toggle
local enabled      = o.enabled
local POSTER_FIT   = o.poster_fit or 'contain'
local PID          = utils.getpid()
local IS_WINDOWS   = package.config:sub(1, 1) == '\\'
local PATH_SEP     = package.config:sub(1, 1)

local function log_info(s)  msg.info('discord-mpv-rpc: ' .. s) end
local function log_warn(s)  msg.warn('discord-mpv-rpc: ' .. s) end
local function log_error(s) msg.error('discord-mpv-rpc: ' .. s) end
local function log_verbose(s) msg.verbose('discord-mpv-rpc: ' .. s) end

-- tick is defined later; poster lookup calls it when curl finishes
local tick

----------------------------------------------------------------
-- Script directory (works for AppData and portable_config)
-- Cache lives next to this file:
--   .../scripts/discord-mpv-rpc/main.lua
--   .../scripts/discord-mpv-rpc/discord-mpv-rpc-posters.json
----------------------------------------------------------------
local function get_script_dir()
    local script_dir = mp.get_script_directory()
    if script_dir and script_dir ~= '' then
        return script_dir
    end

    if IS_WINDOWS then
        return (os.getenv('APPDATA') or '.') .. '\\mpv\\scripts\\discord-mpv-rpc'
    end
    local xdg = os.getenv('XDG_CONFIG_HOME')
    if xdg and xdg ~= '' then
        return xdg .. '/mpv/scripts/discord-mpv-rpc'
    end
    return (os.getenv('HOME') or '.') .. '/.config/mpv/scripts/discord-mpv-rpc'
end

local SCRIPT_DIR = get_script_dir()
local CACHE_PATH = SCRIPT_DIR .. PATH_SEP .. 'discord-mpv-rpc-posters.json'

local poster_cache = {}
local poster_cache_loaded = false
local poster_cache_dirty = false
local current_poster = nil
local current_clean_title = nil
local current_tmdb_title = nil
local current_tmdb_url = nil

local function load_poster_cache()
    if poster_cache_loaded then return end
    poster_cache_loaded = true

    local f = io.open(CACHE_PATH, 'r')
    if not f then return end

    local raw = f:read('*a')
    f:close()
    if not raw or #raw == 0 then return end

    local data = parse_json(raw)
    if type(data) == 'table' then
        poster_cache = data
        log_verbose('loaded poster cache from ' .. CACHE_PATH)
    end
end

local function save_poster_cache()
    if not poster_cache_dirty then return end

    -- Write next to this script. Do not os.execute('mkdir'): that flashes
    -- a Command Prompt on Windows.
    local f = io.open(CACHE_PATH, 'w')
    if not f then
        log_warn('could not write poster cache to ' .. CACHE_PATH)
        return
    end
    f:write(format_json(poster_cache) or '{}')
    f:close()
    poster_cache_dirty = false
    log_verbose('poster cache saved to ' .. CACHE_PATH)
end

local function remember_poster(key, value)
    poster_cache[key] = value
    poster_cache_dirty = true
    save_poster_cache()
end

----------------------------------------------------------------
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

local nonce_counter = 0
local function next_nonce()
    nonce_counter = nonce_counter + 1
    return tostring(nonce_counter)
end

----------------------------------------------------------------
-- curl helper
----------------------------------------------------------------
local function split_curl(stdout)
    if not stdout or stdout == '' then
        return nil, 0
    end
    stdout = gsub(stdout, '\r\n', '\n')
    stdout = gsub(stdout, '\r', '\n')
    local body, code = match(stdout, '^(.*)\n(%d%d%d)\n?$')
    if not code then
        code = match(stdout, '(%d%d%d)\n?$')
        if code then
            body = sub(stdout, 1, #stdout - #code)
            body = gsub(body, '\n+$', '')
        else
            body = stdout
            code = 0
        end
    end
    return body, tonumber(code) or 0
end

local function curl_request(url, extra)
    local args = {
        'curl', '-sS', '--max-time', extra and extra.timeout or '6',
        '-w', '\n%{http_code}',
    }
    if extra and extra.headers then
        for i = 1, #extra.headers do
            args[#args + 1] = '-H'
            args[#args + 1] = extra.headers[i]
        end
    end
    if extra and extra.head then
        args[#args + 1] = '-I'
        args[#args + 1] = '-o'
        args[#args + 1] = IS_WINDOWS and 'NUL' or '/dev/null'
    end
    args[#args + 1] = url

    local function finish(res)
        if not res or not res.stdout then
            return nil, 0
        end
        return split_curl(res.stdout)
    end

    local co = running_co()
    if co then
        local done
        mp.command_native_async({
            name           = 'subprocess',
            args           = args,
            playback_only  = false,
            capture_stdout = true,
            capture_stderr = false,
        }, function(_, res)
            if done then return end
            done = true
            local body, status = finish(res)
            local ok, err = resume_co(co, body, status)
            if not ok then
                log_error('coroutine: ' .. tostring(err))
            end
        end)
        return yield_co()
    end

    return finish(utils.subprocess{ args = args, cancellable = false })
end

local function curl_get(url)
    return curl_request(url, {
        headers = { 'Accept: application/json' },
    })
end

local function run_async(fn)
    local co = create_co(fn)
    local ok, err = resume_co(co)
    if not ok then
        log_error('coroutine: ' .. tostring(err))
    end
end

local function url_encode(s)
    return (gsub(s, '([^%w%-%.%_%~ ])', function(c)
        return format('%%%02X', byte(c))
    end):gsub(' ', '%%20'))
end

-- Discord crops large_image to a square. Letterbox the portrait TMDb poster
-- onto 512x512 so title art stays readable. Use poster_fit=raw to send the
-- original URL. If wsrv fails for a URL, fall back to the raw TMDb link.
local wsrv_bad = {}

local function wsrv_url(tmdb_url)
    local bare = gsub(tmdb_url, '^https://', '')
    return 'https://wsrv.nl/?url=' .. url_encode(bare)
        .. '&w=512&h=512&fit=contain&cbg=111111'
end

local function presence_image(url)
    if not url or url == '' then
        return FALLBACK_IMG
    end
    if POSTER_FIT ~= 'contain' or wsrv_bad[url] then
        return url
    end
    return wsrv_url(url)
end

local function probe_wsrv(tmdb_url)
    if POSTER_FIT ~= 'contain' or not tmdb_url or wsrv_bad[tmdb_url] then
        return
    end
    run_async(function()
        local _, status = curl_request(wsrv_url(tmdb_url), {
            timeout = '4',
            head    = true,
        })
        if status ~= 200 and status ~= 0 then
            wsrv_bad[tmdb_url] = true
            log_warn('wsrv failed (' .. tostring(status) .. '), using raw poster')
            tick(true)
        end
    end)
end

----------------------------------------------------------------
-- Filename -> title / year / is_tv
----------------------------------------------------------------
local function clean_filename(path)
    local name = match(path, '([^/\\]+)$') or path
    name = gsub(name, '%.[^%.]+$', '')

    name = gsub(name, '^%b[]%s*', '')

    local season, ep, is_tv = nil, nil, false

    season, ep = match(name, '[sS](%d+)[eE](%d+)')
    if season then is_tv = true end

    if not is_tv then
        season, ep = match(name, '[sS](%d+)%s*%-%s*(%d+)')
        if season then is_tv = true end
    end

    if not is_tv then
        ep = match(name, '%s%-%s*(%d+)%s*%(')
        if ep then is_tv = true end
    end

    local year = match(name, '%((19%d%d|20%d%d)%)')
              or match(name, '(19%d%d)')
              or match(name, '(20%d%d)')

    local title
    if is_tv then
        title = match(name, '^(.-)%s*[sS]%d+[eE]%d+')
             or match(name, '^(.-)%s*[sS]%d+%s*%-%s*%d+')
             or match(name, '^(.-)%s*%-%s*%d+%s*%(')
             or name
    elseif year then
        title = match(name, '^(.-)%s*%(' .. year .. '%)')
             or match(name, '^(.-)[%s%._%-]+' .. year)
             or match(name, '^(.-)' .. year)
             or name
    else
        title = name
    end

    title = gsub(title, '%b[]', ' ')
    title = gsub(title, '%b()', ' ')
    title = gsub(title, '[%.%_]', ' ')
    title = gsub(title, '%s*%-%s*$', '')
    title = gsub(title, '^%s*%-%s*', '')
    title = gsub(title, '%s+', ' ')
    title = gsub(title, '^%s+', '')
    title = gsub(title, '%s+$', '')

    -- TMDb search is case-insensitive; skip title-case
    return title, year, is_tv
end

----------------------------------------------------------------
-- TMDb posters
----------------------------------------------------------------
local tmdb_backoff_until = 0
local tmdb_backoff_sec   = 30

local function unpack_cache_entry(cached)
    if type(cached) == 'string' and #cached > 0 then
        return { poster = cached }
    end
    if type(cached) == 'table' and cached.poster and #cached.poster > 0 then
        return cached
    end
    return nil
end

local function tmdb_page_url(result)
    if not result or not result.id then return nil end
    if result.media_type == 'tv' then
        return 'https://www.themoviedb.org/tv/' .. tostring(result.id)
    end
    if result.media_type == 'movie' then
        return 'https://www.themoviedb.org/movie/' .. tostring(result.id)
    end
    return nil
end

local function tmdb_official_title(result)
    if not result then return nil end
    local official = result.title or result.name
    if official and #official > 0 then
        return official
    end
    return result.original_title or result.original_name
end

local function score_multi_result(r, year, prefer_tv)
    if not r or r.media_type == 'person' then
        return -1
    end
    if r.media_type ~= 'movie' and r.media_type ~= 'tv' then
        return -1
    end
    local score = 0
    if r.poster_path then score = score + 8 end
    local date = r.release_date or r.first_air_date or ''
    local ry = match(date, '^(%d%d%d%d)')
    if year and ry == year then
        score = score + 20
    elseif year and ry then
        score = score - 5
    end
    if prefer_tv and r.media_type == 'tv' then
        score = score + 4
    elseif not prefer_tv and r.media_type == 'movie' then
        score = score + 4
    end
    return score
end

local function tmdb_lookup(title, year, is_tv)
    if TMDB_KEY == '' or not title or title == '' then
        return nil
    end

    if mp.get_time() < tmdb_backoff_until then
        log_verbose('TMDb backoff active, skipping request')
        return nil
    end

    load_poster_cache()

    local key = 'multi:' .. title:lower() .. '|' .. (year or '')
    local cached = poster_cache[key]
    if cached == false then
        log_verbose('poster cache hit (no poster)')
        return nil
    end
    local hit = unpack_cache_entry(cached)
    if hit then
        log_verbose('poster cache hit -> ' .. hit.poster)
        return hit
    end

    local url = format(
        'https://api.themoviedb.org/3/search/multi?api_key=%s&language=%s&query=%s&page=1&include_adult=false',
        TMDB_KEY, TMDB_LANG, url_encode(title)
    )

    log_verbose(format('TMDb multi query="%s" year=%s tv_hint=%s',
        title, tostring(year), tostring(is_tv)))

    local body, status = curl_get(url)
    if status == 429 then
        tmdb_backoff_until = mp.get_time() + tmdb_backoff_sec
        log_warn('TMDb 429, backing off ' .. tmdb_backoff_sec .. 's')
        tmdb_backoff_sec = math.min(tmdb_backoff_sec * 2, 300)
        return nil
    end
    if (not body or body == '') and status ~= 200 then
        log_warn('TMDb request failed (status=' .. tostring(status) .. ')')
        return nil
    end

    local data = parse_json(body or '')
    if not data then
        log_warn('TMDb response was not JSON (status=' .. tostring(status) .. ')')
        return nil
    end
    tmdb_backoff_sec = 30
    if not data.results or #data.results == 0 then
        remember_poster(key, false)
        log_verbose('TMDb no results')
        return nil
    end

    local best, best_score
    for i = 1, #data.results do
        local s = score_multi_result(data.results[i], year, is_tv)
        if s >= 0 and (not best_score or s > best_score) then
            best = data.results[i]
            best_score = s
        end
    end

    if best and best.poster_path then
        hit = {
            poster = 'https://image.tmdb.org/t/p/w500' .. best.poster_path,
            title  = tmdb_official_title(best),
            url    = tmdb_page_url(best),
            type   = best.media_type,
        }
        remember_poster(key, hit)
        log_info('poster -> ' .. hit.poster)
        if hit.title then
            log_info('title  -> ' .. hit.title)
        end
        return hit
    end

    remember_poster(key, false)
    return nil
end

local poster_gen = 0

local function clear_title_state()
    current_poster = nil
    current_clean_title = nil
    current_tmdb_title = nil
    current_tmdb_url = nil
end

local function apply_tmdb_hit(hit)
    if not hit then
        current_poster = nil
        current_tmdb_title = nil
        current_tmdb_url = nil
        return
    end
    current_poster = hit.poster
    current_tmdb_title = hit.title
    current_tmdb_url = hit.url
end

local function lookup_poster()
    clear_title_state()

    local path = get_property('path')
    if path then
        local title = clean_filename(path)
        if title and title ~= '' then
            current_clean_title = title
        end
    end

    if TMDB_KEY == '' or not path then return end

    local title, year, is_tv = clean_filename(path)
    log_verbose(format(
        'cleaned title="%s" year=%s tv=%s',
        tostring(title), tostring(year), tostring(is_tv)
    ))

    if not title or title == '' then return end

    poster_gen = poster_gen + 1
    local gen = poster_gen

    run_async(function()
        local hit = tmdb_lookup(title, year, is_tv)
        if gen ~= poster_gen then return end
        apply_tmdb_hit(hit)
        tick(true)
        if hit and hit.poster then
            probe_wsrv(hit.poster)
        end
    end)
end

----------------------------------------------------------------
-- Discord IPC transport
----------------------------------------------------------------
local RPC = {
    socket = nil,
    pid    = PID,
    unix   = package.config:sub(1, 1) == '/',
}

local ffi = _G.jit and require 'ffi' or nil

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
    ffi.cdef[[
        struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
        int socket(int, int, int);
        int connect(int, const void*, unsigned);
        int send(int, const void*, size_t, int);
        int recv(int, void*, size_t, int);
        int close(int);
        int fcntl(int, int, int);
    ]]
    local C = ffi.C
    local sockaddr_un_t = ffi.typeof('struct sockaddr_un')
    local RECV_SIZE = 4096
    local recv_buf = ffi.new('char[?]', RECV_SIZE)
    local O_NONBLOCK = 0x800
    local F_GETFL, F_SETFL = 3, 4

    function RPC:connect()
        local paths = ipc_paths()
        for i = 1, #paths do
            local fd = C.socket(1, 1, 0)
            if fd ~= -1 then
                pcall(function()
                    local fl = C.fcntl(fd, F_GETFL, 0)
                    C.fcntl(fd, F_SETFL, fl + O_NONBLOCK)
                end)
                local addr = sockaddr_un_t()
                addr.sun_family = 1
                ffi.copy(addr.sun_path, paths[i])
                if C.connect(fd, addr, ffi.sizeof(addr)) == 0 then
                    self.socket = fd
                    log_verbose('connected ' .. paths[i])
                    return true
                end
                C.close(fd)
            end
        end
        return false
    end

    function RPC:send_raw(data)
        if not self.socket then return false end
        return C.send(self.socket, data, #data, 0) ~= -1
    end

    function RPC:recv_raw(n)
        if not self.socket then return nil end
        local deadline = mp.get_time() + 1.5
        while mp.get_time() < deadline do
            local r
            if n > RECV_SIZE then
                local tmp = ffi.new('char[?]', n)
                r = C.recv(self.socket, tmp, n, 0)
                if r > 0 then return ffi.string(tmp, r) end
            else
                r = C.recv(self.socket, recv_buf, n, 0)
                if r > 0 then return ffi.string(recv_buf, r) end
            end
            if r == 0 then return nil end
        end
        return nil
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
    ]]
    local C = ffi.C
    local INVALID = ffi.cast('HANDLE', -1)
    local GENERIC_READ  = 0x80000000
    local GENERIC_WRITE = 0x40000000
    local OPEN_EXISTING = 3
    local recv_buf = ffi.new('char[?]', 4096)
    local written  = ffi.new('DWORD[1]')
    local readn    = ffi.new('DWORD[1]')

    local function to_wide(s)
        local buf = ffi.new('wchar_t[?]', #s + 1)
        for i = 1, #s do buf[i - 1] = byte(s, i) end
        buf[#s] = 0
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
        return C.WriteFile(self.socket, data, #data, written, nil) ~= 0
    end

    function RPC:recv_raw(n)
        if not self.socket then return nil end
        if n > 4096 then
            local tmp = ffi.new('char[?]', n)
            if C.ReadFile(self.socket, tmp, n, readn, nil) == 0 or readn[0] == 0 then
                return nil
            end
            return ffi.string(tmp, readn[0])
        end
        if C.ReadFile(self.socket, recv_buf, n, readn, nil) == 0 or readn[0] == 0 then
            return nil
        end
        return ffi.string(recv_buf, readn[0])
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
        self.socket:write(data)
        self.socket:flush()
        return true
    end

    function RPC:recv_raw(n)
        if not self.socket then return nil end
        return self.socket:read(n)
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

    function RPC:send_raw(data)
        if not self.socket then return false end
        local sent, total = 0, #data
        while sent < total do
            local n = self.socket:send(data, sent + 1)
            if not n then return false end
            sent = sent + n
        end
        return true
    end

    function RPC:recv_raw(n)
        if not self.socket then return nil end
        self.socket:settimeout(1.5)
        return self.socket:receive(n)
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
function RPC:handshake()
    if self.socket then return true end
    if not self:connect() then
        log_warn('no Discord IPC pipe (is Discord running?)')
        return false
    end

    local body = format_json{ v = 1, client_id = CLIENT_ID }
    if not self:send_raw(pack(0, body)) then
        log_error('handshake send failed')
        self:close()
        return false
    end

    local hdr = self:recv_raw(8)
    if not hdr or #hdr < 8 then
        log_error('handshake recv failed')
        self:close()
        return false
    end

    local _, len = unpack_header(hdr)
    local res = parse_json(self:recv_raw(len) or '')
    if not res or res.evt ~= 'READY' then
        log_error('handshake not READY (check client_id)')
        self:close()
        return false
    end

    log_info('connected to Discord')
    return true
end

function RPC:set_activity(activity)
    if not self.socket and not self:handshake() then
        return false
    end

    local body = format_json{
        cmd   = 'SET_ACTIVITY',
        nonce = next_nonce(),
        args  = { pid = PID, activity = activity },
    }

    if not self:send_raw(pack(1, body)) then
        log_warn('send failed - reconnecting')
        self:close()
        if not self:handshake() then return false end
        return self:send_raw(pack(1, body))
    end
    return true
end

function RPC:shutdown_fast()
    self:close()
end

----------------------------------------------------------------
-- Presence updates
----------------------------------------------------------------
local last = {
    title = nil, state = nil, pos = -1, dur = -1,
    pause = nil, idle = nil, poster = nil,
    tmdb_title = nil, tmdb_url = nil,
}
local timer = nil
local activity = {
    type                = ACTIVITY_WATCHING,
    name                = '',
    status_display_type = 2,
    details             = '',
    state               = '',
    assets              = {
        large_image = FALLBACK_IMG,
        large_text  = FALLBACK_TXT,
    },
}
local timestamps = { start = 0, ['end'] = 0 }

local function format_time(sec)
    sec = floor(sec)
    if sec < 0 then sec = 0 end
    local h = floor(sec / 3600)
    local m = floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return format('%d:%02d:%02d', h, m, s)
    end
    return format('%d:%02d', m, s)
end

local function presence_state(idle, pause, pos_i, dur_i)
    if idle then
        return 'Idle'
    end
    local remain = dur_i > 0 and (dur_i - pos_i) or 0
    local times = format_time(pos_i) .. ' elapsed · ' .. format_time(remain) .. ' left'
    if pause then
        return 'Paused · ' .. times
    end
    return 'Playing · ' .. times
end

tick = function(force)
    if not enabled then return end

    local raw_title = get_property('media-title') or get_property('filename') or 'Unknown'
    local title = current_tmdb_title or current_clean_title or raw_title
    if #title > 120 then title = sub(title, 1, 117) .. '…' end

    local pos   = get_property_number('time-pos') or 0
    local dur   = get_property_number('duration') or 0
    local pause = get_property_bool('pause')
    local idle  = get_property_bool('idle-active')
    local pos_i = floor(pos)
    local dur_i = floor(dur)
    local state = presence_state(idle, pause, pos_i, dur_i)

    -- While paused/idle the timer is stopped; still skip no-op sends
    if not force
       and title == last.title
       and state == last.state
       and pause == last.pause
       and idle == last.idle
       and dur_i == last.dur
       and current_poster == last.poster
       and current_tmdb_title == last.tmdb_title
       and current_tmdb_url == last.tmdb_url
       and pos_i == last.pos
    then
        return
    end

    -- type 3 = Watching. status_display_type 2 = use details after
    -- "Watching", so friends see "Watching The Title" not the app name.
    activity.type                = ACTIVITY_WATCHING
    activity.name                = title
    activity.status_display_type = 2
    activity.details             = title
    activity.state               = state
    activity.details_url         = current_tmdb_url
    activity.state_url           = current_tmdb_url
    activity.assets.large_image = presence_image(current_poster)
    activity.assets.large_text  = current_poster and title or FALLBACK_TXT
    activity.assets.large_url   = current_tmdb_url

    local small_image, small_text
    if idle then
        small_image, small_text = SMALL_IDLE, 'Idle'
    elseif pause then
        small_image, small_text = SMALL_PAUSE, 'Paused'
    else
        small_image, small_text = SMALL_PLAY, 'Playing'
    end
    if small_image and small_image ~= '' then
        activity.assets.small_image = small_image
        activity.assets.small_text  = small_text
    else
        activity.assets.small_image = nil
        activity.assets.small_text  = nil
    end

    -- Discord animates timestamps from wall clock even if we stop sending.
    -- Only attach start/end while actually playing so the bar freezes on pause.
    if not idle and not pause and dur > 0 then
        local now = time()
        timestamps.start  = now - pos_i
        timestamps['end'] = now - pos_i + dur_i
        activity.timestamps = timestamps
    else
        activity.timestamps = nil
    end

    if RPC:set_activity(activity) then
        last.title  = title
        last.state  = state
        last.pos    = pos_i
        last.dur    = dur_i
        last.pause  = pause
        last.idle   = idle
        last.poster = current_poster
        last.tmdb_title = current_tmdb_title
        last.tmdb_url = current_tmdb_url
    end
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function start_timer()
    stop_timer()
    if not enabled then return end
    if get_property_bool('pause') or get_property_bool('idle-active') then
        return
    end
    -- Background refresh only. Pause / seek / new file still call tick(true).
    timer = mp.add_periodic_timer(INTERVAL, function() tick(false) end)
end

local watching_pos = false

local function on_time_pos(_, pos)
    if not enabled or not pos then return end
    if floor(pos) ~= last.pos then
        tick(true)
    end
end

local function watch_time_pos(on)
    if on and not watching_pos then
        mp.observe_property('time-pos', 'number', on_time_pos)
        watching_pos = true
    elseif not on and watching_pos then
        mp.unobserve_property(on_time_pos)
        watching_pos = false
    end
end

local function on_pause(_, paused)
    if paused == nil then return end
    tick(true)
    if paused then
        stop_timer()
        watch_time_pos(true)
    else
        watch_time_pos(false)
        start_timer()
    end
end

mp.register_event('file-loaded', function()
    lookup_poster()
    tick(true)
    start_timer()
end)

mp.register_event('end-file', function()
    stop_timer()
    watch_time_pos(false)
    clear_title_state()
    last.title = nil
    if enabled and RPC.socket then
        RPC:set_activity(nil)
    end
end)

-- Seek / resume while playing: refresh elapsed text, but coalesce seek-spam
local RESTART_DEBOUNCE = 0.4
local last_restart_at  = 0
local restart_pending  = false

mp.register_event('playback-restart', function()
    if not enabled then return end

    local now = mp.get_time()
    if now - last_restart_at < RESTART_DEBOUNCE then
        if not restart_pending then
            restart_pending = true
            mp.add_timeout(RESTART_DEBOUNCE, function()
                restart_pending = false
                last_restart_at = mp.get_time()
                tick(true)
                start_timer()
            end)
        end
        return
    end

    last_restart_at = now
    tick(true)
    start_timer()
end)

mp.observe_property('pause', 'bool', on_pause)

mp.observe_property('idle-active', 'bool', function(_, idle)
    if idle == nil then return end
    tick(true)
    if idle then
        stop_timer()
        watch_time_pos(false)
    else
        start_timer()
    end
end)

mp.register_event('shutdown', function()
    stop_timer()
    watch_time_pos(false)
    save_poster_cache()
    RPC:shutdown_fast()
end)

mp.add_key_binding(KEY_TOGGLE, 'discord-mpv-rpc-toggle', function()
    enabled = not enabled
    if enabled then
        tick(true)
        start_timer()
        mp.osd_message('Discord RPC: on')
    else
        stop_timer()
        watch_time_pos(false)
        if RPC.socket then RPC:set_activity(nil) end
        mp.osd_message('Discord RPC: off')
    end
end)

if enabled then
    mp.add_timeout(1.5, function()
        load_poster_cache()
        if RPC:handshake() then
            tick(true)
            start_timer()
        else
            log_warn('will retry on next file-loaded')
        end
    end)
end
