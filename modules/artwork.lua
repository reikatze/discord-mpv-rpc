-- Poster fitting, wsrv availability checks, and raw-image fallback.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local load_poster_cache = modules.cache.load_poster_cache
local persistent_entry_expired = modules.cache.persistent_entry_expired
local remember_poster = modules.cache.remember_poster
local FALLBACK_IMG = modules.config.FALLBACK_IMG
local POSTER_FIT = modules.config.POSTER_FIT
local gsub = modules.helpers.gsub
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local time = modules.helpers.time
local trim_memory_cache = modules.helpers.trim_memory_cache
local curl_request = modules.http.curl_request
local run_async = modules.http.run_async
local url_encode = modules.http.url_encode

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

    local entry = shared.poster_cache[WSRV_CACHE_KEY]
    if type(entry) ~= 'table' or type(entry.ok) ~= 'boolean'
        or persistent_entry_expired(entry) then
        if entry ~= nil then
            shared.poster_cache[WSRV_CACHE_KEY] = nil
            shared.poster_cache_dirty = true
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
        shared.tick(false)
    end)
end

return {
    presence_image = presence_image,
    probe_wsrv = probe_wsrv,
}
end
