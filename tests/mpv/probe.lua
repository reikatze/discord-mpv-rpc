local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    mode = 'idle',
    expected_title = '',
    expected_year = '',
    expected_tv = false,
    expected_season = 0,
    expected_episode = 0,
}
options.read_options(o, 'mpv-rpc-test')

local source = debug.getinfo(1, 'S').source
local root = assert(source:match('^@(.+)[/\\]tests[/\\]mpv[/\\][^/\\]+$'))
local failed = false
local saw_file_loaded = false
local saw_end_file = false

local function fail(message)
    if failed then return end
    failed = true
    msg.error('MPV_TEST_FAILURE ' .. tostring(message))
    mp.commandv('quit', 1)
end

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function guarded(fn)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then fail(err) end
    end
end

local function check_runtime()
    check(type(jit) == 'table', 'mpv is not using LuaJIT')
    check(type(mp.get_property) == 'function', 'mpv Lua API is unavailable')
end

local function check_filename()
    local parsing = assert(loadfile(root .. '/db/parsing_keywords.lua'))()
    local title_normalize =
        assert(loadfile(root .. '/modules/title_normalize.lua'))()()
    local filename = assert(loadfile(root .. '/modules/filename.lua'))()({
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
        filename.clean_filename(assert(mp.get_property('path')))
    local expected_title = o.expected_title
    check(title == expected_title,
        string.format('expected title %q, got %q', expected_title, title))
    if o.expected_year ~= '' then
        check(year == o.expected_year,
            string.format('expected year %q, got %q', o.expected_year, year))
    else
        check(year == nil, 'expected no parsed year, got ' .. tostring(year))
    end
    check(is_tv == o.expected_tv,
        string.format('expected tv=%s, got %s', tostring(o.expected_tv), tostring(is_tv)))
    if o.expected_season > 0 then
        check(season == o.expected_season,
            string.format('expected season %d, got %s', o.expected_season, tostring(season)))
    end
    if o.expected_episode > 0 then
        check(episode == o.expected_episode,
            string.format('expected episode %d, got %s', o.expected_episode, tostring(episode)))
    end
end

if o.mode == 'idle' then
    mp.add_timeout(0.1, guarded(function()
        check_runtime()
        msg.info('MPV_TEST_IDLE_OK')
        mp.commandv('quit', 0)
    end))
elseif o.mode == 'toggle' then
    mp.add_timeout(0.1, guarded(function()
        check_runtime()
        mp.commandv('script-binding', 'main/discord-mpv-rpc-toggle')
        mp.commandv('script-binding', 'main/discord-mpv-rpc-toggle')
        msg.info('MPV_TEST_TOGGLE_OK')
        mp.commandv('quit', 0)
    end))
elseif o.mode == 'playback' or o.mode == 'filename' then
    mp.register_event('file-loaded', guarded(function()
        check_runtime()
        saw_file_loaded = true
        check(type(mp.get_property('path')) == 'string', 'path is unavailable')
        check((mp.get_property_number('duration') or 0) > 0,
            'media duration is unavailable')
        if o.mode == 'filename' then check_filename() end
    end))
    mp.register_event('end-file', guarded(function()
        saw_end_file = true
    end))
    mp.register_event('shutdown', function()
        if failed then return end
        if not saw_file_loaded then
            msg.error('MPV_TEST_FAILURE file-loaded was not observed')
        elseif not saw_end_file then
            msg.error('MPV_TEST_FAILURE end-file was not observed')
        elseif o.mode == 'filename' then
            msg.info('MPV_TEST_FILENAME_OK')
        else
            msg.info('MPV_TEST_PLAYBACK_OK')
        end
    end)
    mp.add_timeout(15, function()
        if not saw_end_file then fail('playback test timed out') end
    end)
else
    fail('unknown probe mode: ' .. tostring(o.mode))
end
