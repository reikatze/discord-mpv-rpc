-- TMDb episode retrieval, persistent episode caching, and display formatting.
return function(modules, shared)
local persistent_entry_expired = modules.cache.persistent_entry_expired
local remember_poster = modules.cache.remember_poster
local schedule_poster_cache_save = modules.cache.schedule_poster_cache_save
local TMDB_EPISODE_LOOKUP = modules.config.TMDB_EPISODE_LOOKUP
local TMDB_KEY = modules.config.TMDB_KEY
local TMDB_LANG = modules.config.TMDB_LANG
local TMDB_POSITIVE_CACHE_TTL = modules.config.TMDB_POSITIVE_CACHE_TTL
local format = modules.helpers.format
local log_info = modules.helpers.log_info
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local time = modules.helpers.time
local url_encode = modules.http.url_encode
local tmdb_get_json_cached = modules.tmdb_requests.tmdb_get_json_cached
local tmdb_lookup_cancelled = modules.tmdb_requests.tmdb_lookup_cancelled

local TMDB_EPISODE_NEGATIVE_CACHE_TTL = 24 * 60 * 60

local function unpack_cache_entry(cached)
    if type(cached) == 'string' and #cached > 0 then return {poster = cached} end
    if type(cached) == 'table' and cached.poster and #cached.poster > 0 then
        return cached
    end
    return nil
end

local function request_episode(show_id, season, episode, lookup_token)
    if not show_id or not season or not episode then return nil end
    if tmdb_lookup_cancelled(lookup_token) then return nil, 'cancelled' end
    local url = format(
        'https://api.themoviedb.org/3/tv/%s/season/%d/episode/%d?api_key=%s&language=%s',
        tostring(show_id), season, episode, TMDB_KEY, url_encode(TMDB_LANG))
    log_verbose(format('TMDb episode id=%s S%02dE%02d',
        tostring(show_id), season, episode))
    return tmdb_get_json_cached(url, lookup_token, false)
end

local function episode_for_requested_season(show_id, season, episode, lookup_token)
    local data, outcome = request_episode(show_id, season, episode, lookup_token)
    if not data then return nil, outcome end
    local requested_season, requested_episode = tonumber(season), tonumber(episode)
    local got_season, got_episode =
        tonumber(data.season_number), tonumber(data.episode_number)
    if got_season == requested_season and got_episode == requested_episode then
        return data, outcome
    end
    log_verbose(format(
        'TMDb episode identity mismatch: requested S%02dE%02d, got S%02dE%02d; rejecting',
        requested_season or 0, requested_episode or 0,
        got_season or 0, got_episode or 0))
    return nil, 'mismatch'
end

local function persistent_key(show_id, season, episode)
    return format('episode:%s:S%02dE%02d:%s',
        tostring(show_id), season, episode, TMDB_LANG)
end

local function season_episode_count(show_id, season, lookup_token)
    local key = format('season-count:%s:S%02d', tostring(show_id), season)
    local cached = shared.poster_cache[key]
    if type(cached) == 'table' and not persistent_entry_expired(cached) then
        return cached.count
    end
    local url = format(
        'https://api.themoviedb.org/3/tv/%s/season/%d?api_key=%s&language=%s',
        tostring(show_id), season, TMDB_KEY, url_encode(TMDB_LANG))
    local data, outcome = tmdb_get_json_cached(url, lookup_token, false)
    if outcome == 'cancelled' or tmdb_lookup_cancelled(lookup_token) then return nil end
    local count
    if data and tonumber(data.season_number) == tonumber(season)
        and type(data.episodes) == 'table' and #data.episodes > 0 then
        count = #data.episodes
    end
    remember_poster(key, {
        count = count,
        expires_at = time() + (count and 24 * 60 * 60 or 60 * 60),
    })
    return count
end

local function format_episode_title(episode, total, title)
    local label = format('%02d', episode)
    if total and total >= episode then label = label .. format(' of %d', total) end
    return label .. ': ' .. title
end

local function apply_episode(hit, season, episode, lookup_token)
    if not TMDB_EPISODE_LOOKUP or hit.type ~= 'tv' or not hit.id
        or not season or not episode then
        return hit
    end

    local key = persistent_key(hit.id, season, episode)
    local cached = shared.poster_cache[key]
    if type(cached) == 'table' and persistent_entry_expired(cached) then
        shared.poster_cache[key] = nil
        shared.poster_cache_dirty = true
        schedule_poster_cache_save()
        cached = nil
    end
    if type(cached) == 'table' and cached.negative then
        if not persistent_entry_expired(cached) then
            log_verbose('episode poster cache hit (no result)')
            return hit
        end
        shared.poster_cache[key] = nil
        shared.poster_cache_dirty = true
        schedule_poster_cache_save()
        cached = nil
    end

    local episode_hit = unpack_cache_entry(cached)
    if episode_hit then
        if type(cached) == 'table' and not cached.expires_at then
            cached.expires_at = time() + TMDB_POSITIVE_CACHE_TTL
            remember_poster(key, cached)
        end
        hit = episode_hit
        log_verbose('episode poster cache hit -> ' .. hit.poster)
    else
        local data, outcome = episode_for_requested_season(
            hit.id, season, episode, lookup_token)
        if outcome == 'cancelled' or tmdb_lookup_cancelled(lookup_token) then return nil end

        local got_season = tonumber(data and data.season_number)
        local got_episode = tonumber(data and data.episode_number)
        if data and got_season == tonumber(season)
            and got_episode == tonumber(episode) then
            local resolved = {
                poster = hit.poster,
                title = hit.title,
                url = hit.url,
                type = hit.type,
                id = hit.id,
                episode = nil,
                expires_at = time() + TMDB_POSITIVE_CACHE_TTL,
            }
            if data.still_path and #data.still_path > 0 then
                resolved.poster = 'https://image.tmdb.org/t/p/w500' .. data.still_path
            end
            if data.name and #data.name > 0 then resolved.episode = data.name end
            if data.id then
                resolved.url = hit.url .. '/season/' .. season .. '/episode/' .. episode
            end
            hit = resolved
            remember_poster(key, hit)
            if hit.episode then log_info('episode -> ' .. hit.episode) end
        elseif data then
            log_warn(format(
                'TMDb episode response mismatch: requested S%02dE%02d, got S%02dE%02d',
                season, episode, got_season or -1, got_episode or -1))
        elseif outcome == 'not_found' then
            remember_poster(key, {
                negative = true,
                cache_version = 2,
                expires_at = time() + TMDB_EPISODE_NEGATIVE_CACHE_TTL,
            })
        end
    end

    if hit.episode and hit.episode ~= '' then
        local total = season_episode_count(hit.id, season, lookup_token)
        if tmdb_lookup_cancelled(lookup_token) then return nil end
        local display_hit = {}
        for field, value in pairs(hit) do display_hit[field] = value end
        display_hit.episode = format_episode_title(episode, total, hit.episode)
        return display_hit
    end
    return hit
end

return {
    apply_episode = apply_episode,
    format_episode_title = format_episode_title,
    persistent_key = persistent_key,
}
end
