-- TMDb title similarity, candidate scoring, and tiered alias resolution.
-- Network access stays in tmdb.lua; this module owns matching policy only.
return function(modules, shared)
local format = modules.helpers.format
local log_verbose = modules.helpers.log_verbose
local match = modules.helpers.match
local normalize_match_title = modules.title_normalize.normalize_match

local TMDB_MIN_MATCH_SCORE = 55
local TMDB_MIN_MATCH_MARGIN = 8

local function title_tokens(s)
    local tokens = {}
    for token in s:gmatch('%S+') do
        tokens[#tokens + 1] = token
    end
    return tokens
end

local function prepare_title(value)
    local normalized = normalize_match_title(value)
    local tokens = title_tokens(normalized)
    local counts = {}
    for i = 1, #tokens do
        counts[tokens[i]] = (counts[tokens[i]] or 0) + 1
    end
    return {
        raw = value,
        normalized = normalized,
        tokens = tokens,
        counts = counts,
    }
end

local function prepared_title_similarity(a, b)
    if a.normalized == '' or b.normalized == '' then return 0 end
    if a.normalized == b.normalized then return 1 end

    local common = 0
    for token, count in pairs(a.counts) do
        local other = b.counts[token]
        if other then common = common + math.min(count, other) end
    end

    local ta, tb = a.tokens, b.tokens
    local union = #ta + #tb - common
    local jaccard = union > 0 and common / union or 0
    local dice = (#ta + #tb) > 0 and (2 * common) / (#ta + #tb) or 0
    local containment = common / math.min(#ta, #tb)

    local prefix = 0
    local limit = math.min(#ta, #tb)
    while prefix < limit and ta[prefix + 1] == tb[prefix + 1] do
        prefix = prefix + 1
    end
    local prefix_score = prefix / math.max(#ta, #tb)

    return math.max(jaccard, dice * 0.96, containment * 0.82, prefix_score * 0.90)
end

local function title_similarity(a, b)
    return prepared_title_similarity(prepare_title(a), prepare_title(b))
end

local function prepare_result_titles(result)
    local official = result and (result.title or result.name)
    local original = result and (result.original_title or result.original_name)
    return {
        official = prepare_title(official),
        original = original and original ~= official and prepare_title(original) or nil,
    }
end

local function best_title_similarity(query_title, result_titles)
    local best = prepared_title_similarity(query_title, result_titles.official)
    local original = result_titles.original
    if original then
        best = math.max(best, prepared_title_similarity(query_title, original))
    end
    return best
end

local function result_year(result)
    local date = result and (result.first_air_date or result.release_date or '')
    return match(date, '^(%d%d%d%d)')
end

local function candidate_name(result)
    return result and (result.name or result.title or result.original_name
        or result.original_title) or nil
end

local function score_multi_result(result, result_titles, query_title, year, prefer_tv)
    if not result or result.media_type == 'person' then return -1 end
    if result.media_type ~= 'movie' and result.media_type ~= 'tv' then return -1 end

    local similarity = best_title_similarity(query_title, result_titles)
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
    if result.poster_path then score = score + 8 end

    local candidate_year = result_year(result)
    if year and candidate_year == year then
        score = score + 20
    elseif year and candidate_year then
        local query_year, numeric_year = tonumber(year), tonumber(candidate_year)
        local delta = query_year and numeric_year
            and math.abs(query_year - numeric_year) or 99
        if delta <= 1 then
            score = score + 3
        elseif delta <= 3 then
            score = score - 3
        else
            score = score - 8
        end
    end

    if prefer_tv and result.media_type == 'tv' then
        score = score + 4
    elseif not prefer_tv and result.media_type == 'movie' then
        score = score + 4
    end
    return score
end

local function candidate_is_confident(best, best_score, second_score)
    if not best or not best.id or not best.poster_path then return false end
    if not best_score or best_score < TMDB_MIN_MATCH_SCORE then return false end
    if second_score and (best_score - second_score) < TMDB_MIN_MATCH_MARGIN then
        return false
    end
    return true
end

local function candidate_is_safe_early_stop(best, best_score, second_score, year)
    if not candidate_is_confident(best, best_score, second_score) then return false end
    return not year or result_year(best) == year
end

local function candidate_cache_key(result)
    if not result or not result.id then return nil end
    return tostring(result.media_type or '') .. ':' .. tostring(result.id)
end

local function new_resolver(callbacks)
    local alternative_titles = assert(callbacks.alternative_titles)
    local lookup_cancelled = assert(callbacks.lookup_cancelled)

    local function best_alias_match(query_title, aliases)
        local best_similarity, best_title = 0, nil
        for i = 1, #aliases do
            local similarity = prepared_title_similarity(query_title, aliases[i])
            if similarity > best_similarity then
                best_similarity, best_title = similarity, aliases[i].raw
            end
        end
        return best_similarity, best_title
    end

    local function prepare_query_titles(query_titles)
        local prepared = {}
        for i = 1, #query_titles do
            prepared[i] = prepare_title(query_titles[i])
        end
        return prepared
    end

    local function new_scoring_context(query_titles)
        return {
            queries = prepare_query_titles(query_titles),
            results = {},
            aliases = {},
        }
    end

    local function prepare_alias_titles(result, lookup_token, alias_cache)
        local cached = alias_cache[result]
        if cached then return cached, 'ok' end
        local aliases, outcome = alternative_titles(result, lookup_token)
        if outcome == 'cancelled' then return nil, outcome end
        local prepared = {}
        for i = 1, #(aliases or {}) do
            prepared[i] = prepare_title(aliases[i])
        end
        alias_cache[result] = prepared
        return prepared, outcome
    end

    local function score_candidate_for_queries(
        result, result_titles, query_titles, year, is_tv, use_aliases,
        lookup_token, alias_cache
    )
        local best_score = -math.huge
        local best_query, best_alias = nil, nil
        local best_alias_similarity = 0

        local aliases = {}
        if use_aliases then
            local outcome
            aliases, outcome = prepare_alias_titles(result, lookup_token, alias_cache)
            if outcome == 'cancelled' then return nil, nil, nil, nil, true end
        end

        for i = 1, #query_titles do
            if lookup_cancelled(lookup_token) then
                return nil, nil, nil, nil, true
            end
            local query_title = query_titles[i]
            local score = score_multi_result(result, result_titles, query_title, year, is_tv)
            local alias_similarity, alias_title = 0, nil

            if use_aliases then
                alias_similarity, alias_title = best_alias_match(query_title, aliases)

                if alias_similarity > 0 then
                    local alias_score = alias_similarity * 50
                    if alias_similarity >= 0.98 then
                        alias_score = alias_score + 9
                    elseif alias_similarity >= 0.85 then
                        alias_score = alias_score + 5
                    elseif alias_similarity >= 0.70 then
                        alias_score = alias_score + 2
                    end

                    local candidate_year = result_year(result)
                    if year and candidate_year == year then
                        alias_score = alias_score + 20
                    elseif year and candidate_year then
                        local query_year, numeric_year = tonumber(year), tonumber(candidate_year)
                        local delta = query_year and numeric_year
                            and math.abs(query_year - numeric_year) or 99
                        if delta <= 1 then
                            alias_score = alias_score + 3
                        elseif delta <= 3 then
                            alias_score = alias_score - 3
                        else
                            alias_score = alias_score - 8
                        end
                    end

                    if result.poster_path then alias_score = alias_score + 8 end
                    if is_tv and result.media_type == 'tv' then
                        alias_score = alias_score + 4
                    elseif not is_tv and result.media_type == 'movie' then
                        alias_score = alias_score + 4
                    end
                    if alias_score > score then score = alias_score end
                end
            end

            if score > best_score then
                best_score = score
                best_query = query_title.raw
                best_alias = alias_title
                best_alias_similarity = alias_similarity
            end
        end
        return best_score, best_query, best_alias, best_alias_similarity, false
    end

    local function choose_from_pool(
        pool, query_titles, year, is_tv, use_aliases, lookup_token, alias_filter,
        context
    )
        context = context or new_scoring_context(query_titles)
        local prepared_queries = context.queries
        local prepared_results = context.results
        local prepared_aliases = context.aliases
        local best, second
        for i = 1, #pool do
            if lookup_cancelled(lookup_token) then
                return nil, nil, nil, nil, 'cancelled'
            end
            local result = pool[i]
            local use_result_aliases = use_aliases
            if use_result_aliases and alias_filter then
                local key = candidate_cache_key(result)
                use_result_aliases = key and alias_filter[key] == true
            end
            local result_titles = prepared_results[result]
            if not result_titles then
                result_titles = prepare_result_titles(result)
                prepared_results[result] = result_titles
            end
            local score, query_title, alias_title, alias_similarity, cancelled =
                score_candidate_for_queries(
                    result, result_titles, prepared_queries, year, is_tv,
                    use_result_aliases, lookup_token, prepared_aliases)
            if cancelled then return nil, nil, nil, nil, 'cancelled' end
            local item = {
                result = result,
                score = score,
                query_title = query_title,
                alias_title = alias_title,
                alias_similarity = alias_similarity,
                alias_checked = use_result_aliases,
            }
            if item.alias_checked then
                log_verbose(format(
                    'TMDb candidate id=%s type=%s title="%s" year=%s source=%s '
                    .. 'query="%s" alias="%s" alias_sim=%.3f score=%.1f poster=%s',
                    tostring(result.id), tostring(result.media_type),
                    tostring(candidate_name(result) or ''),
                    tostring(result_year(result) or ''),
                    tostring(result._mpv_candidate_source or ''),
                    tostring(item.query_title or ''),
                    tostring(item.alias_title or ''),
                    tonumber(item.alias_similarity) or 0,
                    tonumber(item.score) or -1,
                    tostring(result.poster_path ~= nil)))
            end
            if not best or item.score > best.score then
                second, best = best, item
            elseif not second or item.score > second.score then
                second = item
            end
        end

        return best and best.result or nil,
               best and best.score or nil,
               second and second.score or nil,
               best,
               'ok'
    end

    local function resolve_aliases_tiered(
        pool, query_titles, year, is_tv, lookup_token, context
    )
        context = context or new_scoring_context(query_titles)
        local prepared_queries = context.queries
        local prepared_results = context.results
        local prepared_aliases = context.aliases
        local ranked = {}
        for i = 1, #pool do
            if lookup_cancelled(lookup_token) then
                return nil, nil, nil, 'cancelled'
            end
            local result = pool[i]
            local result_titles = prepared_results[result]
            if not result_titles then
                result_titles = prepare_result_titles(result)
                prepared_results[result] = result_titles
            end
            local score, _, _, _, cancelled = score_candidate_for_queries(
                result, result_titles, prepared_queries, year, is_tv, false,
                lookup_token, prepared_aliases)
            if cancelled then return nil, nil, nil, 'cancelled' end
            ranked[#ranked + 1] = {result = result, score = score}
        end
        table.sort(ranked, function(a, b) return a.score > b.score end)

        local checked, checked_count = {}, 0
        local function add_candidates(predicate, limit)
            local added = 0
            for i = 1, #ranked do
                local result = ranked[i].result
                local key = candidate_cache_key(result)
                if key and not checked[key] and predicate(result) then
                    checked[key] = true
                    checked_count = checked_count + 1
                    added = added + 1
                    if limit and added >= limit then break end
                end
            end
            return added
        end

        local function score_checked(tier_name, require_safe_year)
            if checked_count == 0 then return nil, nil, nil, false, 'ok' end
            log_verbose(format('TMDb alias %s: evaluating %d/%d candidates',
                tier_name, checked_count, #pool))
            local best, best_score, second_score, _, outcome = choose_from_pool(
                pool, query_titles, year, is_tv, true, lookup_token, checked,
                context)
            if outcome == 'cancelled' then
                return nil, nil, nil, false, outcome
            end
            local confident
            if require_safe_year then
                confident = candidate_is_safe_early_stop(
                    best, best_score, second_score, year)
            else
                confident = candidate_is_confident(
                    best, best_score, second_score)
            end
            return best, best_score, second_score, confident, 'ok'
        end

        local best, best_score, second_score, confident, outcome
        if year then
            local added = add_candidates(function(result)
                return result_year(result) == year
            end)
            if added > 0 then
                best, best_score, second_score, confident, outcome =
                    score_checked('tier 1 (exact year)', true)
                if outcome == 'cancelled' or confident then
                    return best, best_score, second_score, outcome
                end
            end
        else
            add_candidates(function() return true end, 5)
            best, best_score, second_score, confident, outcome =
                score_checked('tier 1 (top primary)', false)
            if outcome == 'cancelled' or confident then
                return best, best_score, second_score, outcome
            end
        end

        local added = add_candidates(function() return true end, 5)
        if added > 0 then
            best, best_score, second_score, confident, outcome =
                score_checked('tier 2 (broader top candidates)', year ~= nil)
            if outcome == 'cancelled' or confident then
                return best, best_score, second_score, outcome
            end
        end

        add_candidates(function() return true end)
        best, best_score, second_score, confident, outcome =
            score_checked('tier 3 (full pool)', false)
        return best, best_score, second_score, outcome
    end

    return {
        choose_from_pool = choose_from_pool,
        new_scoring_context = new_scoring_context,
        resolve_aliases_tiered = resolve_aliases_tiered,
    }
end

return {
    MIN_MATCH_SCORE = TMDB_MIN_MATCH_SCORE,
    MIN_MATCH_MARGIN = TMDB_MIN_MATCH_MARGIN,
    candidate_is_confident = candidate_is_confident,
    candidate_is_safe_early_stop = candidate_is_safe_early_stop,
    candidate_name = candidate_name,
    new_resolver = new_resolver,
    result_year = result_year,
    title_similarity = title_similarity,
}
end
