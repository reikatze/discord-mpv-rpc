-- Rich Presence payloads, reconnects, and mpv event registration.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local presence_image = modules.artwork.presence_image
local load_poster_cache = modules.cache.load_poster_cache
local save_poster_cache = modules.cache.save_poster_cache
local ACTIVITY_WATCHING = modules.config.ACTIVITY_WATCHING
local FALLBACK_IMG = modules.config.FALLBACK_IMG
local FALLBACK_TXT = modules.config.FALLBACK_TXT
local KEY_TOGGLE = modules.config.KEY_TOGGLE
local SMALL_IDLE = modules.config.SMALL_IDLE
local SMALL_PAUSE = modules.config.SMALL_PAUSE
local SMALL_PLAY = modules.config.SMALL_PLAY
local meaningful_chapter_title = modules.filename.meaningful_chapter_title
local tagged_title = modules.filename.tagged_title
local floor = modules.helpers.floor
local get_property = modules.helpers.get_property
local get_property_bool = modules.helpers.get_property_bool
local get_property_number = modules.helpers.get_property_number
local log_warn = modules.helpers.log_warn
local time = modules.helpers.time
local truncate_utf8 = modules.helpers.truncate_utf8
local RPC = modules.ipc.RPC
local rpc_backoff_active = modules.ipc.rpc_backoff_active
local clear_title_state = modules.metadata.clear_title_state
local lookup_poster = modules.metadata.lookup_poster
local tmdb_abort_inflight_requests = modules.tmdb_requests.tmdb_abort_inflight_requests

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
    if reconnect_timer or not shared.enabled then return end

    reconnect_timer = mp.add_periodic_timer(1, function()
        if not shared.enabled then
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
            shared.tick(true)
        end
    end)
end

RPC.on_disconnect = start_reconnect_watchdog

local function playback_state_label(idle, paused, buffering)
    if idle then return 'Idle' end
    if buffering then return 'Buffering' end
    if paused then return 'Paused' end
    return 'Playing'
end

shared.tick = function(force)
    if not shared.enabled then return end

    local raw_title = get_property('media-title') or get_property('filename') or 'Unknown'
    local title = shared.current_tmdb_title or tagged_title() or shared.current_clean_title or raw_title
    title = truncate_utf8(title, 120)

    local paused = get_property_bool('pause')
    local buffering = get_property_bool('paused-for-cache')
    local pause = paused or buffering
    local idle  = get_property_bool('idle-active')
    local extra = shared.current_episode or meaningful_chapter_title()
    local state = truncate_utf8(
        (extra and extra ~= '') and extra
            or playback_state_label(idle, paused, buffering), 120)

    local large_image = presence_image(shared.current_poster)
    local large_text = truncate_utf8(shared.current_poster and title or FALLBACK_TXT, 120)

    local small_image, small_text
    if idle then
        small_image, small_text = SMALL_IDLE, 'Idle'
    elseif pause then
        small_image, small_text = SMALL_PAUSE, buffering and 'Buffering' or 'Paused'
    else
        small_image, small_text = SMALL_PLAY, 'Playing'
    end

    local activity_sig = table.concat({
        title,
        state,
        tostring(pause),
        tostring(buffering),
        tostring(idle),
        tostring(shared.current_poster or ''),
        tostring(shared.current_tmdb_title or ''),
        tostring(shared.current_tmdb_url or ''),
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
    activity.details_url         = shared.current_tmdb_url
    activity.state               = state
    activity.state_url           = shared.current_tmdb_url
    activity.assets.large_image  = large_image
    activity.assets.large_text   = large_text
    activity.assets.large_url    = shared.current_tmdb_url

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
    if paused == nil or not shared.enabled then return end
    -- On resume this reads the current time-pos once and rebases Discord's
    -- timestamps, including any seek that happened while paused.
    shared.tick(true)
end

mp.register_event('file-loaded', function()
    lookup_poster()
    reset_presence_state()
    shared.tick(true)
end)

mp.register_event('end-file', function()
    tmdb_abort_inflight_requests()
    shared.tmdb_lookup_generation = shared.tmdb_lookup_generation + 1
    clear_title_state()
    reset_presence_state()

    if shared.enabled and RPC.socket then
        if not RPC:set_activity(nil) then
            start_reconnect_watchdog()
        end
    elseif shared.enabled then
        start_reconnect_watchdog()
    end
end)

-- Seek/playback restarts can arrive in bursts. One timestamp rebase after the
-- burst is enough now that elapsed/remaining text is no longer displayed.
local RESTART_DEBOUNCE = 0.4
local last_restart_at  = 0
local restart_pending  = false

mp.register_event('playback-restart', function()
    if not shared.enabled then return end

    local now = mp.get_time()
    if now - last_restart_at < RESTART_DEBOUNCE then
        if not restart_pending then
            restart_pending = true
            mp.add_timeout(RESTART_DEBOUNCE, function()
                restart_pending = false
                last_restart_at = mp.get_time()
                shared.tick(true)
            end)
        end
        return
    end

    last_restart_at = now
    shared.tick(true)
end)

mp.observe_property('pause', 'bool', on_pause)
mp.observe_property('paused-for-cache', 'bool', on_pause)
mp.observe_property('speed', 'number', function(_, speed)
    if speed ~= nil and shared.enabled then shared.tick(true) end
end)
mp.observe_property('duration', 'number', function(_, duration)
    if duration ~= nil and shared.enabled then shared.tick(true) end
end)

mp.observe_property('chapter', 'number', function(_, idx)
    if idx == nil or not shared.enabled then return end
    -- TMDb episode titles take precedence over chapter titles. If an episode
    -- title is already known, chapter changes do not alter Discord presence.
    if not shared.current_episode then
        shared.tick(false)
    end
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
    if idle == nil or not shared.enabled then return end
    shared.tick(true)
end)

mp.register_event('shutdown', function()
    stop_reconnect_watchdog()
    tmdb_abort_inflight_requests()
    if shared.poster_cache_save_timer then
        shared.poster_cache_save_timer:kill()
        shared.poster_cache_save_timer = nil
    end
    save_poster_cache()
    RPC:shutdown_fast()
end)

mp.add_key_binding(KEY_TOGGLE, 'discord-mpv-rpc-toggle', function()
    shared.enabled = not shared.enabled
    if shared.enabled then
        reset_presence_state()
        shared.tick(true)
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

if shared.enabled then
    mp.add_timeout(1.5, function()
        if not shared.enabled then return end
        load_poster_cache()
        if RPC:handshake() then
            reset_presence_state()
            shared.tick(true)
        else
            log_warn('Discord unavailable; reconnect watchdog enabled')
            start_reconnect_watchdog()
        end
    end)
end

return {
}
end
