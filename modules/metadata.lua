-- Active-file lookup orchestration and current display metadata.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local probe_wsrv = modules.artwork.probe_wsrv
local TMDB_KEY = modules.config.TMDB_KEY
local clean_filename = modules.filename.clean_filename
local directory_context = modules.filename.directory_context
local format = modules.helpers.format
local get_property = modules.helpers.get_property
local log_verbose = modules.helpers.log_verbose
local run_async = modules.http.run_async
local tmdb_lookup = modules.tmdb.tmdb_lookup
local tmdb_abort_inflight_requests = modules.tmdb_requests.tmdb_abort_inflight_requests

local function clear_title_state()
    shared.current_poster = nil
    shared.current_clean_title = nil
    shared.current_tmdb_title = nil
    shared.current_tmdb_url = nil
    shared.current_episode = nil
end

local function apply_tmdb_hit(hit)
    if not hit then
        shared.current_poster = nil
        shared.current_tmdb_title = nil
        shared.current_tmdb_url = nil
        shared.current_episode = nil
        return
    end
    shared.current_poster = hit.poster
    shared.current_tmdb_title = hit.title
    shared.current_tmdb_url = hit.url
    shared.current_episode = hit.episode
end

local function lookup_poster()
    -- Invalidate and abort older TMDb work immediately. mpv's asynchronous
    -- subprocess command supports aborting curl, so stale files no longer
    -- keep an unnecessary network request alive in the background.
    tmdb_abort_inflight_requests()
    shared.tmdb_lookup_generation = shared.tmdb_lookup_generation + 1
    local gen = shared.tmdb_lookup_generation

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
        shared.current_clean_title = title
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
        if gen ~= shared.tmdb_lookup_generation then return end
        apply_tmdb_hit(hit)
        shared.tick(false)
        if hit and hit.poster then
            probe_wsrv(hit.poster)
        end
    end)
end

return {
    clear_title_state = clear_title_state,
    lookup_poster = lookup_poster,
}
end
