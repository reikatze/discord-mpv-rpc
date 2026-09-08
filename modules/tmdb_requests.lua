-- TMDb request caching, coalescing, pacing, cancellation, and backoff.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local format = modules.helpers.format
local log_error = modules.helpers.log_error
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local parse_json = modules.helpers.parse_json
local resume_co = modules.helpers.resume_co
local running_co = modules.helpers.running_co
local trim_memory_cache = modules.helpers.trim_memory_cache
local yield_co = modules.helpers.yield_co
local curl_get = modules.http.curl_get

-- Short-lived in-memory TMDb response cache for reusable search responses.
-- Specialized episode/alternative-title data is not duplicated here because
-- those paths already have their own persistent/specialized caches.
local tmdb_request_cache = {}
local tmdb_inflight = {} -- [url] = { waiters = { coroutine, ... } }
local TMDB_REQUEST_CACHE_TTL = 24 * 60 * 60
local TMDB_REQUEST_CACHE_MAX = 512
-- Proactive pacing limits bursts from difficult/ambiguous lookups. Cache hits
-- and coalesced in-flight requests do not consume a new request slot.
local TMDB_MIN_REQUEST_INTERVAL = 0.25
local tmdb_next_request_at = 0

-- Every new file invalidates the previous lookup. An in-flight HTTP request
-- may finish, but a stale coroutine is stopped before it can launch more
-- searches, alias requests, or episode requests.
shared.tmdb_lookup_generation = 0
-- Retain one failure marker for the active file, including alias-request failures.
shared.tmdb_failed_generation = nil

local function tmdb_lookup_cancelled(token)
    return token ~= nil and token ~= shared.tmdb_lookup_generation
end

local tmdb_backoff_until = 0
local tmdb_backoff_sec   = 30

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
        and lookup_token == shared.tmdb_lookup_generation then
        shared.tmdb_failed_generation = lookup_token
    end
    return data, outcome
end

return {
    tmdb_abort_inflight_requests = tmdb_abort_inflight_requests,
    tmdb_get_json_cached = tmdb_get_json_cached,
    tmdb_lookup_cancelled = tmdb_lookup_cancelled,
}
end
