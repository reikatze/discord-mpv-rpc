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
    key_toggle      = 'D',
    enabled         = true,
    poster_fit      = 'contain',
    tmdb_episode_lookup = true,
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
local TMDB_EPISODE_LOOKUP = o.tmdb_episode_lookup ~= false
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

-- Keep outgoing text within a conservative byte budget without splitting UTF-8.
local function truncate_utf8(text, limit)
    if #text <= limit then return text end
    local cut = limit - 3
    while cut > 0 do
        local next_byte = byte(text, cut + 1)
        if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
        cut = cut - 1
    end
    return sub(text, 1, cut) .. '…'
end

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
local poster_cache_save_timer = nil

-- Short-lived in-memory TMDb response cache for reusable search responses.
-- Specialized episode/alternative-title data is not duplicated here because
-- those paths already have their own persistent/specialized caches.
local tmdb_request_cache = {}
local tmdb_inflight = {} -- [url] = { waiters = { coroutine, ... } }
local TMDB_REQUEST_CACHE_TTL = 24 * 60 * 60
local TMDB_REQUEST_CACHE_MAX = 512

-- Missing exact episodes are persisted briefly so a season TMDb has not added
-- yet is not retried on every playback. Successful episode metadata is stored
-- only as the transformed persistent episode entry used by Discord.
local TMDB_EPISODE_NEGATIVE_CACHE_TTL = 24 * 60 * 60

-- Proactive pacing limits bursts from difficult/ambiguous lookups. Cache hits
-- and coalesced in-flight requests do not consume a new request slot.
local TMDB_MIN_REQUEST_INTERVAL = 0.25
local tmdb_next_request_at = 0

-- Every new file invalidates the previous lookup. An in-flight HTTP request
-- may finish, but a stale coroutine is stopped before it can launch more
-- searches, alias requests, or episode requests.
local tmdb_lookup_generation = 0
-- Retain one failure marker for the active file, including alias-request failures.
local tmdb_failed_generation = nil

local function tmdb_lookup_cancelled(token)
    return token ~= nil and token ~= tmdb_lookup_generation
end

local function trim_memory_cache(cache, max_entries)
    local now = mp.get_time()
    local count = 0

    -- Expired entries are always the first to go.
    for key, entry in pairs(cache) do
        if type(entry) == 'table' and entry.expires and now >= entry.expires then
            cache[key] = nil
        else
            count = count + 1
        end
    end

    if count <= max_entries then return end

    -- These caches are optimization-only. Arbitrary eviction keeps memory
    -- bounded without adding LRU bookkeeping to the hot path.
    local remove = count - max_entries
    for key in pairs(cache) do
        cache[key] = nil
        remove = remove - 1
        if remove <= 0 then break end
    end
end

-- Negative poster-cache entries expire instead of permanently remembering
-- that TMDb had no usable result. Existing boolean false entries remain
-- compatible and are treated as legacy permanent negatives.
local TMDB_NEGATIVE_CACHE_TTL = 7 * 24 * 60 * 60

local current_poster = nil
local current_clean_title = nil
local current_tmdb_title = nil
local current_tmdb_url = nil
local current_episode = nil

-- Parsed filename cache: mpv can trigger several events for the same path.
local parsed_filename_cache = {}
local PARSED_FILENAME_CACHE_MAX = 256

-- Persistent TTLs use wall-clock timestamps so they survive mpv restarts.
-- v5.x stored some negative-cache expiries using mp.get_time(), which is
-- process-relative and therefore cannot be trusted after a restart.
local function persistent_entry_expired(entry)
    if type(entry) ~= 'table' then return false end
    if entry.expires_at then
        local expires_at = tonumber(entry.expires_at)
        return expires_at ~= nil and time() >= expires_at
    end
    -- Legacy persisted negative entries with `expires` used mp.get_time().
    -- Expire them once on v6 rather than interpreting a previous process's
    -- monotonic clock as if it belonged to this process.
    if entry.negative and entry.expires then
        return true
    end
    return false
end

local function prune_poster_cache_expired()
    local removed = 0
    for key, entry in pairs(poster_cache) do
        if persistent_entry_expired(entry) then
            poster_cache[key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        poster_cache_dirty = true
        log_verbose(format('pruned %d expired persistent cache entr%s',
            removed, removed == 1 and 'y' or 'ies'))
    end
    return removed
end

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
        prune_poster_cache_expired()
        log_verbose('loaded poster cache from ' .. CACHE_PATH)
    end
end

local function save_poster_cache()
    prune_poster_cache_expired()
    if not poster_cache_dirty then return end

    -- Write next to this script. Do not os.execute('mkdir'): that flashes
    -- a Command Prompt on Windows.
    local encoded = format_json(poster_cache)
    if not encoded then
        log_warn('could not encode poster cache')
        return
    end
    local tmp_path = CACHE_PATH .. '.' .. tostring(PID) .. '.tmp'
    local f = io.open(tmp_path, 'w')
    if not f then
        log_warn('could not write poster cache to ' .. tmp_path)
        return
    end

    local ok, err = pcall(function()
        assert(f:write(encoded))
        assert(f:flush())
        assert(f:close())
    end)

    if not ok then
        pcall(function() f:close() end)
        os.remove(tmp_path)
        log_warn('could not write poster cache: ' .. tostring(err))
        return
    end

    local renamed = os.rename(tmp_path, CACHE_PATH)
    if not renamed and IS_WINDOWS then
        -- The Windows C runtime may refuse to rename over an existing file.
        -- Fall back to replacement while keeping the temp file as the
        -- crash-safe copy until the final rename succeeds.
        os.remove(CACHE_PATH)
        renamed = os.rename(tmp_path, CACHE_PATH)
    end
    if not renamed then
        -- Keep the complete temporary copy for recovery, including on Windows
        -- if removal succeeded but the final rename failed.
        log_warn('could not replace poster cache; retained ' .. tmp_path)
        return
    end

    poster_cache_dirty = false
    log_verbose('poster cache saved to ' .. CACHE_PATH)
end

local MAX_CACHE_ENTRIES = 1000

local function trim_poster_cache()
    prune_poster_cache_expired()
    local count = 0
    for _ in pairs(poster_cache) do
        count = count + 1
    end
    if count <= MAX_CACHE_ENTRIES then return end

    -- JSON object order is intentionally not relied upon; this is a simple
    -- bounded-cache fallback rather than a full LRU implementation.
    local remove = count - MAX_CACHE_ENTRIES
    for key in pairs(poster_cache) do
        poster_cache[key] = nil
        remove = remove - 1
        if remove <= 0 then break end
    end
end

local function schedule_poster_cache_save()
    if poster_cache_save_timer then return end
    poster_cache_save_timer = mp.add_timeout(2, function()
        poster_cache_save_timer = nil
        save_poster_cache()
    end)
end

local function remember_poster(key, value)
    poster_cache[key] = value
    trim_poster_cache()
    poster_cache_dirty = true
    schedule_poster_cache_save()
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
    if extra and extra.discard_body then
        -- Keep the HTTP response body out of Lua. This is used for the wsrv
        -- availability probe so a successful image GET does not allocate a
        -- potentially large poster in memory.
        args[#args + 1] = '-o'
        args[#args + 1] = IS_WINDOWS and 'NUL' or '/dev/null'
    end
    args[#args + 1] = url

    local function finish(res)
        if not res then
            return nil, 0, true
        end

        -- `res.status` is the curl process exit status in mpv's subprocess
        -- result. The HTTP status is independently emitted by %{http_code}
        -- and parsed from stdout. Do not confuse the two: HTTP 000 is not
        -- itself proof of a transport failure, and a curl exit code of 0 is
        -- not an HTTP status.
        local process_status = tonumber(res.status)
        local process_error = process_status ~= nil and process_status ~= 0
        local body, http_status = split_curl(res.stdout or '')
        if process_status == nil then
            process_error = true
        end
        return body, http_status, process_error
    end

    local co = running_co()
    if co then
        local done
        local handle
        handle = mp.command_native_async({
            name           = 'subprocess',
            args           = args,
            playback_only  = false,
            capture_stdout = true,
            capture_stderr = false,
        }, function(_, res)
            if done then return end
            done = true
            if extra and extra.on_async_complete then
                pcall(extra.on_async_complete, handle)
            end
            local body, status, transport_error = finish(res)
            local ok, err = resume_co(co, body, status, transport_error)
            if not ok then
                log_error('coroutine: ' .. tostring(err))
            end
        end)
        if handle and extra and extra.on_async_handle then
            pcall(extra.on_async_handle, handle)
        end
        return yield_co()
    end

    return finish(utils.subprocess{ args = args, cancellable = false })
end

local function curl_get(url, control)
    return curl_request(url, {
        headers = { 'Accept: application/json' },
        on_async_handle = control and control.on_async_handle or nil,
        on_async_complete = control and control.on_async_complete or nil,
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
local wsrv_status = {} -- [url] = { ok = boolean, expires = timestamp }
local WSRV_FAILURE_TTL = 10 * 60
local WSRV_SUCCESS_TTL = 24 * 60 * 60
local WSRV_STATUS_CACHE_MAX = 256

-- Service-level state avoids probing every new poster when wsrv itself is
-- unavailable. Per-URL state is retained as a secondary cache.
local wsrv_global = {
    ok = nil,          -- nil = unknown, true = available, false = unavailable
    expires = 0,
}
local wsrv_probe_inflight = false
local WSRV_CACHE_KEY = '__wsrv_service'
local wsrv_persistent_loaded = false

local function wsrv_load_persistent_state()
    if wsrv_persistent_loaded then return end
    wsrv_persistent_loaded = true
    load_poster_cache()

    local entry = poster_cache[WSRV_CACHE_KEY]
    if type(entry) ~= 'table' or type(entry.ok) ~= 'boolean'
        or persistent_entry_expired(entry) then
        if entry ~= nil then
            poster_cache[WSRV_CACHE_KEY] = nil
            poster_cache_dirty = true
        end
        return
    end

    local remaining = math.max(0, tonumber(entry.expires_at or 0) - time())
    if remaining > 0 then
        wsrv_global.ok = entry.ok
        wsrv_global.expires = mp.get_time() + remaining
        log_verbose('restored wsrv service state from persistent cache')
    end
end

local function wsrv_remember_global(ok, ttl)
    wsrv_global.ok = ok
    wsrv_global.expires = mp.get_time() + ttl
    remember_poster(WSRV_CACHE_KEY, {
        ok = ok,
        expires_at = time() + ttl,
    })
end

local function wsrv_global_get()
    wsrv_load_persistent_state()
    if wsrv_global.ok == nil then return nil end
    if mp.get_time() >= wsrv_global.expires then
        wsrv_global.ok = nil
        wsrv_global.expires = 0
        return nil
    end
    return wsrv_global.ok
end

local function wsrv_status_get(url)
    local entry = wsrv_status[url]
    if not entry then return nil end
    if mp.get_time() >= entry.expires then
        wsrv_status[url] = nil
        return nil
    end
    return entry.ok
end

local function wsrv_url(tmdb_url)
    local bare = gsub(tmdb_url, '^https://', '')
    return 'https://wsrv.nl/?url=' .. url_encode(bare)
        .. '&w=512&h=512&fit=contain&cbg=111111'
end

local function presence_image(url)
    if not url or url == '' then
        return FALLBACK_IMG
    end
    if POSTER_FIT ~= 'contain' then
        return url
    end

    local global_known = wsrv_global_get()
    if global_known == false then
        return url
    end

    local known = wsrv_status_get(url)
    if known == false then
        return url
    elseif known == true or global_known == true then
        return wsrv_url(url)
    end

    -- Unknown URLs are still returned through wsrv immediately; probe_wsrv()
    -- is responsible for learning whether the service works.
    return wsrv_url(url)
end

local function probe_wsrv(tmdb_url)
    if POSTER_FIT ~= 'contain' or not tmdb_url then
        return
    end

    local global_known = wsrv_global_get()
    if global_known ~= nil then
        return
    end
    if wsrv_status_get(tmdb_url) ~= nil then
        return
    end
    if wsrv_probe_inflight then
        return
    end

    wsrv_probe_inflight = true
    run_async(function()
        -- Use a normal GET rather than HEAD. Some image/proxy services do
        -- not implement HEAD consistently even though their GET endpoint
        -- works. Discard the image body so the probe remains cheap.
        local _, status, transport_error = curl_request(wsrv_url(tmdb_url), {
            timeout      = '4',
            discard_body = true,
        })

        local ok = (not transport_error and status == 200)
        wsrv_probe_inflight = false

        if ok then
            wsrv_remember_global(true, WSRV_SUCCESS_TTL)
            wsrv_status[tmdb_url] = {
                ok = true,
                expires = mp.get_time() + WSRV_SUCCESS_TTL,
            }
            trim_memory_cache(wsrv_status, WSRV_STATUS_CACHE_MAX)
            log_verbose('wsrv probe succeeded')
        else
            wsrv_remember_global(false, WSRV_FAILURE_TTL)
            wsrv_status[tmdb_url] = {
                ok = false,
                expires = mp.get_time() + WSRV_FAILURE_TTL,
            }
            trim_memory_cache(wsrv_status, WSRV_STATUS_CACHE_MAX)
            log_warn('wsrv failed (' .. tostring(status) .. '), using raw poster for '
                .. WSRV_FAILURE_TTL .. 's')
        end
        tick(false)
    end)
end

----------------------------------------------------------------
-- Filename -> title / year / is_tv
----------------------------------------------------------------
local function basename_without_extension(path)
    local name = match(path, '([^/\\\\]+)$') or path
    return gsub(name, '%.[^%.]+$', '')
end

local function parent_directory(path)
    return match(path, '^(.*)[/\\\\][^/\\\\]+$')
end

local function extract_episode_info(name)
    -- Standard TV/scene forms:
    --   Show.S02E05 / Show S02 E05 / Show S02-E05
    local season, ep = match(name, '[sS](%d+)%s*[-%.]?%s*[eE]%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Explicit season + dash + episode: Show S2 - 03 / S02-03
    season, ep = match(name, '[sS](%d+)%s*%-%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Common alternate notation: Show 2x05 / Show 02x05
    season, ep = match(name, '[%s%._%-](%d+)[xX](%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Explicit words are less ambiguous than bare numbers.
    season, ep = match(name, '[sS]eason%s*(%d+)%s*[,%-]?%s*[eE]pisode%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    season, ep = match(name, '[sS]eason%s*(%d+)%s*[,%-]?%s*[eE]p?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    season, ep = match(name, '[sS](%d+)%s*[eE]pisode%.?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end
    season, ep = match(name, '[sS](%d+)%s*[eE]p%.?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Anime/scene style: Show - 05 - Episode Title
    -- Only treat a number as an episode when it is separated by dashes,
    -- avoiding accidental matches inside the show title.
    ep = match(name, '%s%-%s*(%d+)%s*%-%s*')
    if ep then
        return 1, tonumber(ep), true
    end

    -- Existing parenthesized form: Show - 05 (Episode Title)
    ep = match(name, '%s%-%s*(%d+)%s*%(')
    if ep then
        return 1, tonumber(ep), true
    end

    -- Simple "Show - 05" at the end. Permit common release/version tags
    -- after the episode number (e.g. "Show - 05v2"), but don't treat an
    -- arbitrary number elsewhere in a filename as an episode.
    ep = match(name, '%s%-%s*(%d+)[vV]%d+%s*$')
    if ep then
        return 1, tonumber(ep), true
    end
    ep = match(name, '%s%-%s*(%d+)%s*$')
    if ep then
        return 1, tonumber(ep), true
    end

    return nil, nil, false
end

local function extract_year(name)
    return match(name, '%((19%d%d)%)')
        or match(name, '%((20%d%d)%)')
        or match(name, '%f[%d](19%d%d)%f[%D]')
        or match(name, '%f[%d](20%d%d)%f[%D]')
end

local function derive_title(name, year, is_tv)
    if is_tv then
        return match(name, '^(.-)%s*[sS]%d+%s*[-%.]?%s*[eE]%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*%-%s*%d+')
            or match(name, '^(.-)[%s%._%-]%d+[xX]%d+')
            or match(name, '^(.-)%s*[sS]eason%s*%d+%s*[,%-]?%s*[eE]pisode%s*%d+')
            or match(name, '^(.-)%s*[sS]eason%s*%d+%s*[,%-]?%s*[eE]p?%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*[eE]pisode%.?%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*[eE]p%.?%s*%d+')
            or match(name, '^(.-)%s*%-%s*%d+%s*%-%s*')
            or match(name, '^(.-)%s*%-%s*%d+%s*%(')
            or match(name, '^(.-)%s*%-%s*%d+%s*[vV]%d+%s*$')
            or match(name, '^(.-)%s*%-%s*%d+%s*$')
            or name
    end

    if year then
        return match(name, '^(.-)%s*%(' .. year .. '%)')
            or match(name, '^(.-)[%s%._%-]+' .. year)
            or match(name, '^(.-)' .. year)
            or name
    end

    return name
end

local function normalize_filename_title(title)
    title = gsub(title, '%b[]', ' ')
    title = gsub(title, '%b()', ' ')
    title = gsub(title, '[%.%_]', ' ')
    title = gsub(title, '%s*%-%s*$', '')
    title = gsub(title, '^%s*%-%s*', '')

    -- Remove common release tags only when they occur at the end of the
    -- derived title. These are deliberately conservative so legitimate
    -- words/numbers in titles are not stripped.
    local release_suffixes = {
        'WEB%-DL', 'WEBRip', 'Blu%-Ray', 'BluRay', 'BRRip', 'HDRip',
        'DVDRip', 'HDTV', 'AMZN', 'NF', 'DSNP', 'HMAX', 'MAX',
        'PROPER', 'REPACK', 'REMUX', 'x26[45]', 'h26[45]', 'HEVC',
        'AAC', 'AC3', 'DTS', 'DDP%d*', 'Atmos', '%d%d%d%dp', '%dK',
    }
    local previous
    repeat
        previous = title
        for i = 1, #release_suffixes do
            title = gsub(title, '%s*[%._%-]%s*' .. release_suffixes[i] .. '%s*$', '')
            title = gsub(title, '%s+' .. release_suffixes[i] .. '%s*$', '')
        end
    until title == previous

    title = gsub(title, '%s+', ' ')
    title = gsub(title, '^%s+', '')
    title = gsub(title, '%s+$', '')
    return title
end

local function directory_context(path)
    local dir = parent_directory(path)
    if not dir or dir == '' then return nil, nil end

    local name = match(dir, '([^/\\]+)$') or dir
    local year = extract_year(name)
    if not year then return nil, nil end

    local title = name
    title = gsub(title, '^%b[]%s*', '')
    title = gsub(title, '%s*%(' .. year .. '%)%s*$', '')
    title = normalize_filename_title(title)
    if title == '' then return nil, year end
    return title, year
end

local function trim_parsed_filename_cache()
    local count = 0
    for _ in pairs(parsed_filename_cache) do count = count + 1 end
    if count <= PARSED_FILENAME_CACHE_MAX then return end
    for key in pairs(parsed_filename_cache) do
        parsed_filename_cache[key] = nil
        count = count - 1
        if count <= PARSED_FILENAME_CACHE_MAX then break end
    end
end

local function clean_filename(path)
    local cached = parsed_filename_cache[path]
    if cached then
        return cached.title, cached.year, cached.is_tv, cached.season, cached.episode
    end

    local name = basename_without_extension(path)
    name = gsub(name, '^%b[]%s*', '')

    local season, ep, is_tv = extract_episode_info(name)
    local year = extract_year(name)
    local title = derive_title(name, year, is_tv)
    title = normalize_filename_title(title)

    -- If the filename omits its year, inherit a year from a media/show
    -- directory such as "[Judas] Koukaku Kidoutai (2026)". A year explicitly
    -- present in the filename always wins.
    if not year then
        local dir_title, dir_year = directory_context(path)
        if dir_year then
            year = dir_year
            -- If the directory has a useful title and the filename title is
            -- empty/generic, prefer the directory title. Otherwise preserve
            -- the filename title because it may contain a more specific alias.
            if (not title or title == '') and dir_title and dir_title ~= '' then
                title = dir_title
            end
        end
    end

    local result = {
        title = title, year = year, is_tv = is_tv, season = season, episode = ep,
    }
    parsed_filename_cache[path] = result
    trim_parsed_filename_cache()
    return title, year, is_tv, season, ep
end

local function tagged_title()
    local meta = mp.get_property_native('metadata')
    if type(meta) ~= 'table' then
        return nil
    end
    local t = meta.title or meta.TITLE or meta.Title
    if type(t) ~= 'string' then
        return nil
    end
    t = gsub(t, '^%s+', '')
    t = gsub(t, '%s+$', '')
    if #t < 2 or match(t, '^https?://') or match(t, '%.%w%w%w%w?$') then
        return nil
    end
    return t
end

local function chapter_title()
    local title = get_property('chapter-metadata/title')
    if title and title ~= '' then
        return title
    end
    local idx = get_property_number('chapter')
    if not idx then
        return nil
    end
    title = get_property('chapter-list/' .. floor(idx) .. '/title')
    if title and title ~= '' then
        return title
    end
    return nil
end

local function meaningful_chapter_title()
    local title = chapter_title()
    if not title then return nil end

    title = gsub(title, '^%s+', '')
    title = gsub(title, '%s+$', '')
    if title == '' then return nil end

    -- Some muxers/editors use the chapter timestamp itself as the title.
    if match(title, '^%d%d?:%d%d:%d%d$') or match(title, '^%d%d?:%d%d:%d%d[.,]%d+$') then
        return nil
    end

    -- Avoid displaying generic scene/chapter labels when there is no useful
    -- episode title. Real descriptive chapter names are still preserved.
    local lower = title:lower()
    if match(lower, '^chapter%s+%d+$')
        or match(lower, '^scene%s+%d+$')
        or lower == 'no scene description'
        or lower == 'no chapter description' then
        return nil
    end

    return title
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

local function normalize_match_title(s)
    if not s then return '' end
    s = s:lower()
    s = gsub(s, '[&]', ' and ')
    s = gsub(s, '[^%w]+', ' ')
    s = gsub(s, '^%s+', '')
    s = gsub(s, '%s+$', '')
    s = gsub(s, '%s+', ' ')
    return s
end

local function title_tokens(s)
    local tokens = {}
    for token in s:gmatch('%S+') do
        tokens[#tokens + 1] = token
    end
    return tokens
end

local function title_similarity(a, b)
    a = normalize_match_title(a)
    b = normalize_match_title(b)
    if a == '' or b == '' then return 0 end
    if a == b then return 1 end

    local ta, tb = title_tokens(a), title_tokens(b)
    local counts = {}
    for i = 1, #tb do
        counts[tb[i]] = (counts[tb[i]] or 0) + 1
    end

    local common = 0
    for i = 1, #ta do
        if counts[ta[i]] and counts[ta[i]] > 0 then
            common = common + 1
            counts[ta[i]] = counts[ta[i]] - 1
        end
    end

    local union = #ta + #tb - common
    local jaccard = union > 0 and common / union or 0
    local dice = (#ta + #tb) > 0 and (2 * common) / (#ta + #tb) or 0

    -- Containment is useful for subtitles: "Dune" should remain a plausible
    -- match for "Dune Part Two", but not score as highly as an exact match.
    local containment = common / math.min(#ta, #tb)

    local prefix = 0
    local limit = math.min(#ta, #tb)
    while prefix < limit and ta[prefix + 1] == tb[prefix + 1] do
        prefix = prefix + 1
    end
    local prefix_score = prefix / math.max(#ta, #tb)

    -- Prefer exact/near-exact token sets, then useful subtitle containment.
    return math.max(jaccard, dice * 0.96, containment * 0.82, prefix_score * 0.90)
end

local function best_title_similarity(query_title, result)
    local official = result and (result.title or result.name)
    local original = result and (result.original_title or result.original_name)
    local best = title_similarity(query_title, official)
    if original and original ~= official then
        best = math.max(best, title_similarity(query_title, original))
    end
    return best
end

local function score_multi_result(r, query_title, year, prefer_tv)
    if not r or r.media_type == 'person' then
        return -1
    end
    if r.media_type ~= 'movie' and r.media_type ~= 'tv' then
        return -1
    end

    local similarity = best_title_similarity(query_title, r)
    local score = similarity * 50

    if similarity >= 0.98 then
        score = score + 10
    elseif similarity >= 0.85 then
        score = score + 5
    elseif similarity >= 0.70 then
        score = score + 2
    elseif similarity < 0.35 then
        score = score - 15
    end

    if r.poster_path then score = score + 8 end

    local date = r.release_date or r.first_air_date or ''
    local ry = match(date, '^(%d%d%d%d)')
    if year and ry == year then
        score = score + 20
    elseif year and ry then
        local qy, cy = tonumber(year), tonumber(ry)
        local delta = qy and cy and math.abs(qy - cy) or 99
        if delta <= 1 then
            score = score + 3
        elseif delta <= 3 then
            score = score - 3
        else
            score = score - 8
        end
    end

    if prefer_tv and r.media_type == 'tv' then
        score = score + 4
    elseif not prefer_tv and r.media_type == 'movie' then
        score = score + 4
    end
    return score
end

local function tmdb_get_json(url, inflight)
    local body, status, transport_error = curl_get(url, {
        on_async_handle = function(handle)
            if inflight then inflight.async_handle = handle end
        end,
        on_async_complete = function(handle)
            if inflight and inflight.async_handle == handle then
                inflight.async_handle = nil
            end
        end,
    })

    if status == 429 then
        tmdb_backoff_until = mp.get_time() + tmdb_backoff_sec
        log_warn('TMDb 429, backing off ' .. tmdb_backoff_sec .. 's')
        tmdb_backoff_sec = math.min(tmdb_backoff_sec * 2, 300)
        return nil, 'rate_limited'
    end

    -- Only HTTP 200 is a successful TMDb API response. Do not let an error
    -- response containing JSON get mistaken for a valid search result.
    if status ~= 200 then
        if transport_error then
            log_warn('TMDb request failed (transport error, status=' .. tostring(status) .. ')')
            return nil, 'transport'
        end
        if status == 404 then
            log_verbose('TMDb resource not found (404)')
            return nil, 'not_found'
        end
        log_warn('TMDb request failed (HTTP status=' .. tostring(status) .. ')')
        return nil, 'http_error'
    end

    if not body or body == '' then
        log_warn('TMDb request returned an empty 200 response')
        return nil, 'empty'
    end

    local data = parse_json(body)
    if type(data) ~= 'table' then
        log_warn('TMDb response was not a JSON object')
        return nil, 'invalid_json'
    end
    if url:find('/search/', 1, true) and type(data.results) ~= 'table' then
        return nil, 'invalid_response'
    end
    if url:find('/alternative_titles?', 1, true)
        and type(data.titles or data.results) ~= 'table' then
        return nil, 'invalid_response'
    end
    if transport_error then return nil, 'transport' end

    tmdb_backoff_sec = 30
    return data, 'ok'
end

local function tmdb_request_cache_get(key)
    local entry = tmdb_request_cache[key]
    if not entry then return nil, false end
    if mp.get_time() >= entry.expires then
        tmdb_request_cache[key] = nil
        return nil, false
    end
    return entry.data, true
end

local function tmdb_request_cache_put(key, data)
    tmdb_request_cache[key] = {
        data = data,
        expires = mp.get_time() + TMDB_REQUEST_CACHE_TTL,
    }
    trim_memory_cache(tmdb_request_cache, TMDB_REQUEST_CACHE_MAX)
end

local function tmdb_resume_waiters(inflight, data, outcome)
    local waiters = inflight.waiters
    inflight.waiters = {}
    for i = 1, #waiters do
        local waiter = waiters[i]
        local ok, err = resume_co(waiter, data, outcome)
        if not ok then
            log_error('TMDb waiter coroutine: ' .. tostring(err))
        end
    end
end

local function tmdb_abort_inflight_requests()
    local aborted = 0
    for url, inflight in pairs(tmdb_inflight) do
        inflight.cancelled = true
        tmdb_inflight[url] = nil
        tmdb_resume_waiters(inflight, nil, 'cancelled')
        if inflight.async_handle then
            pcall(mp.abort_async_command, inflight.async_handle)
            inflight.async_handle = nil
            aborted = aborted + 1
        end
    end
    if aborted > 0 then
        log_verbose(format('aborted %d stale TMDb curl request%s',
            aborted, aborted == 1 and '' or 's'))
    end
end

local function tmdb_wait_for_request_slot(lookup_token, inflight)
    local now = mp.get_time()
    local slot = math.max(now, tmdb_next_request_at)
    tmdb_next_request_at = slot + TMDB_MIN_REQUEST_INTERVAL

    local delay = slot - now
    if delay <= 0 then
        return not tmdb_lookup_cancelled(lookup_token)
            or (inflight and #inflight.waiters > 0)
    end

    local co = running_co()
    if not co then
        -- TMDb lookups normally run in a coroutine. Never block mpv's main
        -- thread merely to enforce pacing if called synchronously.
        return true
    end

    local resumed = false
    mp.add_timeout(delay, function()
        if resumed then return end
        resumed = true
        local ok, err = resume_co(co)
        if not ok then
            log_error('TMDb pacing coroutine: ' .. tostring(err))
        end
    end)
    yield_co()

    -- If this file became stale while queued, cancel the request unless a
    -- current lookup has joined the same in-flight URL and still needs it.
    return not tmdb_lookup_cancelled(lookup_token)
        or (inflight and #inflight.waiters > 0)
end

local function tmdb_get_json_cached_impl(url, lookup_token, cache_response)
    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end

    local cached, found = tmdb_request_cache_get(url)
    if found then
        log_verbose('TMDb request cache hit')
        return cached, 'ok'
    end

    -- Coalesce simultaneous requests for the same URL. If any caller wants
    -- the generic response cached, preserve that preference for the request.
    local co = running_co()
    local inflight = tmdb_inflight[url]
    if inflight and co then
        if cache_response ~= false then
            inflight.cache_response = true
        end
        inflight.waiters[#inflight.waiters + 1] = co
        log_verbose('TMDb request already in flight; waiting')
        local data, outcome = yield_co()
        if tmdb_lookup_cancelled(lookup_token) then
            return nil, 'cancelled'
        end
        return data, outcome
    end

    inflight = {
        waiters = {},
        cache_response = cache_response ~= false,
        async_handle = nil,
        cancelled = false,
    }
    tmdb_inflight[url] = inflight

    if mp.get_time() < tmdb_backoff_until then
        tmdb_inflight[url] = nil
        tmdb_resume_waiters(inflight, nil, 'rate_limited')
        return nil, 'rate_limited'
    end

    if not tmdb_wait_for_request_slot(lookup_token, inflight) then
        if tmdb_inflight[url] == inflight then tmdb_inflight[url] = nil end
        tmdb_resume_waiters(inflight, nil, 'cancelled')
        return nil, 'cancelled'
    end

    -- Backoff may have started while this request was waiting for its slot.
    if mp.get_time() < tmdb_backoff_until then
        tmdb_inflight[url] = nil
        tmdb_resume_waiters(inflight, nil, 'rate_limited')
        return nil, 'rate_limited'
    end

    local data, outcome = tmdb_get_json(url, inflight)
    if tmdb_inflight[url] == inflight then
        tmdb_inflight[url] = nil
    end

    if inflight.cancelled then
        data, outcome = nil, 'cancelled'
    end

    -- Only reusable search responses live in the generic request cache.
    -- Episode and alternative-title callers pass cache_response=false and
    -- store only their transformed/specialized representation.
    if data and outcome == 'ok' and inflight.cache_response then
        tmdb_request_cache_put(url, data)
    end

    tmdb_resume_waiters(inflight, data, outcome)

    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end
    return data, outcome
end

local function tmdb_get_json_cached(url, lookup_token, cache_response)
    local data, outcome = tmdb_get_json_cached_impl(url, lookup_token, cache_response)
    if outcome ~= 'ok' and outcome ~= 'cancelled'
        and lookup_token == tmdb_lookup_generation then
        tmdb_failed_generation = lookup_token
    end
    return data, outcome
end

local function tmdb_episode(show_id, season, ep, lookup_token)
    if not show_id or not season or not ep then
        return nil
    end
    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end

    local url = format(
        'https://api.themoviedb.org/3/tv/%s/season/%d/episode/%d?api_key=%s&language=%s',
        tostring(show_id), season, ep, TMDB_KEY, url_encode(TMDB_LANG)
    )
    log_verbose(format(
        'TMDb episode id=%s S%02dE%02d',
        tostring(show_id), season, ep
    ))

    -- The caller persists only the compact episode entry Discord needs, so
    -- do not duplicate the full raw episode JSON in the generic HTTP cache.
    return tmdb_get_json_cached(url, lookup_token, false)
end

local TMDB_MIN_MATCH_SCORE = 55
local TMDB_MIN_MATCH_MARGIN = 8
local TMDB_ALIAS_CACHE_TTL = 30 * 24 * 60 * 60
local TMDB_ALIAS_CACHE_MAX = 256
local tmdb_alias_cache = {}

local function tmdb_episode_for_requested_season(show_id, season, ep, lookup_token)
    if not show_id or not season or not ep then
        return nil
    end

    -- Query exactly the season/episode parsed from the filename. If TMDb
    -- returns 404 (for example, a season it has not added yet), stop there.
    -- Do not query show details and never substitute another season.
    local data, outcome = tmdb_episode(show_id, season, ep, lookup_token)
    if not data then
        return nil, outcome
    end

    local requested_season = tonumber(season)
    local requested_ep = tonumber(ep)
    local got_season = tonumber(data.season_number)
    local got_ep = tonumber(data.episode_number)

    if got_season == requested_season and got_ep == requested_ep then
        return data, outcome
    end

    log_verbose(format(
        'TMDb episode identity mismatch: requested S%02dE%02d, got S%02dE%02d; rejecting',
        requested_season or 0,
        requested_ep or 0,
        got_season or 0,
        got_ep or 0))
    return nil, 'mismatch'
end

local function tmdb_episode_persistent_key(show_id, season, ep)
    return format('episode:%s:S%02dE%02d:%s', tostring(show_id), season, ep, TMDB_LANG)
end

local function tmdb_season_episode_count(show_id, season, lookup_token)
    local key = format('season-count:%s:S%02d', tostring(show_id), season)
    local cached = poster_cache[key]
    if type(cached) == 'table' and not persistent_entry_expired(cached) then
        return cached.count
    end

    local url = format(
        'https://api.themoviedb.org/3/tv/%s/season/%d?api_key=%s&language=%s',
        tostring(show_id), season, TMDB_KEY, url_encode(TMDB_LANG))
    local data, outcome = tmdb_get_json_cached(url, lookup_token, false)
    if outcome == 'cancelled' or tmdb_lookup_cancelled(lookup_token) then
        return nil
    end

    local count
    if data and tonumber(data.season_number) == tonumber(season)
        and type(data.episodes) == 'table' and #data.episodes > 0 then
        count = #data.episodes
    end
    -- Keep only the count. Refresh daily for ongoing seasons; retry missing
    -- totals after an hour without discarding a successful episode lookup.
    remember_poster(key, {
        count = count,
        expires_at = time() + (count and 24 * 60 * 60 or 60 * 60),
    })
    return count
end

local function format_episode_title(ep, total, title)
    local label = format('%02d', ep)
    if total and total >= ep then
        label = label .. format(' of %d', total)
    end
    return label .. ': ' .. title
end

local function tmdb_alternative_titles(result, lookup_token)
    if not result or not result.id then
        return nil
    end
    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end

    local type_name = result.media_type
    if type_name ~= 'tv' and type_name ~= 'movie' then
        return nil
    end

    local key = type_name .. ':' .. tostring(result.id) .. ':' .. TMDB_LANG
    local cached = tmdb_alias_cache[key]
    if cached then
        if mp.get_time() < cached.expires then
            return cached.titles, 'ok'
        end
        tmdb_alias_cache[key] = nil
    end

    local url = format(
        'https://api.themoviedb.org/3/%s/%s/alternative_titles?api_key=%s&language=%s',
        type_name, tostring(result.id), TMDB_KEY, url_encode(TMDB_LANG)
    )
    local data, outcome = tmdb_get_json_cached(url, lookup_token, false)
    if not data or outcome ~= 'ok' then
        return nil, outcome
    end

    local titles = {}
    -- TMDb uses `titles` for movie alternative titles and `results` for
    -- TV alternative titles. Accept both response shapes.
    local list = data.titles or data.results
    if type(list) == 'table' then
        for i = 1, #list do
            local item = list[i]
            if type(item) == 'table' then
                local value = item.title or item.name
                if type(value) == 'string' and #value > 0 then
                    titles[#titles + 1] = value
                end
            end
        end
    end

    tmdb_alias_cache[key] = {
        titles = titles,
        expires = mp.get_time() + TMDB_ALIAS_CACHE_TTL,
    }
    trim_memory_cache(tmdb_alias_cache, TMDB_ALIAS_CACHE_MAX)
    return titles, 'ok'
end

local function tmdb_result_year(result)
    local date = result and (result.first_air_date or result.release_date or '')
    local y = match(date, '^(%d%d%d%d)')
    return y
end

local function candidate_is_confident(best, best_score, second_score)
    if not best or not best.id or not best.poster_path then
        return false
    end
    if not best_score or best_score < TMDB_MIN_MATCH_SCORE then
        return false
    end
    if second_score and (best_score - second_score) < TMDB_MIN_MATCH_MARGIN then
        return false
    end
    return true
end

local function candidate_is_safe_early_stop(best, best_score, second_score, year)
    if not candidate_is_confident(best, best_score, second_score) then
        return false
    end

    -- During staged primary-title searches, do not stop early on an older
    -- exact-title franchise entry when the filename/directory supplied a
    -- different exact year. Alias scoring may reveal the intended reboot.
    if year then
        local result_year = tmdb_result_year(best)
        if result_year ~= year then
            return false
        end
    end
    return true
end

local function tmdb_search_tv_candidates(query_title, year, lookup_token)
    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end

    local url = format(
        'https://api.themoviedb.org/3/search/tv?api_key=%s&language=%s&query=%s&page=1&include_adult=false',
        TMDB_KEY, url_encode(TMDB_LANG), url_encode(query_title)
    )
    if year then
        url = url .. '&first_air_date_year=' .. url_encode(year)
    end

    log_verbose(format('TMDb TV query="%s" year=%s',
        query_title, tostring(year)))

    local data, outcome = tmdb_get_json_cached(url, lookup_token)
    if not data or outcome ~= 'ok' or type(data.results) ~= 'table' then
        return nil, outcome
    end

    local candidates = {}
    for i = 1, #data.results do
        local result = data.results[i]
        if type(result) == 'table' then
            result.media_type = 'tv'
            candidates[#candidates + 1] = result
        end
    end
    return candidates, 'ok'
end

local function tmdb_candidate_name(result)
    return result and (result.name or result.title or result.original_name
        or result.original_title) or nil
end

local function tmdb_add_candidates(pool, seen, results, media_type, source_name)
    if type(results) ~= 'table' then return end
    for i = 1, #results do
        local result = results[i]
        if type(result) == 'table' then
            local result_type = result.media_type or media_type
            if result_type == media_type and result.id then
                result.media_type = result_type
                local key = result_type .. ':' .. tostring(result.id)
                if not seen[key] then
                    seen[key] = true
                    result._mpv_candidate_source = source_name
                    pool[#pool + 1] = result
                end
            end
        end
    end
end

local function tmdb_search_multi_candidates(query_title, lookup_token)
    if tmdb_lookup_cancelled(lookup_token) then
        return nil, 'cancelled'
    end

    local url = format(
        'https://api.themoviedb.org/3/search/multi?api_key=%s&language=%s&query=%s&page=1&include_adult=false',
        TMDB_KEY, url_encode(TMDB_LANG), url_encode(query_title)
    )

    log_verbose(format('TMDb candidate query multi="%s"', query_title))

    local data, outcome = tmdb_get_json_cached(url, lookup_token)
    if not data or outcome ~= 'ok' or type(data.results) ~= 'table' then
        return nil, outcome
    end
    return data.results, 'ok'
end

local function tmdb_best_alias_match(query_title, result, lookup_token)
    local aliases, outcome = tmdb_alternative_titles(result, lookup_token)
    if outcome == 'cancelled' then
        return 0, nil, true
    end
    if not aliases or #aliases == 0 then
        return 0, nil, false
    end

    local best_similarity = 0
    local best_title = nil
    for i = 1, #aliases do
        local similarity = title_similarity(query_title, aliases[i])
        if similarity > best_similarity then
            best_similarity = similarity
            best_title = aliases[i]
        end
    end
    return best_similarity, best_title, false
end

local function tmdb_score_candidate_for_queries(
    result, query_titles, year, is_tv, use_aliases, lookup_token
)
    local best_score = -math.huge
    local best_query = nil
    local best_alias = nil
    local best_alias_similarity = 0

    for i = 1, #query_titles do
        if tmdb_lookup_cancelled(lookup_token) then
            return nil, nil, nil, nil, true
        end

        local query_title = query_titles[i]
        local score = score_multi_result(result, query_title, year, is_tv)
        local alias_similarity = 0
        local alias_title = nil

        if use_aliases then
            local cancelled
            alias_similarity, alias_title, cancelled =
                tmdb_best_alias_match(query_title, result, lookup_token)
            if cancelled then
                return nil, nil, nil, nil, true
            end

            if alias_similarity > 0 then
                local alias_score = alias_similarity * 50
                if alias_similarity >= 0.98 then
                    alias_score = alias_score + 9
                elseif alias_similarity >= 0.85 then
                    alias_score = alias_score + 5
                elseif alias_similarity >= 0.70 then
                    alias_score = alias_score + 2
                end

                local result_year = tmdb_result_year(result)
                if year and result_year == year then
                    alias_score = alias_score + 20
                elseif year and result_year then
                    local qy, cy = tonumber(year), tonumber(result_year)
                    local delta = qy and cy and math.abs(qy - cy) or 99
                    if delta <= 1 then
                        alias_score = alias_score + 3
                    elseif delta <= 3 then
                        alias_score = alias_score - 3
                    else
                        alias_score = alias_score - 8
                    end
                end

                if result.poster_path then
                    alias_score = alias_score + 8
                end
                if is_tv and result.media_type == 'tv' then
                    alias_score = alias_score + 4
                elseif not is_tv and result.media_type == 'movie' then
                    alias_score = alias_score + 4
                end

                if alias_score > score then
                    score = alias_score
                end
            end
        end

        if score > best_score then
            best_score = score
            best_query = query_title
            best_alias = alias_title
            best_alias_similarity = alias_similarity
        end
    end

    return best_score, best_query, best_alias, best_alias_similarity, false
end

local function tmdb_candidate_cache_key(result)
    if not result or not result.id then return nil end
    return tostring(result.media_type or '') .. ':' .. tostring(result.id)
end

local function tmdb_choose_from_pool(
    pool, query_titles, year, is_tv, use_aliases, lookup_token, alias_filter
)
    local scored = {}

    for i = 1, #pool do
        if tmdb_lookup_cancelled(lookup_token) then
            return nil, nil, nil, nil, 'cancelled'
        end

        local result = pool[i]
        local use_result_aliases = use_aliases
        if use_result_aliases and alias_filter then
            local result_key = tmdb_candidate_cache_key(result)
            use_result_aliases = result_key and alias_filter[result_key] == true
        end

        local score, query_title, alias_title, alias_similarity, cancelled =
            tmdb_score_candidate_for_queries(
                result, query_titles, year, is_tv,
                use_result_aliases, lookup_token
            )
        if cancelled then
            return nil, nil, nil, nil, 'cancelled'
        end

        scored[#scored + 1] = {
            result = result,
            score = score,
            query_title = query_title,
            alias_title = alias_title,
            alias_similarity = alias_similarity,
            alias_checked = use_result_aliases,
        }
    end

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)

    if use_aliases then
        for i = 1, #scored do
            local item = scored[i]
            if item.alias_checked then
                local result = item.result
                log_verbose(format(
                    'TMDb candidate id=%s type=%s title="%s" year=%s source=%s '
                    .. 'query="%s" alias="%s" alias_sim=%.3f score=%.1f poster=%s',
                    tostring(result.id),
                    tostring(result.media_type),
                    tostring(tmdb_candidate_name(result) or ''),
                    tostring(tmdb_result_year(result) or ''),
                    tostring(result._mpv_candidate_source or ''),
                    tostring(item.query_title or ''),
                    tostring(item.alias_title or ''),
                    tonumber(item.alias_similarity) or 0,
                    tonumber(item.score) or -1,
                    tostring(result.poster_path ~= nil)
                ))
            end
        end
    end

    local best = scored[1]
    local second = scored[2]
    return best and best.result or nil,
           best and best.score or nil,
           second and second.score or nil,
           best,
           'ok'
end

local function tmdb_resolve_aliases_tiered(
    pool, query_titles, year, is_tv, lookup_token
)
    local ranked = {}

    -- Rank all candidates cheaply by primary/original title first. This
    -- ranking determines which broader candidates receive alias requests
    -- before the final all-candidate fallback.
    for i = 1, #pool do
        if tmdb_lookup_cancelled(lookup_token) then
            return nil, nil, nil, 'cancelled'
        end

        local result = pool[i]
        local score, _, _, _, cancelled =
            tmdb_score_candidate_for_queries(
                result, query_titles, year, is_tv, false, lookup_token
            )
        if cancelled then
            return nil, nil, nil, 'cancelled'
        end
        ranked[#ranked + 1] = { result = result, score = score }
    end

    table.sort(ranked, function(a, b)
        return a.score > b.score
    end)

    local checked = {}
    local checked_count = 0

    local function add_candidates(predicate, limit)
        local added = 0
        for i = 1, #ranked do
            local result = ranked[i].result
            local key = tmdb_candidate_cache_key(result)
            if key and not checked[key] and predicate(result) then
                checked[key] = true
                checked_count = checked_count + 1
                added = added + 1
                if limit and added >= limit then
                    break
                end
            end
        end
        return added
    end

    local function score_checked(tier_name, require_safe_year)
        if checked_count == 0 then
            return nil, nil, nil, false, 'ok'
        end

        log_verbose(format(
            'TMDb alias %s: evaluating %d/%d candidates',
            tier_name, checked_count, #pool
        ))

        local best, best_score, second_score, _, outcome =
            tmdb_choose_from_pool(
                pool, query_titles, year, is_tv, true,
                lookup_token, checked
            )
        if outcome == 'cancelled' then
            return nil, nil, nil, false, outcome
        end

        local confident
        if require_safe_year then
            confident = candidate_is_safe_early_stop(
                best, best_score, second_score, year
            )
        else
            confident = candidate_is_confident(
                best, best_score, second_score
            )
        end

        return best, best_score, second_score, confident, 'ok'
    end

    local best, best_score, second_score, confident, outcome

    -- Tier 1: when a year is known, inspect all exact-year candidates first.
    -- This keeps reboot/current-series cases such as Koukaku reliable while
    -- avoiding alias calls for unrelated franchise entries.
    if year then
        local added = add_candidates(function(result)
            return tmdb_result_year(result) == year
        end)
        if added > 0 then
            best, best_score, second_score, confident, outcome =
                score_checked('tier 1 (exact year)', true)
            if outcome == 'cancelled' or confident then
                return best, best_score, second_score, outcome
            end
        end
    else
        -- Without year context, begin with only the five strongest primary
        -- candidates before expanding further.
        add_candidates(function() return true end, 5)
        best, best_score, second_score, confident, outcome =
            score_checked('tier 1 (top primary)', false)
        if outcome == 'cancelled' or confident then
            return best, best_score, second_score, outcome
        end
    end

    -- Tier 2: broaden to the next five strongest primary-title candidates.
    local added = add_candidates(function() return true end, 5)
    if added > 0 then
        best, best_score, second_score, confident, outcome =
            score_checked('tier 2 (broader top candidates)', year ~= nil)
        if outcome == 'cancelled' or confident then
            return best, best_score, second_score, outcome
        end
    end

    -- Tier 3: preserve v5-6-1/v5-7 correctness by falling back to the full
    -- deduplicated pool when the cheaper tiers are still weak/ambiguous.
    add_candidates(function() return true end)
    best, best_score, second_score, confident, outcome =
        score_checked('tier 3 (full pool)', false)

    return best, best_score, second_score, outcome
end

local function tmdb_lookup(
    title, year, is_tv, season, ep, directory_title, lookup_token
)
    if TMDB_KEY == '' or not title or title == '' then
        return nil
    end
    if tmdb_lookup_cancelled(lookup_token) then
        log_verbose('TMDb stale lookup cancelled before start')
        return nil
    end

    -- Cache hits remain available while HTTP requests are backing off.
    load_poster_cache()

    local cache_title = gsub(title:lower(), '%s+', ' ')
    cache_title = gsub(cache_title, '^%s+', '')
    cache_title = gsub(cache_title, '%s+$', '')

    local preferred_type = is_tv and 'tv' or 'movie'
    local key = 'show:' .. preferred_type .. '|' .. cache_title
        .. '|' .. (year or '') .. '|' .. TMDB_LANG
    local cached = poster_cache[key]

    -- Safely migrate positive pre-v5-7 cache entries only when their stored
    -- media type agrees with this lookup. Old negatives are deliberately not
    -- reused because they did not distinguish TV from movie.
    if cached == nil then
        local legacy_key = 'show:' .. cache_title
            .. '|' .. (year or '') .. '|' .. TMDB_LANG
        local legacy_cached = poster_cache[legacy_key]
        local legacy_hit = unpack_cache_entry(legacy_cached)
        if legacy_hit and legacy_hit.type == preferred_type then
            cached = legacy_cached
            remember_poster(key, legacy_cached)
            log_verbose('migrated legacy show cache entry to media-typed key')
        end
    end

    if cached == false then
        log_verbose('poster cache hit (legacy no poster)')
        return nil
    end
    if type(cached) == 'table' and cached.negative then
        if cached.cache_version ~= 2 then
            poster_cache[key] = nil
            poster_cache_dirty = true
            schedule_poster_cache_save()
            cached = nil
        elseif not persistent_entry_expired(cached) then
            log_verbose('poster cache hit (no result)')
            return nil
        end
        poster_cache[key] = nil
        poster_cache_dirty = true
        schedule_poster_cache_save()
        cached = nil
    end

    local hit = unpack_cache_entry(cached)

    if not hit then
        local query_titles = { title }
        if directory_title and directory_title ~= '' then
            local same = normalize_match_title(directory_title)
                == normalize_match_title(title)
            if not same then
                query_titles[#query_titles + 1] = directory_title
            end
        end

        local pool = {}
        local seen = {}
        local any_request_ok = false
        local best, best_score, second_score
        local confident = false

        local function cancelled()
            if tmdb_lookup_cancelled(lookup_token) then
                log_verbose('TMDb stale lookup cancelled')
                return true
            end
            return false
        end

        local function score_primary(allow_early_stop)
            if #pool == 0 or cancelled() then return false end
            local outcome
            best, best_score, second_score, _, outcome =
                tmdb_choose_from_pool(
                    pool, query_titles, year, is_tv, false, lookup_token
                )
            if outcome == 'cancelled' then return false end
            if allow_early_stop then
                confident = candidate_is_safe_early_stop(
                    best, best_score, second_score, year
                )
            else
                confident = candidate_is_confident(
                    best, best_score, second_score
                )
            end
            return confident
        end

        local function add_tv_query(query_title, search_year, source_name)
            if cancelled() then return 'cancelled' end
            local results, outcome =
                tmdb_search_tv_candidates(query_title, search_year, lookup_token)
            if outcome == 'cancelled' then return outcome end
            if outcome == 'ok' then
                any_request_ok = true
                tmdb_add_candidates(pool, seen, results, 'tv', source_name)
            end
            return outcome
        end

        if is_tv then
            -- Stage 1: one dedicated TV search using the strongest context.
            -- Straightforward shows such as Dragon Ball DAIMA can stop here.
            local outcome = add_tv_query(
                title, year, year and 'filename-tv-year' or 'filename-tv'
            )
            if outcome == 'cancelled' then return nil end
            score_primary(true)

            -- Stage 2: only search a distinct directory title if the first
            -- search was not already decisive.
            if not confident and #query_titles > 1 then
                outcome = add_tv_query(
                    query_titles[2], year,
                    year and 'directory-tv-year' or 'directory-tv'
                )
                if outcome == 'cancelled' then return nil end
                score_primary(true)
            end

            -- Stage 3: if the year-filtered searches were not decisive,
            -- broaden to unfiltered TV search results. This remains cheaper
            -- than doing every search eagerly on every new show.
            if not confident and year then
                outcome = add_tv_query(title, nil, 'filename-tv')
                if outcome == 'cancelled' then return nil end
                if #query_titles > 1 then
                    outcome = add_tv_query(query_titles[2], nil, 'directory-tv')
                    if outcome == 'cancelled' then return nil end
                end
                score_primary(true)
            end

            -- Stage 4: retain /search/multi as a last inexpensive candidate
            -- expansion before the more expensive alternate-title fan-out.
            if not confident then
                if cancelled() then return nil end
                local results, multi_outcome =
                    tmdb_search_multi_candidates(title, lookup_token)
                if multi_outcome == 'cancelled' then return nil end
                if multi_outcome == 'ok' then
                    any_request_ok = true
                    tmdb_add_candidates(
                        pool, seen, results, preferred_type, 'filename-multi'
                    )
                    score_primary(true)
                end
            end
        else
            -- Movies continue to use one multi-search first.
            local results, outcome =
                tmdb_search_multi_candidates(title, lookup_token)
            if outcome == 'cancelled' then return nil end
            if outcome == 'ok' then
                any_request_ok = true
                tmdb_add_candidates(
                    pool, seen, results, preferred_type, 'filename-multi'
                )
                score_primary(true)
            end
        end

        if cancelled() then return nil end
        if not any_request_ok then
            return nil
        end

        if #pool == 0 then
            if tmdb_failed_generation == lookup_token then return nil end
            remember_poster(key, {
                negative = true, cache_version = 2,
                expires_at = time() + TMDB_NEGATIVE_CACHE_TTL
            })
            log_verbose('TMDb no candidates after staged search')
            return nil
        end

        -- Final stage: only weak/ambiguous searches pay the alternate-title
        -- cost. Alias requests are tiered: exact-year candidates first, then
        -- the strongest broader candidates, with a full-pool fallback that
        -- preserves the successful v5-6-1/v5-7 matching behavior.
        if not confident then
            local outcome
            best, best_score, second_score, outcome =
                tmdb_resolve_aliases_tiered(
                    pool, query_titles, year, is_tv, lookup_token
                )
            if outcome == 'cancelled' or cancelled() then
                return nil
            end
            confident = candidate_is_confident(
                best, best_score, second_score
            )
        end

        if not confident then
            if tmdb_failed_generation == lookup_token then
                log_verbose('TMDb lookup incomplete; not caching a miss')
                return nil
            end
            remember_poster(key, {
                negative = true, cache_version = 2,
                expires_at = time() + TMDB_NEGATIVE_CACHE_TTL
            })
            log_verbose(format(
                'TMDb match rejected after staged/alias scoring '
                .. '(score=%.1f, second=%.1f, minimum=%d, margin=%d)',
                best_score or -1, second_score or -1,
                TMDB_MIN_MATCH_SCORE, TMDB_MIN_MATCH_MARGIN
            ))
            return nil
        end

        if cancelled() then return nil end

        log_info(format(
            'TMDb selected id=%s type=%s title="%s" year=%s score=%.1f',
            tostring(best.id),
            tostring(best.media_type),
            tostring(tmdb_candidate_name(best) or ''),
            tostring(tmdb_result_year(best) or ''),
            tonumber(best_score) or -1
        ))

        hit = {
            poster  = 'https://image.tmdb.org/t/p/w500' .. best.poster_path,
            title   = tmdb_official_title(best),
            url     = tmdb_page_url(best),
            type    = best.media_type,
            id      = best.id,
            episode = nil,
        }

        remember_poster(key, hit)
        log_info('poster -> ' .. hit.poster)
        if hit.title then
            log_info('title  -> ' .. hit.title)
        end
    else
        log_verbose(format(
            'poster cache hit -> %s (TMDb id=%s)',
            tostring(hit.poster), tostring(hit.id)
        ))
    end

    if tmdb_lookup_cancelled(lookup_token) then
        return nil
    end

    if TMDB_EPISODE_LOOKUP and hit.type == 'tv' and hit.id and season and ep then
        local episode_key = tmdb_episode_persistent_key(hit.id, season, ep)
        local episode_cached = poster_cache[episode_key]

        if type(episode_cached) == 'table' and episode_cached.negative then
            if not persistent_entry_expired(episode_cached) then
                log_verbose('episode poster cache hit (no result)')
                return hit
            end
            poster_cache[episode_key] = nil
            poster_cache_dirty = true
            schedule_poster_cache_save()
            episode_cached = nil
        end

        local episode_hit = unpack_cache_entry(episode_cached)
        if episode_hit then
            hit = episode_hit
            log_verbose('episode poster cache hit -> ' .. hit.poster)
        else
            local epdata, ep_outcome =
                tmdb_episode_for_requested_season(
                    hit.id, season, ep, lookup_token
                )

            if ep_outcome == 'cancelled'
                or tmdb_lookup_cancelled(lookup_token) then
                return nil
            end

            local ep_season = tonumber(epdata and epdata.season_number)
            local ep_number = tonumber(epdata and epdata.episode_number)
            local episode_matches = epdata
                and ep_season == tonumber(season)
                and ep_number == tonumber(ep)

            if episode_matches then
                local new_episode_hit = {
                    poster = hit.poster,
                    title = hit.title,
                    url = hit.url,
                    type = hit.type,
                    id = hit.id,
                    episode = nil,
                }

                if epdata.still_path and #epdata.still_path > 0 then
                    new_episode_hit.poster =
                        'https://image.tmdb.org/t/p/w500' .. epdata.still_path
                end
                if epdata.name and #epdata.name > 0 then
                    new_episode_hit.episode = epdata.name
                end
                if epdata.id then
                    new_episode_hit.url =
                        hit.url .. '/season/' .. season .. '/episode/' .. ep
                end

                hit = new_episode_hit
                remember_poster(episode_key, hit)
                if hit.episode then
                    log_info('episode -> ' .. hit.episode)
                end
            elseif epdata then
                log_warn(format(
                    'TMDb episode response mismatch: requested S%02dE%02d, got S%02dE%02d',
                    season, ep, ep_season or -1, ep_number or -1))
            elseif ep_outcome == 'not_found' then
                -- A real 404 means TMDb does not currently have this exact
                -- season/episode. Cache that briefly and do not try another
                -- season or a continuous-numbering fallback.
                remember_poster(episode_key, {
                    negative = true,
                    cache_version = 2,
                    expires_at = time() + TMDB_EPISODE_NEGATIVE_CACHE_TTL,
                })
            end
        end
    end

    if hit.episode and hit.episode ~= '' and season and ep then
        local total = tmdb_season_episode_count(hit.id, season, lookup_token)
        if tmdb_lookup_cancelled(lookup_token) then return nil end
        -- Format a copy so both old and new cache entries retain the raw
        -- title, and repeated playback never adds the number twice.
        local display_hit = {}
        for field, value in pairs(hit) do display_hit[field] = value end
        display_hit.episode = format_episode_title(ep, total, hit.episode)
        return display_hit
    end

    return hit
end


local function clear_title_state()
    current_poster = nil
    current_clean_title = nil
    current_tmdb_title = nil
    current_tmdb_url = nil
    current_episode = nil
end

local function apply_tmdb_hit(hit)
    if not hit then
        current_poster = nil
        current_tmdb_title = nil
        current_tmdb_url = nil
        current_episode = nil
        return
    end
    current_poster = hit.poster
    current_tmdb_title = hit.title
    current_tmdb_url = hit.url
    current_episode = hit.episode
end

local function lookup_poster()
    -- Invalidate and abort older TMDb work immediately. mpv's asynchronous
    -- subprocess command supports aborting curl, so stale files no longer
    -- keep an unnecessary network request alive in the background.
    tmdb_abort_inflight_requests()
    tmdb_lookup_generation = tmdb_lookup_generation + 1
    local gen = tmdb_lookup_generation

    clear_title_state()

    local path = get_property('path')
    if not path then return end

    local title, year, is_tv, season, ep = clean_filename(path)
    local directory_title = nil
    do
        local dir_title = directory_context(path)
        directory_title = dir_title
    end
    if title and title ~= '' then
        current_clean_title = title
    end

    if TMDB_KEY == '' then return end

    log_verbose(format(
        'cleaned title="%s" year=%s tv=%s S%sE%s',
        tostring(title), tostring(year), tostring(is_tv),
        tostring(season), tostring(ep)
    ))

    if not title or title == '' then return end

    run_async(function()
        local hit = tmdb_lookup(
            title, year, is_tv, season, ep, directory_title, gen
        )
        if gen ~= tmdb_lookup_generation then return end
        apply_tmdb_hit(hit)
        tick(false)
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
    ffi.cdef[[
        struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
        int socket(int, int, int);
        int connect(int, const void*, unsigned);
        int send(int, const void*, size_t, int);
        int recv(int, void*, size_t, int);
        int close(int);
        int fcntl(int, int, int);
        struct pollfd { int fd; short events; short revents; };
        int poll(struct pollfd*, unsigned long, int);
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
                local addr = sockaddr_un_t()
                addr.sun_family = 1
                ffi.copy(addr.sun_path, paths[i])
                if C.connect(fd, addr, ffi.sizeof(addr)) == 0 then
                    pcall(function()
                        local fl = C.fcntl(fd, F_GETFL, 0)
                        C.fcntl(fd, F_SETFL, fl + O_NONBLOCK)
                    end)
                    self.socket = fd
                    log_verbose('connected ' .. paths[i])
                    return true
                end
                C.close(fd)
            end
        end
        return false
    end

    local POLLIN = 0x001
    local POLLOUT = 0x004
    local POLLERR = 0x008
    local POLLHUP = 0x010

    local function wait_fd(fd, events, timeout_ms)
        local pfd = ffi.new('struct pollfd[1]')
        pfd[0].fd = fd
        pfd[0].events = events
        local r = C.poll(pfd, 1, timeout_ms)
        if r <= 0 then return false end
        return bit.band(pfd[0].revents, events + POLLERR + POLLHUP) ~= 0
    end

    local function wait_readable(fd, timeout_ms)
        local pfd = ffi.new('struct pollfd[1]')
        pfd[0].fd = fd
        pfd[0].events = POLLIN
        local r = C.poll(pfd, 1, timeout_ms)
        if r <= 0 then return false end
        return bit.band(pfd[0].revents, POLLIN + POLLERR + POLLHUP) ~= 0
    end

    function RPC:read_available()
        local pfd = ffi.new('struct pollfd[1]')
        pfd[0].fd, pfd[0].events = self.socket, POLLIN
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
    local send_buf = ffi.new('char[?]', SEND_SIZE)

    function RPC:send_raw(data)
        if not self.socket then return false end
        local total = #data
        local sent = 0
        local deadline = mp.get_time() + 1.5
        while sent < total do
            local chunk = math.min(SEND_SIZE, total - sent)
            ffi.copy(send_buf, data:sub(sent + 1, sent + chunk), chunk)
            local n = C.send(self.socket, send_buf, chunk, 0)
            if n > 0 then
                sent = sent + n
            else
                local remaining_ms = floor((deadline - mp.get_time()) * 1000)
                if remaining_ms <= 0 or not wait_fd(self.socket, POLLOUT, remaining_ms) then
                    return false
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

    local send_buf = ffi.new('char[?]', 65536)

    function RPC:send_raw(data)
        if not self.socket then return false end
        local total = #data
        local sent = 0
        while sent < total do
            local chunk = math.min(65536, total - sent)
            ffi.copy(send_buf, data:sub(sent + 1, sent + chunk), chunk)
            if C.WriteFile(self.socket, send_buf, chunk, written, nil) == 0
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
        transport_close(self)
    end
end

function RPC:connection_failed(reason)
    log_warn(reason)
    self:close()
    rpc_note_failure()
    if self.on_disconnect then self.on_disconnect() end
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
            if response.evt == 'ERROR' then
                local data = type(response.data) == 'table' and response.data or {}
                log_warn('Discord RPC error (nonce=' .. tostring(response.nonce)
                    .. '): ' .. tostring(data.message or data.code or 'unknown'))
            end
        end
    end
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

function RPC:set_activity(activity)
    if not self.socket and not self:handshake() then
        return false
    end

    local encoded = 'null'
    if activity ~= nil then
        encoded = format_json(activity)
        if not encoded then return false end
    end
    local body = '{"cmd":"SET_ACTIVITY","nonce":' .. format_json(next_nonce())
        .. ',"args":{"pid":' .. tostring(PID) .. ',"activity":' .. encoded .. '}}'

    if not self:send_raw(pack(1, body)) then
        self:connection_failed('Discord IPC send failed')
        return false
    end
    return true
end

function RPC:shutdown_fast()
    self:close()
end

----------------------------------------------------------------
-- Presence updates (event-driven)
----------------------------------------------------------------
local last = {
    activity_sig = nil,
}

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

-- With elapsed/remaining text removed, Discord animates the progress bar from
-- start/end timestamps by itself. Presence only needs to be sent on meaningful
-- playback or metadata events (load, pause/resume, seek, chapter, TMDb result).
local reconnect_timer = nil

local function stop_reconnect_watchdog()
    if reconnect_timer then
        reconnect_timer:kill()
        reconnect_timer = nil
    end
end

local function start_reconnect_watchdog()
    if reconnect_timer or not enabled then return end

    reconnect_timer = mp.add_periodic_timer(1, function()
        if not enabled then
            stop_reconnect_watchdog()
            return
        end
        if RPC.socket then
            stop_reconnect_watchdog()
            return
        end
        if rpc_backoff_active() then return end

        if RPC:handshake() then
            stop_reconnect_watchdog()
            -- Re-publish the current state after Discord comes back.
            tick(true)
        end
    end)
end

RPC.on_disconnect = start_reconnect_watchdog

local function playback_state_label(idle, pause)
    if idle then return 'Idle' end
    if pause then return 'Paused' end
    return 'Playing'
end

tick = function(force)
    if not enabled then return end

    local raw_title = get_property('media-title') or get_property('filename') or 'Unknown'
    local title = current_tmdb_title or tagged_title() or current_clean_title or raw_title
    title = truncate_utf8(title, 120)

    local pause = get_property_bool('pause') or get_property_bool('paused-for-cache')
    local idle  = get_property_bool('idle-active')
    local extra = current_episode or meaningful_chapter_title()
    local state = truncate_utf8(
        (extra and extra ~= '') and extra or playback_state_label(idle, pause), 120)

    local large_image = presence_image(current_poster)
    local large_text = truncate_utf8(current_poster and title or FALLBACK_TXT, 120)

    local small_image, small_text
    if idle then
        small_image, small_text = SMALL_IDLE, 'Idle'
    elseif pause then
        small_image, small_text = SMALL_PAUSE, 'Paused'
    else
        small_image, small_text = SMALL_PLAY, 'Playing'
    end

    local activity_sig = table.concat({
        title,
        state,
        tostring(pause),
        tostring(idle),
        tostring(current_poster or ''),
        tostring(current_tmdb_title or ''),
        tostring(current_tmdb_url or ''),
        tostring(large_image or ''),
        tostring(large_text or ''),
        tostring(small_image or ''),
        tostring(small_text or ''),
    }, '\31')

    -- A seek/resume passes force=true because timestamps need to be rebased
    -- even when the visible metadata is otherwise identical.
    if not force and activity_sig == last.activity_sig and RPC.socket then
        return
    end

    activity.type                = ACTIVITY_WATCHING
    activity.name                = title
    activity.status_display_type = 2
    activity.details             = title
    activity.details_url         = current_tmdb_url
    activity.state               = state
    activity.state_url           = current_tmdb_url
    activity.assets.large_image  = large_image
    activity.assets.large_text   = large_text
    activity.assets.large_url    = current_tmdb_url

    if small_image and small_image ~= '' then
        activity.assets.small_image = small_image
        activity.assets.small_text  = small_text
    else
        activity.assets.small_image = nil
        activity.assets.small_text  = nil
    end

    -- Discord owns the live progress display. We only rebase timestamps when
    -- an event makes that necessary; there is no periodic time-text refresh.
    local pos = get_property_number('time-pos') or 0
    local dur = get_property_number('duration') or 0
    if not idle and not pause and dur > 0 then
        local speed = get_property_number('speed') or 1
        if speed <= 0 then speed = 1 end
        pos = math.max(0, math.min(pos, dur))
        local now = time()
        timestamps.start  = floor(now - pos / speed)
        timestamps['end'] = floor(now + (dur - pos) / speed)
        activity.timestamps = timestamps
    else
        activity.timestamps = nil
    end

    if RPC:set_activity(activity) then
        last.activity_sig = activity_sig
        stop_reconnect_watchdog()
    else
        start_reconnect_watchdog()
    end
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local function reset_presence_state()
    last.activity_sig = nil
end

local function on_pause(_, paused)
    if paused == nil or not enabled then return end
    -- On resume this reads the current time-pos once and rebases Discord's
    -- timestamps, including any seek that happened while paused.
    tick(true)
end

mp.register_event('file-loaded', function()
    lookup_poster()
    reset_presence_state()
    tick(true)
end)

mp.register_event('end-file', function()
    tmdb_abort_inflight_requests()
    tmdb_lookup_generation = tmdb_lookup_generation + 1
    clear_title_state()
    reset_presence_state()

    if enabled and RPC.socket then
        if not RPC:set_activity(nil) then
            start_reconnect_watchdog()
        end
    elseif enabled then
        start_reconnect_watchdog()
    end
end)

-- Seek/playback restarts can arrive in bursts. One timestamp rebase after the
-- burst is enough now that elapsed/remaining text is no longer displayed.
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
            end)
        end
        return
    end

    last_restart_at = now
    tick(true)
end)

mp.observe_property('pause', 'bool', on_pause)
mp.observe_property('paused-for-cache', 'bool', on_pause)
mp.observe_property('speed', 'number', function(_, speed)
    if speed ~= nil and enabled then tick(true) end
end)
mp.observe_property('duration', 'number', function(_, duration)
    if duration ~= nil and enabled then tick(true) end
end)

mp.observe_property('chapter', 'number', function(_, idx)
    if idx == nil or not enabled then return end
    -- TMDb episode titles take precedence over chapter titles. If an episode
    -- title is already known, chapter changes do not alter Discord presence.
    if not current_episode then
        tick(false)
    end
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
    if idle == nil or not enabled then return end
    tick(true)
end)

mp.register_event('shutdown', function()
    stop_reconnect_watchdog()
    tmdb_abort_inflight_requests()
    if poster_cache_save_timer then
        poster_cache_save_timer:kill()
        poster_cache_save_timer = nil
    end
    save_poster_cache()
    RPC:shutdown_fast()
end)

mp.add_key_binding(KEY_TOGGLE, 'discord-mpv-rpc-toggle', function()
    enabled = not enabled
    if enabled then
        reset_presence_state()
        tick(true)
        if not RPC.socket then
            start_reconnect_watchdog()
        end
        mp.osd_message('Discord RPC: on')
    else
        stop_reconnect_watchdog()
        if RPC.socket then RPC:set_activity(nil) end
        RPC:close()
        mp.osd_message('Discord RPC: off')
    end
end)

if enabled then
    mp.add_timeout(1.5, function()
        if not enabled then return end
        load_poster_cache()
        if RPC:handshake() then
            reset_presence_state()
            tick(true)
        else
            log_warn('Discord unavailable; reconnect watchdog enabled')
            start_reconnect_watchdog()
        end
    end)
end
