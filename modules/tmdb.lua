-- TMDb candidate matching, aliases, show/movie lookup, and episodes.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local TMDB_NEGATIVE_CACHE_TTL = modules.cache.TMDB_NEGATIVE_CACHE_TTL
local load_poster_cache = modules.cache.load_poster_cache
local persistent_entry_expired = modules.cache.persistent_entry_expired
local remember_poster = modules.cache.remember_poster
local schedule_poster_cache_save = modules.cache.schedule_poster_cache_save
local TMDB_EPISODE_LOOKUP = modules.config.TMDB_EPISODE_LOOKUP
local TMDB_KEY = modules.config.TMDB_KEY
local TMDB_LANG = modules.config.TMDB_LANG
local TMDB_POSITIVE_CACHE_TTL = modules.config.TMDB_POSITIVE_CACHE_TTL
local format = modules.helpers.format
local gsub = modules.helpers.gsub
local log_info = modules.helpers.log_info
local log_verbose = modules.helpers.log_verbose
local log_warn = modules.helpers.log_warn
local match = modules.helpers.match
local time = modules.helpers.time
local trim_memory_cache = modules.helpers.trim_memory_cache
local url_encode = modules.http.url_encode
local tmdb_get_json_cached = modules.tmdb_requests.tmdb_get_json_cached
local tmdb_lookup_cancelled = modules.tmdb_requests.tmdb_lookup_cancelled
local normalize_match_title = modules.title_normalize.normalize_match
local leading_bracket_alternative = modules.title_normalize.leading_bracket_alternative

-- Missing exact episodes are persisted briefly so a season TMDb has not added
-- yet is not retried on every playback. Successful episode metadata is stored
-- only as the transformed persistent episode entry used by Discord.
local TMDB_EPISODE_NEGATIVE_CACHE_TTL = 24 * 60 * 60

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
    local cached = shared.poster_cache[key]
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

    if TMDB_EPISODE_LOOKUP and hit.type == 'tv' and hit.id and season and ep then
        local episode_key = tmdb_episode_persistent_key(hit.id, season, ep)
        local episode_cached = shared.poster_cache[episode_key]

        if type(episode_cached) == 'table'
            and persistent_entry_expired(episode_cached) then
            shared.poster_cache[episode_key] = nil
            shared.poster_cache_dirty = true
            schedule_poster_cache_save()
            episode_cached = nil
        end

        if type(episode_cached) == 'table' and episode_cached.negative then
            if not persistent_entry_expired(episode_cached) then
                log_verbose('episode poster cache hit (no result)')
                return hit
            end
            shared.poster_cache[episode_key] = nil
            shared.poster_cache_dirty = true
            schedule_poster_cache_save()
            episode_cached = nil
        end

        local episode_hit = unpack_cache_entry(episode_cached)
        if episode_hit then
            if type(episode_cached) == 'table' and not episode_cached.expires_at then
                episode_cached.expires_at = time() + TMDB_POSITIVE_CACHE_TTL
                remember_poster(episode_key, episode_cached)
            end
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
                    expires_at = time() + TMDB_POSITIVE_CACHE_TTL,
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

return {
    tmdb_lookup = tmdb_lookup,
    _test = {
        format_episode_title = format_episode_title,
        title_similarity = title_similarity,
        build_query_titles = build_query_titles,
        show_cache_key = show_cache_key,
    },
}
end
