-- Persistent poster-cache loading, expiry, pruning, and deferred writes.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local IS_WINDOWS = modules.config.IS_WINDOWS
local PATH_SEP = modules.config.PATH_SEP
local PID = modules.config.PID
local SCRIPT_DIR = modules.helpers.SCRIPT_DIR
local format = modules.helpers.format
local format_json = modules.helpers.format_json
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local parse_json = modules.helpers.parse_json
local time = modules.helpers.time

local CACHE_PATH = SCRIPT_DIR .. PATH_SEP .. 'discord-mpv-rpc-posters.json'

shared.poster_cache = {}
local poster_cache_loaded = false
shared.poster_cache_dirty = false
shared.poster_cache_save_timer = nil

-- Negative poster-cache entries expire instead of permanently remembering
-- that TMDb had no usable result. Existing boolean false entries remain
-- compatible and are treated as legacy permanent negatives.
local TMDB_NEGATIVE_CACHE_TTL = 7 * 24 * 60 * 60
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
    for key, entry in pairs(shared.poster_cache) do
        if persistent_entry_expired(entry) then
            shared.poster_cache[key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        shared.poster_cache_dirty = true
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
        shared.poster_cache = data
        prune_poster_cache_expired()
        log_verbose('loaded poster cache from ' .. CACHE_PATH)
    end
end

local function save_poster_cache()
    prune_poster_cache_expired()
    if not shared.poster_cache_dirty then return end

    -- Write next to this script. Do not os.execute('mkdir'): that flashes
    -- a Command Prompt on Windows.
    local encoded = format_json(shared.poster_cache)
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

    shared.poster_cache_dirty = false
    log_verbose('poster cache saved to ' .. CACHE_PATH)
end

local MAX_CACHE_ENTRIES = 1000

local function trim_poster_cache()
    prune_poster_cache_expired()
    local count = 0
    for _ in pairs(shared.poster_cache) do
        count = count + 1
    end
    if count <= MAX_CACHE_ENTRIES then return end

    -- JSON object order is intentionally not relied upon; this is a simple
    -- bounded-cache fallback rather than a full LRU implementation.
    local remove = count - MAX_CACHE_ENTRIES
    for key in pairs(shared.poster_cache) do
        shared.poster_cache[key] = nil
        remove = remove - 1
        if remove <= 0 then break end
    end
end

local function schedule_poster_cache_save()
    if shared.poster_cache_save_timer then return end
    shared.poster_cache_save_timer = mp.add_timeout(2, function()
        shared.poster_cache_save_timer = nil
        save_poster_cache()
    end)
end

local function remember_poster(key, value)
    shared.poster_cache[key] = value
    trim_poster_cache()
    shared.poster_cache_dirty = true
    schedule_poster_cache_save()
end

return {
    TMDB_NEGATIVE_CACHE_TTL = TMDB_NEGATIVE_CACHE_TTL,
    load_poster_cache = load_poster_cache,
    persistent_entry_expired = persistent_entry_expired,
    remember_poster = remember_poster,
    save_poster_cache = save_poster_cache,
    schedule_poster_cache_save = schedule_poster_cache_save,
}
end
