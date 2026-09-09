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
            candidates = function() return {} end,
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
