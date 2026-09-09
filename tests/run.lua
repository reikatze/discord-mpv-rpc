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

local parsing = assert(loadfile(root .. '/db/parsing_keywords.lua'))()
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
}, {poster_cache = {}, tmdb_lookup_generation = 1})

equal(tmdb._test.format_episode_title(4, 20, 'Chatty'),
    '04 of 20: Chatty', 'episode total formatting')
equal(tmdb._test.format_episode_title(4, nil, 'Chatty'),
    '04: Chatty', 'episode fallback formatting')
equal(tmdb._test.title_similarity('Dune', 'Dune: Part Two') > 0.7,
    true, 'subtitle similarity')

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
