local source = debug.getinfo(1, 'S').source
local tests_dir = source:match('^@(.+)[/\\][^/\\]+$') or 'tests'
local root = tests_dir == 'tests' and '.' or tests_dir:gsub('[/\\]tests$', '')

local passed = 0
local function equal(actual, expected, label)
    assert(actual == expected, string.format(
        '%s: expected %q, got %q', label, tostring(expected), tostring(actual)))
    passed = passed + 1
end

_G.mp = {
    get_time = function() return 100 end,
    add_timeout = function() return {kill = function() end} end,
    get_property = function() return nil end,
    get_property_number = function() return nil end,
    get_property_bool = function() return nil end,
    get_property_native = function() return nil end,
}

-- Empty cache_path must leave CACHE_PATH unset so cache.lua stores beside
-- main.lua. Explicit paths still go through mpv's expand-path command.
local saved_preload, saved_loaded = {}, {}
for _, name in ipairs({'mp.utils', 'mp.msg', 'mp.options'}) do
    saved_preload[name] = package.preload[name]
    saved_loaded[name] = package.loaded[name]
    package.loaded[name] = nil
end
local configured_cache_path = ''
local expand_path_calls = 0
package.preload['mp.utils'] = function()
    return {getpid = function() return 123 end}
end
package.preload['mp.msg'] = function() return {} end
package.preload['mp.options'] = function()
    return {read_options = function(options)
        options.cache_path = configured_cache_path
    end}
end
local saved_command_native = mp.command_native
mp.command_native = function(command)
    expand_path_calls = expand_path_calls + 1
    return '/expanded/' .. command[2]
end
local config_factory = assert(loadfile(root .. '/modules/config.lua'))()
local default_config = config_factory({}, {})
equal(default_config.CACHE_PATH, nil, 'default script-directory cache path')
equal(expand_path_calls, 0, 'default cache path needs no expansion')
configured_cache_path = '~~/custom-cache.json'
local custom_config = config_factory({}, {})
equal(custom_config.CACHE_PATH, '/expanded/~~/custom-cache.json',
    'custom cache path expansion')
equal(expand_path_calls, 1, 'custom cache path expansion count')
mp.command_native = saved_command_native
for _, name in ipairs({'mp.utils', 'mp.msg', 'mp.options'}) do
    package.preload[name] = saved_preload[name]
    package.loaded[name] = saved_loaded[name]
end

local parsing = assert(loadfile(root .. '/db/parsing_keywords.lua'))()
local title_normalize_factory =
    assert(loadfile(root .. '/modules/title_normalize.lua'))()
local title_normalize = title_normalize_factory()
local filename_factory = assert(loadfile(root .. '/modules/filename.lua'))()
local filename = filename_factory({
    helpers = {
        floor = math.floor,
        get_property = mp.get_property,
        get_property_number = mp.get_property_number,
        gsub = string.gsub,
        match = string.match,
        sub = string.sub,
    },
    database = {parsing = parsing},
    title_normalize = title_normalize,
}, {})

local title, year, is_tv, season, episode =
    filename.clean_filename('[Judas] Dragon Ball Daima - S01E04v2.mkv')
equal(title, 'Dragon Ball Daima', 'scene title cleanup')
equal(is_tv, true, 'TV detection')
equal(season, 1, 'season parsing')
equal(episode, 4, 'episode parsing')

title, year = filename.clean_filename(
    'Birdman (or the Unexpected Virtue of Ignorance) (2014) 1080p BluRay.mkv')
equal(title, 'Birdman (or the Unexpected Virtue of Ignorance)',
    'meaningful parentheses')
equal(year, '2014', 'movie year parsing')

title = filename.clean_filename('Movie.Name.(1080p).x265.mkv')
equal(title, 'Movie Name', 'parenthesized technical suffix')

title, year = filename.clean_filename('2001.A.Space.Odyssey.1968.mkv')
equal(title, '2001 A Space Odyssey', 'numeric movie title')
equal(year, '1968', 'last plausible release year')

title, year = filename.clean_filename('1917.mkv')
equal(title, '1917', 'year-shaped title')
equal(year, nil, 'year-shaped title has no inferred release year')

title, year = filename.clean_filename('1917.2019.mkv')
equal(title, '1917', 'numeric title before release year')
equal(year, '2019', 'numeric title release year')

title, year, is_tv = filename.clean_filename('1923.S01E01.mkv')
equal(title, '1923', 'numeric TV title')
equal(year, nil, 'numeric TV title has no inferred release year')
equal(is_tv, true, 'numeric TV title detection')

title, year = filename.clean_filename('Show.Name.2020.S01E01.mkv')
equal(title, 'Show Name', 'TV release year removal')
equal(year, '2020', 'TV release year detection')

title, year = filename.clean_filename('[REC].2007.mkv')
equal(title, '[REC]', 'legitimate bracketed movie title')
equal(year, '2007', 'bracketed movie year')

title = filename.clean_filename('[Oshi no Ko].S01E01.mkv')
equal(title, '[Oshi no Ko]', 'legitimate bracketed TV title')

title = filename.clean_filename(
    'Movie.Name.[DSNP WEBDL-1080p][EAC3 5.1][h264].mkv')
equal(title, 'Movie Name', 'known bracketed release tags')

title = filename.clean_filename('[MysteryGroup] Show.Name.2020.S01E01.mkv')
equal(title, '[MysteryGroup] Show Name', 'unknown bracket group preservation')

equal(title_normalize.normalize_match('攻殻機動隊'), '攻殻機動隊',
    'UTF-8 match normalization')
equal(title_normalize.normalize_match('Амели!'), 'Амели',
    'Cyrillic preservation')
equal(title_normalize.normalize_index('Tom & Jerry'), 'tom jerry',
    'bundled index normalization compatibility')

local tmdb_factory = assert(loadfile(root .. '/modules/tmdb.lua'))()
local noop = function() end
local tmdb = tmdb_factory({
    cache = {
        TMDB_NEGATIVE_CACHE_TTL = 1,
        load_poster_cache = noop,
        persistent_entry_expired = function() return false end,
        remember_poster = noop,
        schedule_poster_cache_save = noop,
    },
    config = {
        TMDB_EPISODE_LOOKUP = true,
        TMDB_KEY = '',
        TMDB_LANG = 'en-US',
        TMDB_POSITIVE_CACHE_TTL = 60,
    },
    helpers = {
        format = string.format,
        gsub = string.gsub,
        log_info = noop,
        log_verbose = noop,
        log_warn = noop,
        match = string.match,
        time = os.time,
        trim_memory_cache = noop,
    },
    http = {url_encode = function(value) return value end},
    tmdb_requests = {
        tmdb_get_json_cached = noop,
        tmdb_lookup_cancelled = function() return false end,
    },
    tmdb_index = {
        candidates = function() return {} end,
        matches = function(a, b) return a == b end,
    },
    title_normalize = title_normalize,
}, {poster_cache = {}, tmdb_lookup_generation = 1})

equal(tmdb._test.format_episode_title(4, 20, 'Chatty'),
    '04 of 20: Chatty', 'episode total formatting')
equal(tmdb._test.format_episode_title(4, nil, 'Chatty'),
    '04: Chatty', 'episode fallback formatting')
equal(tmdb._test.title_similarity('Dune', 'Dune: Part Two') > 0.7,
    true, 'subtitle similarity')
equal(tmdb._test.title_similarity('攻殻機動隊', '攻殻機動隊'), 1,
    'Unicode title similarity')
local bracket_queries = tmdb._test.build_query_titles(
    '[MysteryGroup] Show Name', nil)
equal(#bracket_queries, 2, 'ambiguous bracket query count')
equal(bracket_queries[1], '[MysteryGroup] Show Name',
    'preserved bracket query priority')
equal(bracket_queries[2], 'Show Name', 'stripped bracket query fallback')
local plain_key = tmdb._test.show_cache_key(
    'Show Name', '2020', 'tv', nil, {})
local directory_key = tmdb._test.show_cache_key(
    'Show Name', '2020', 'tv', 'Different Directory', {})
equal(plain_key ~= directory_key, true, 'directory-aware show cache key')
equal(plain_key:match('^show:v3|') ~= nil, true, 'show cache schema marker')

local function staged_tmdb(responder, request_log)
    return tmdb_factory({
        cache = {
            TMDB_NEGATIVE_CACHE_TTL = 1,
            load_poster_cache = noop,
            persistent_entry_expired = function() return false end,
            remember_poster = noop,
            schedule_poster_cache_save = noop,
        },
        config = {
            TMDB_EPISODE_LOOKUP = true,
            TMDB_KEY = 'test-key',
            TMDB_LANG = 'en-US',
            TMDB_POSITIVE_CACHE_TTL = 60,
        },
        helpers = {
            format = string.format,
            gsub = string.gsub,
            log_info = noop,
            log_verbose = noop,
            log_warn = noop,
            match = string.match,
            time = function() return 1000 end,
            trim_memory_cache = noop,
        },
        http = {url_encode = function(value) return tostring(value) end},
        tmdb_requests = {
            tmdb_get_json_cached = function(url)
                request_log[#request_log + 1] = url
                return responder(url)
            end,
            tmdb_lookup_cancelled = function() return false end,
        },
        tmdb_index = {
            candidates_many = function() return {} end,
            candidates = function()
                error('batched local-index lookup was not used')
            end,
            matches = function(a, b)
                return title_normalize.normalize_index(a)
                    == title_normalize.normalize_index(b)
            end,
        },
        title_normalize = title_normalize,
    }, {poster_cache = {}, tmdb_lookup_generation = 1})
end

local movie_requests = {}
local movie_tmdb = staged_tmdb(function(url)
    if url:find('query=Target&page', 1, true) then
        return {results = {{
            id = 10, media_type = 'movie', title = 'Target',
            release_date = '2020-01-01', poster_path = '/target.jpg',
        }}}, 'ok'
    end
    return {results = {}}, 'ok'
end, movie_requests)
local movie_hit = movie_tmdb.tmdb_lookup(
    '[MysteryGroup] Target', '2020', false, nil, nil, nil, 1)
equal(movie_hit and movie_hit.id, 10, 'movie bracket fallback result')
equal(#movie_requests, 2, 'movie staged alternate request count')
equal(movie_requests[2]:find('query=Target&page', 1, true) ~= nil, true,
    'movie bracket fallback searched')

local tv_requests = {}
local tv_tmdb = staged_tmdb(function(url)
    if url:find('query=Target Show&page', 1, true) then
        return {results = {{
            id = 20, name = 'Target Show', first_air_date = '2020-01-01',
            poster_path = '/target-show.jpg',
        }}}, 'ok'
    end
    return {results = {}}, 'ok'
end, tv_requests)
local tv_hit = tv_tmdb.tmdb_lookup(
    '[MysteryGroup] Wrong', '2020', true, nil, nil, 'Target Show', 1)
equal(tv_hit and tv_hit.id, 20, 'TV directory fallback result')
equal(#tv_requests, 3, 'TV staged directory request count')
equal(tv_requests[3]:find('query=Target Show&page', 1, true) ~= nil, true,
    'TV directory fallback searched')
equal(tv_requests[3]:find('first_air_date_year=2020', 1, true) ~= nil, true,
    'TV directory fallback preserves year filter')

local cache_factory = assert(loadfile(root .. '/modules/cache.lua'))()
local cache = cache_factory({
    config = {IS_WINDOWS = false, PATH_SEP = '/', PID = 1, CACHE_PATH = '/tmp/test-cache'},
    helpers = {
        SCRIPT_DIR = root,
        format = string.format,
        format_json = function() return '{}' end,
        log_verbose = noop,
        log_warn = noop,
        parse_json = function() return {} end,
        time = function() return 1000 end,
    },
}, {})
equal(cache.persistent_entry_expired({expires_at = 999}), true,
    'expired persistent entry')
equal(cache.persistent_entry_expired({expires_at = 1001}), false,
    'live persistent entry')

local gzip_factory = assert(loadfile(root .. '/tools/gzip.lua'))()
local compressed_seen = false
local gunzip = gzip_factory({
    DecompressDeflate = function(_, compressed)
        compressed_seen = #compressed == 7
        return 'hello', 0
    end,
})
local gzip_holder = {data = string.char(
    31,139,8,0,0,0,0,0,0,3,203,72,205,201,201,7,0,
    134,166,16,54,5,0,0,0)}
equal(gunzip(gzip_holder), 'hello', 'gzip framing and checksums')
equal(gzip_holder.data, nil, 'gzip source release')
equal(compressed_seen, true, 'raw DEFLATE extraction')

local health_factory = assert(loadfile(root .. '/tools/index_health.lua'))()
local health = health_factory({})
local health_now = os.time()
local healthy_meta = {
    generation = 'g0123456789abcdef0123456789abcdef',
    exported_at = health_now - 86400,
}
equal(health.maintenance_due(healthy_meta, true, {
    generation = healthy_meta.generation,
    valid = true,
    checked_at = health_now - 60,
}, health_now, 86400), false, 'recent index maintenance check')
equal(health.maintenance_due(healthy_meta, true, {
    generation = healthy_meta.generation,
    valid = true,
    checked_at = health_now - 86400,
}, health_now, 86400), true, 'due index maintenance check')
equal(health.maintenance_due(healthy_meta, true, {
    generation = healthy_meta.generation,
    valid = false,
    checked_at = health_now,
}, health_now, 86400), true, 'failed index maintenance check')
equal(health.maintenance_due(nil, false, nil, health_now, 86400), true,
    'missing index maintenance check')
local fingerprint_path = os.tmpname()
local fingerprint_file = assert(io.open(fingerprint_path, 'wb'))
assert(fingerprint_file:write('Wikipedia'))
assert(fingerprint_file:close())
local fingerprint = health.fingerprint(fingerprint_path)
os.remove(fingerprint_path)
equal(fingerprint.size, 9, 'fingerprint size')
equal(fingerprint.adler, 0x11E60398, 'Adler-32 fallback')

local builder_factory = assert(loadfile(root .. '/tools/index_builder.lua'))()
local builder_json = {
    parse_json = function(line)
        return {
            id = tonumber(assert(line:match('"id":(%d+)'))),
            original_title = assert(line:match('"original_title":"([^"]+)"')),
            adult = false,
            video = false,
        }
    end,
    format_json = function(value)
        if type(value) == 'string' then return '"' .. value .. '"' end
        local values = {}
        for i = 1, #value do values[i] = string.format('%.0f', value[i]) end
        return '[' .. table.concat(values, ',') .. ']'
    end,
}
local builder = builder_factory(builder_json, function(holder)
    local value = holder.data
    holder.data = nil
    return value
end, title_normalize.normalize_index)
local builder_source = os.tmpname()
local builder_base = builder_source .. '.index'
local builder_input = assert(io.open(builder_source, 'wb'))
assert(builder_input:write(
    '{"id":2,"original_title":"Zulu"}\n' ..
    '{"id":3,"original_title":"Alpha"}\n' ..
    '{"id":1,"original_title":"Alpha"}\n'))
assert(builder_input:close())
equal(builder(builder_source, builder_base, 'movie', noop), 2,
    'temporary index records')
local builder_data = assert(io.open(builder_base .. '.jsonl', 'rb'))
local builder_text = assert(builder_data:read('*a'))
builder_data:close()
os.remove(builder_source)
os.remove(builder_base .. '.jsonl')
os.remove(builder_base .. '.offsets')
equal(builder_text, '["alpha",[1,3]]\n["zulu",[2]]\n',
    'native string index ordering')

-- Discord replies are associated with the exact command context by nonce.
local saved_socket_unix_preload = package.preload['socket.unix']
local saved_socket_unix_loaded = package.loaded['socket.unix']
package.loaded['socket.unix'] = nil
package.preload['socket.unix'] = function()
    return function() return {} end
end
local parsed_rpc_response
local ipc_factory = assert(loadfile(root .. '/modules/ipc.lua'))()
local ipc = assert(ipc_factory({
    config = {CLIENT_ID = 'test-client', PID = 123},
    helpers = {
        byte = string.byte,
        char = string.char,
        floor = math.floor,
        format = string.format,
        format_json = function(value)
            if type(value) == 'string' then return '"' .. value .. '"' end
            return '{}'
        end,
        log_error = noop,
        log_info = noop,
        log_verbose = noop,
        log_warn = noop,
        parse_json = function() return parsed_rpc_response end,
        sub = string.sub,
    },
}, {}))
local test_rpc = ipc.RPC
test_rpc.socket = {close = noop}
test_rpc.send_raw = function() return true end
local sent, nonce = test_rpc:set_activity({}, {activity_sig = 'activity-a'})
equal(sent, true, 'tracked Discord command send')
local rpc_error_context
test_rpc.on_error = function(_, pending)
    rpc_error_context = pending and pending.context
end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
parsed_rpc_response = {evt = 'ERROR', nonce = nonce, data = {message = 'bad'}}
test_rpc.rx_buffer = le32(1) .. le32(2) .. '{}'
equal(test_rpc:drain_frames(), true, 'Discord error frame drain')
equal(rpc_error_context.activity_sig, 'activity-a', 'Discord error nonce context')
equal(test_rpc.pending[nonce], nil, 'Discord error clears pending command')
local _, ack_nonce = test_rpc:set_activity({}, {activity_sig = 'activity-b'})
local rpc_ack_context
test_rpc.on_response = function(_, pending)
    rpc_ack_context = pending and pending.context
end
parsed_rpc_response = {nonce = ack_nonce}
test_rpc.rx_buffer = le32(1) .. le32(2) .. '{}'
equal(test_rpc:drain_frames(), true, 'Discord response frame drain')
equal(rpc_ack_context.activity_sig, 'activity-b', 'Discord response nonce context')
package.preload['socket.unix'] = saved_socket_unix_preload
package.loaded['socket.unix'] = saved_socket_unix_loaded

-- Several related mpv events in one burst result in one presence update. A
-- rejected current payload retries once; a late rejection for an older payload
-- is ignored.
local saved_mp = mp
local event_handlers, property_handlers, presence_timers = {}, {}, {}
local presence_properties = {
    ['media-title'] = 'Activity A',
    ['time-pos'] = 10,
    duration = 100,
    speed = 1,
    pause = false,
    ['paused-for-cache'] = false,
    ['idle-active'] = false,
}
mp = {
    add_timeout = function(delay, fn)
        local timer = {delay = delay, fn = fn, killed = false}
        function timer:kill() self.killed = true end
        presence_timers[#presence_timers + 1] = timer
        return timer
    end,
    add_periodic_timer = function(delay, fn)
        local timer = {delay = delay, fn = fn, killed = false}
        function timer:kill() self.killed = true end
        presence_timers[#presence_timers + 1] = timer
        return timer
    end,
    register_event = function(name, fn) event_handlers[name] = fn end,
    observe_property = function(name, _, fn) property_handlers[name] = fn end,
    add_key_binding = noop,
    osd_message = noop,
}
local presence_sends = {}
local presence_rpc = {
    socket = true,
    set_activity = function(_, _, context)
        presence_sends[#presence_sends + 1] = context
        return true, tostring(#presence_sends)
    end,
    handshake = function() return true end,
    close = noop,
    shutdown_fast = noop,
}
local presence_shared = {enabled = true, tmdb_lookup_generation = 0}
assert(assert(loadfile(root .. '/modules/presence.lua'))()({
    artwork = {presence_image = function(value) return value or 'fallback' end},
    cache = {load_poster_cache = noop, save_poster_cache = noop},
    config = {
        ACTIVITY_WATCHING = 3,
        FALLBACK_IMG = 'fallback', FALLBACK_TXT = 'fallback',
        KEY_TOGGLE = 'D', SMALL_IDLE = '', SMALL_PAUSE = '', SMALL_PLAY = '',
    },
    filename = {meaningful_chapter_title = noop, tagged_title = noop},
    helpers = {
        floor = math.floor,
        get_property = function(name) return presence_properties[name] end,
        get_property_bool = function(name) return presence_properties[name] end,
        get_property_number = function(name) return presence_properties[name] end,
        log_warn = noop,
        time = function() return 1000 end,
        truncate_utf8 = function(value) return value end,
    },
    ipc = {RPC = presence_rpc, rpc_backoff_active = function() return false end},
    metadata = {clear_title_state = noop, lookup_poster = noop},
    tmdb_requests = {tmdb_abort_inflight_requests = noop},
}, presence_shared))
property_handlers.pause(nil, true)
property_handlers.speed(nil, 2)
property_handlers.duration(nil, 100)
local refresh_count = 0
local first_refresh
for _, timer in ipairs(presence_timers) do
    if timer.delay == 0.075 then refresh_count = refresh_count + 1; first_refresh = timer end
end
equal(refresh_count, 1, 'presence event burst coalescing')
first_refresh.fn()
equal(#presence_sends, 1, 'coalesced presence send count')
local old_context = presence_sends[1]
presence_properties['media-title'] = 'Activity B'
event_handlers['playback-restart']()
local second_refresh = presence_timers[#presence_timers]
second_refresh.fn()
local current_context = presence_sends[2]
local timers_before_stale_error = #presence_timers
presence_rpc.on_error({}, {
    command = 'SET_ACTIVITY', nonce = '1', context = old_context,
})
equal(#presence_timers, timers_before_stale_error, 'stale Discord error ignored')
presence_rpc.on_error({}, {
    command = 'SET_ACTIVITY', nonce = '2', context = current_context,
})
local retry_timer = presence_timers[#presence_timers]
equal(retry_timer.delay, 1, 'Discord rejection retry delay')
retry_timer.fn()
equal(#presence_sends, 3, 'Discord rejection retry send')
local timers_before_second_error = #presence_timers
presence_rpc.on_error({}, {
    command = 'SET_ACTIVITY', nonce = '3', context = presence_sends[3],
})
equal(#presence_timers, timers_before_second_error, 'Discord rejection retries once')
mp = saved_mp

for _,path in ipairs({
    'main.lua',
    'db/parsing_keywords.lua',
    'modules/artwork.lua',
    'modules/cache.lua',
    'modules/config.lua',
    'modules/database.lua',
    'modules/filename.lua',
    'modules/helpers.lua',
    'modules/http.lua',
    'modules/ipc.lua',
    'modules/metadata.lua',
    'modules/presence.lua',
    'modules/tmdb.lua',
    'modules/tmdb_index.lua',
    'modules/tmdb_requests.lua',
    'modules/title_normalize.lua',
    'tools/gzip.lua',
    'tools/index_builder.lua',
    'tools/index_health.lua',
    'tools/index_platform.lua',
    'tools/update_tmdb_index.lua',
    'tools/vendor/LibDeflate.lua',
}) do
    local chunk, err = loadfile(root .. '/' .. path)
    assert(chunk, path .. ': ' .. tostring(err))
    passed = passed + 1
end

io.write(string.format('ok - %d assertions\n', passed))
