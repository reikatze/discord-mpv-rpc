-- TMDb API search orchestration, aliases, and show/movie caching.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local TMDB_NEGATIVE_CACHE_TTL = modules.cache.TMDB_NEGATIVE_CACHE_TTL
local load_poster_cache = modules.cache.load_poster_cache
local persistent_entry_expired = modules.cache.persistent_entry_expired
local remember_poster = modules.cache.remember_poster
local schedule_poster_cache_save = modules.cache.schedule_poster_cache_save
local TMDB_KEY = modules.config.TMDB_KEY
local TMDB_LANG = modules.config.TMDB_LANG
local TMDB_POSITIVE_CACHE_TTL = modules.config.TMDB_POSITIVE_CACHE_TTL
local format = modules.helpers.format
local log_info = modules.helpers.log_info
local log_verbose = modules.helpers.log_verbose
local time = modules.helpers.time
local trim_memory_cache = modules.helpers.trim_memory_cache
local url_encode = modules.http.url_encode
local tmdb_get_json_cached = modules.tmdb_requests.tmdb_get_json_cached
local tmdb_lookup_cancelled = modules.tmdb_requests.tmdb_lookup_cancelled
local normalize_match_title = modules.title_normalize.normalize_match
local leading_bracket_alternative = modules.title_normalize.leading_bracket_alternative

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

local TMDB_ALIAS_CACHE_TTL = 30 * 24 * 60 * 60
local TMDB_ALIAS_CACHE_MAX = 256
local tmdb_alias_cache = {}

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

local matcher = modules.tmdb_match.new_resolver({
    alternative_titles = tmdb_alternative_titles,
    lookup_cancelled = tmdb_lookup_cancelled,
})
local candidate_is_confident = modules.tmdb_match.candidate_is_confident
local candidate_is_safe_early_stop = modules.tmdb_match.candidate_is_safe_early_stop
local tmdb_candidate_name = modules.tmdb_match.candidate_name
local tmdb_result_year = modules.tmdb_match.result_year
local title_similarity = modules.tmdb_match.title_similarity
local tmdb_choose_from_pool = matcher.choose_from_pool
local tmdb_resolve_aliases_tiered = matcher.resolve_aliases_tiered
local TMDB_MIN_MATCH_SCORE = modules.tmdb_match.MIN_MATCH_SCORE
local TMDB_MIN_MATCH_MARGIN = modules.tmdb_match.MIN_MATCH_MARGIN

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

local SHOW_CACHE_VERSION = 3

local function build_query_candidates(title, directory_title)
    local values, seen = {}, {}
    local function add(value, source)
        local normalized = normalize_match_title(value)
        if normalized == '' or seen[normalized] then return end
        seen[normalized] = true
        values[#values + 1] = {title = value, source = source}
    end
    add(title, 'filename')
    add(leading_bracket_alternative(title), 'filename-bracket')
    add(directory_title, 'directory')
    add(leading_bracket_alternative(directory_title), 'directory-bracket')
    return values
end

local function candidate_titles(query_candidates)
    local values = {}
    for i = 1, #query_candidates do
        values[i] = query_candidates[i].title
    end
    return values
end

local function build_query_titles(title, directory_title)
    return candidate_titles(build_query_candidates(title, directory_title))
end

local function collect_index_ids(query_titles, is_tv)
    if modules.tmdb_index.candidates_many then
        return modules.tmdb_index.candidates_many(query_titles,is_tv)
    end
    local values, seen = {}, {}
    for i = 1, #query_titles do
        local ids = modules.tmdb_index.candidates(query_titles[i], is_tv)
        for n = 1, #ids do
            local id = ids[n]
            if not seen[id] then
                seen[id] = true
                values[#values + 1] = id
            end
        end
    end
    table.sort(values)
    return values
end

local function show_cache_key(
    title, year, preferred_type, directory_title, index_ids
)
    local cache_title = normalize_match_title(title)
    local cache_directory = normalize_match_title(directory_title)
    if cache_directory == cache_title then cache_directory = '' end
    local key = table.concat({
        'show:v' .. SHOW_CACHE_VERSION,
        preferred_type,
        cache_title,
        year or '',
        TMDB_LANG,
        'dir:' .. cache_directory,
    }, '|')
    if #index_ids > 0 then
        key = key .. '|export:' .. table.concat(index_ids, ',')
    end
    return key, cache_directory
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

    local query_candidates = build_query_candidates(title, directory_title)
    local query_titles = candidate_titles(query_candidates)
    local index_ids = collect_index_ids(query_titles, is_tv)
    local preferred_type = is_tv and 'tv' or 'movie'
    local key, cache_directory = show_cache_key(
        title, year, preferred_type, directory_title, index_ids
    )
    local cached = shared.poster_cache[key]

    if type(cached) == 'table' and persistent_entry_expired(cached) then
        shared.poster_cache[key] = nil
        shared.poster_cache_dirty = true
        schedule_poster_cache_save()
        cached = nil
    end

    -- A prior positive entry is safe to migrate only when no distinct
    -- directory context contributed to this lookup. Negative entries are not
    -- migrated because the query candidates and Unicode matching changed.
    if cached == nil and cache_directory == '' then
        local old_title = normalize_match_title(title)
        local old_key = 'show:' .. preferred_type .. '|' .. old_title
            .. '|' .. (year or '') .. '|' .. TMDB_LANG
        if #index_ids > 0 then
            old_key = old_key .. '|export:' .. table.concat(index_ids, ',')
        end
        local old_cached = shared.poster_cache[old_key]
        local old_hit = unpack_cache_entry(old_cached)
        if old_hit and old_hit.type == preferred_type then
            cached = old_cached
            remember_poster(key, old_cached)
            log_verbose('migrated compatible show cache entry to v3 key')
        end
    end

    if cached == false then
        log_verbose('poster cache hit (legacy no poster)')
        return nil
    end
    if type(cached) == 'table' and cached.negative then
        if cached.cache_version ~= SHOW_CACHE_VERSION then
            shared.poster_cache[key] = nil
            shared.poster_cache_dirty = true
            schedule_poster_cache_save()
            cached = nil
        elseif not persistent_entry_expired(cached) then
            log_verbose('poster cache hit (no result)')
            return nil
        end
        shared.poster_cache[key] = nil
        shared.poster_cache_dirty = true
        schedule_poster_cache_save()
        cached = nil
    end

    local hit = unpack_cache_entry(cached)

    if not hit then
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

        local function add_multi_query(query_title, source_name)
            if cancelled() then return 'cancelled' end
            local results, outcome =
                tmdb_search_multi_candidates(query_title, lookup_token)
            if outcome == 'cancelled' then return outcome end
            if outcome == 'ok' then
                any_request_ok = true
                tmdb_add_candidates(
                    pool, seen, results, preferred_type, source_name .. '-multi'
                )
            end
            return outcome
        end

        local function run_tv_stage(search_year)
            for i = 1, #query_candidates do
                local candidate = query_candidates[i]
                local suffix = search_year and '-tv-year' or '-tv'
                local outcome = add_tv_query(
                    candidate.title, search_year, candidate.source .. suffix
                )
                if outcome == 'cancelled' then return outcome end
                if score_primary(true) then return 'confident' end
            end
            return 'ok'
        end

        local function run_multi_stage()
            for i = 1, #query_candidates do
                local candidate = query_candidates[i]
                local outcome = add_multi_query(
                    candidate.title, candidate.source
                )
                if outcome == 'cancelled' then return outcome end
                if score_primary(true) then return 'confident' end
            end
            return 'ok'
        end

        -- Verify a unique indexed title before taking the shortcut. The
        -- export has no reliable year/artwork/episode data, so details remain
        -- authoritative. Duplicate titles use the normal search instead.
        if #index_ids == 1 then
            local verified, complete = {}, true
            for _, id in ipairs(index_ids) do
                if cancelled() then return nil end
                local url = format(
                    'https://api.themoviedb.org/3/%s/%d?api_key=%s&language=%s',
                    preferred_type, id, TMDB_KEY, url_encode(TMDB_LANG))
                local data, outcome = tmdb_get_json_cached(url, lookup_token)
                if outcome == 'cancelled' then return nil end
                if outcome == 'ok' and type(data) == 'table'
                    and tonumber(data.id) == id
                    and type(is_tv and data.name or data.title) == 'string' then
                    if not data.adult and not data.video
                        and (not year or tmdb_result_year(data) == tostring(year)) then
                        data.media_type = preferred_type
                        verified[#verified + 1] = data
                    end
                elseif outcome ~= 'not_found' then
                    complete = false
                end
            end
            -- The local shortcut is intentionally limited to unique titles.
            -- Duplicate titles are cheaper to resolve with one year-filtered
            -- search than with several individual detail requests.
            if complete and #verified == 1 then
                local item = verified[1]
                local indexed_title_match = false
                for i = 1, #query_titles do
                    if modules.tmdb_index.matches(
                            query_titles[i], item.title or item.name)
                        or modules.tmdb_index.matches(
                            query_titles[i], item.original_title or item.original_name) then
                        indexed_title_match = true
                        break
                    end
                end
                if indexed_title_match then
                    tmdb_add_candidates(pool, seen, verified, preferred_type, 'local-export')
                    any_request_ok = true
                    score_primary(true)
                end
            end
        end

        if is_tv and not confident then
            -- Search every distinct title candidate in priority order. A
            -- confident result stops the stage immediately, so common shows
            -- still need only one request.
            local outcome = run_tv_stage(year)
            if outcome == 'cancelled' then return nil end

            -- If exact-year searches remain weak, retry the same ordered
            -- candidates without a year before broadening to /search/multi.
            if not confident and year then
                outcome = run_tv_stage(nil)
                if outcome == 'cancelled' then return nil end
            end
            if not confident then
                outcome = run_multi_stage()
                if outcome == 'cancelled' then return nil end
            end
        elseif not confident then
            local outcome = run_multi_stage()
            if outcome == 'cancelled' then return nil end
        end

        if cancelled() then return nil end
        if not any_request_ok then
            return nil
        end

        if #pool == 0 then
            if shared.tmdb_failed_generation == lookup_token then return nil end
            remember_poster(key, {
                negative = true, cache_version = SHOW_CACHE_VERSION,
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
            if shared.tmdb_failed_generation == lookup_token then
                log_verbose('TMDb lookup incomplete; not caching a miss')
                return nil
            end
            remember_poster(key, {
                negative = true, cache_version = SHOW_CACHE_VERSION,
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
            expires_at = time() + TMDB_POSITIVE_CACHE_TTL,
        }

        remember_poster(key, hit)
        log_info('poster -> ' .. hit.poster)
        if hit.title then
            log_info('title  -> ' .. hit.title)
        end
    else
        if type(cached) == 'table' and not cached.expires_at then
            cached.expires_at = time() + TMDB_POSITIVE_CACHE_TTL
            remember_poster(key, cached)
        end
        log_verbose(format(
            'poster cache hit -> %s (TMDb id=%s)',
            tostring(hit.poster), tostring(hit.id)
        ))
    end

    if tmdb_lookup_cancelled(lookup_token) then
        return nil
    end

    return modules.tmdb_episode.apply_episode(hit, season, ep, lookup_token)
end

return {
    tmdb_lookup = tmdb_lookup,
    _test = {
        format_episode_title = modules.tmdb_episode.format_episode_title,
        title_similarity = title_similarity,
        build_query_titles = build_query_titles,
        show_cache_key = show_cache_key,
    },
}
end
