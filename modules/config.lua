-- Configuration defaults, user options, and platform constants.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)


local utils = require 'mp.utils'
local msg   = require 'mp.msg'
local opts  = require 'mp.options'

local DEFAULT_CLIENT_ID = string.char(49, 53, 52, 54, 49, 51, 52, 48, 55, 52, 56, 56, 50, 55, 56, 57, 52, 52, 54)
local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

local o = {
    client_id       = DEFAULT_CLIENT_ID,
    large_image          = 'mpv',
    large_text           = 'mpv',
    small_image_playing  = 'play',
    small_image_paused   = 'pause',
    small_image_idle     = 'mpv',
    tmdb_api_key    = '',
    tmdb_language   = 'en-US',
    key_toggle      = 'D',
    enabled         = true,
    poster_fit      = 'contain',
    tmdb_episode_lookup = true,
    tmdb_local_index = true,
    key_toggle_db = 'Ctrl+d',
    tmdb_index_mpv_path = '',
    cache_path      = '',
    tmdb_positive_cache_days = 60,
    ignored_paths   = '[]',
}
opts.read_options(o, 'discord-mpv-rpc')

o.client_id = trim(o.client_id)
if o.client_id == '' then
    o.client_id = DEFAULT_CLIENT_ID
elseif not o.client_id:match('^%d+$') then
    msg.warn('client_id must contain only digits; using the built-in application')
    o.client_id = DEFAULT_CLIENT_ID
end

o.tmdb_language = trim(o.tmdb_language)
if o.tmdb_language == '' then
    msg.warn('tmdb_language cannot be empty; using en-US')
    o.tmdb_language = 'en-US'
end

o.poster_fit = trim(o.poster_fit):lower()
if o.poster_fit ~= 'contain' and o.poster_fit ~= 'raw' then
    msg.warn('poster_fit must be contain or raw; using contain')
    o.poster_fit = 'contain'
end

local positive_cache_days = tonumber(o.tmdb_positive_cache_days)
if not positive_cache_days then
    msg.warn('tmdb_positive_cache_days must be a number; using 60')
    positive_cache_days = 60
elseif positive_cache_days < 1 or positive_cache_days > 3650 then
    msg.warn('tmdb_positive_cache_days must be between 1 and 3650; clamping the value')
    positive_cache_days = math.max(1, math.min(positive_cache_days, 3650))
end

local CLIENT_ID    = o.client_id
local FALLBACK_IMG = o.large_image
local FALLBACK_TXT = o.large_text
local SMALL_PLAY   = o.small_image_playing
local SMALL_PAUSE  = o.small_image_paused
local SMALL_IDLE   = o.small_image_idle
local ACTIVITY_WATCHING = 3
local TMDB_KEY     = o.tmdb_api_key
local TMDB_LANG    = o.tmdb_language
local TMDB_EPISODE_LOOKUP = o.tmdb_episode_lookup ~= false
local KEY_TOGGLE   = o.key_toggle
shared.enabled      = o.enabled
local POSTER_FIT   = o.poster_fit
local PID          = utils.getpid()
local IS_WINDOWS   = package.config:sub(1, 1) == '\\'
local PATH_SEP     = package.config:sub(1, 1)

local function resolve_dot_segments(path)
    local prefix, rest, protected_segments = '', path, 0
    if path:match('^%a:/') then
        prefix, rest = path:sub(1, 3), path:sub(4)
    elseif path:sub(1, 2) == '//' then
        prefix, rest, protected_segments = '//', path:sub(3), 2
    elseif path:sub(1, 1) == '/' then
        prefix, rest = '/', path:sub(2)
    end

    local segments = {}
    for segment in rest:gmatch('[^/]+') do
        if segment == '..' then
            if #segments > protected_segments
                and segments[#segments] ~= '..' then
                table.remove(segments)
            elseif prefix == '' then
                segments[#segments + 1] = segment
            end
        elseif segment ~= '.' then
            segments[#segments + 1] = segment
        end
    end

    local body = table.concat(segments, '/')
    if prefix == '//' then return prefix .. body end
    if prefix ~= '' then return prefix .. body end
    return body == '' and '.' or body
end

local function normalize_local_path(path)
    if type(path) ~= 'string' or path == ''
        or path:match('^[%a][%w+.-]*://') then
        return nil
    end

    local ok, expanded = pcall(mp.command_native, {'expand-path', path})
    if ok and type(expanded) == 'string' and expanded ~= '' then
        path = expanded
    end

    local absolute = path:match('^[/\\]') or path:match('^%a:[/\\]')
    if not absolute then
        local working_directory = mp.get_property('working-directory')
        if working_directory and working_directory ~= '' then
            path = working_directory .. PATH_SEP .. path
        end
    end

    local unc = path:match('^[/\\][/\\]') ~= nil
    path = path:gsub('\\', '/'):gsub('/+', '/')
    if unc then path = '/' .. path end
    path = resolve_dot_segments(path)
    while #path > 1 and path:sub(-1) == '/' and not path:match('^%a:/$') do
        path = path:sub(1, -2)
    end
    if IS_WINDOWS then path = path:lower() end
    return path
end

local ignored_paths = {}
local ignored_paths_json = trim(tostring(o.ignored_paths or ''))
if ignored_paths_json == '' then ignored_paths_json = '[]' end
local parsed_ignored_paths
if ignored_paths_json:match('^%[') and ignored_paths_json:match('%]%s*$') then
    local ok, value = pcall(utils.parse_json, ignored_paths_json)
    if ok and type(value) == 'table' then parsed_ignored_paths = value end
end
local valid_ignored_paths = parsed_ignored_paths ~= nil
if valid_ignored_paths then
    local entry_count, highest_index = 0, 0
    for key, entry in pairs(parsed_ignored_paths) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0
            or type(entry) ~= 'string' then
            valid_ignored_paths = false
            break
        end
        entry_count = entry_count + 1
        highest_index = math.max(highest_index, key)
    end
    if highest_index ~= entry_count then valid_ignored_paths = false end
end
if not valid_ignored_paths then
    msg.warn('ignored_paths must be a JSON array of strings; ignoring the option')
else
    for _, entry in ipairs(parsed_ignored_paths) do
        local normalized = normalize_local_path(trim(entry))
        if normalized then ignored_paths[#ignored_paths + 1] = normalized end
    end
end

local function is_ignored_path(path)
    local normalized = normalize_local_path(path)
    if not normalized then return false end
    for _, ignored in ipairs(ignored_paths) do
        local prefix = ignored:sub(-1) == '/' and ignored or ignored .. '/'
        if normalized == ignored
            or normalized:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local cache_path = o.cache_path
local expanded_cache_path = nil
if cache_path and cache_path ~= '' then
    local ok, value = pcall(mp.command_native, {'expand-path', cache_path})
    if ok and type(value) == 'string' and value ~= '' then
        expanded_cache_path = value
    end
end
return {
    ACTIVITY_WATCHING = ACTIVITY_WATCHING,
    CLIENT_ID = CLIENT_ID,
    FALLBACK_IMG = FALLBACK_IMG,
    FALLBACK_TXT = FALLBACK_TXT,
    IS_WINDOWS = IS_WINDOWS,
    KEY_TOGGLE = KEY_TOGGLE,
    PATH_SEP = PATH_SEP,
    PID = PID,
    POSTER_FIT = POSTER_FIT,
    SMALL_IDLE = SMALL_IDLE,
    SMALL_PAUSE = SMALL_PAUSE,
    SMALL_PLAY = SMALL_PLAY,
    TMDB_EPISODE_LOOKUP = TMDB_EPISODE_LOOKUP,
    TMDB_KEY = TMDB_KEY,
    TMDB_LANG = TMDB_LANG,
    TMDB_LOCAL_INDEX = o.tmdb_local_index ~= false,
    KEY_TOGGLE_DB = o.key_toggle_db,
    TMDB_INDEX_MPV_PATH = o.tmdb_index_mpv_path,
    CACHE_PATH = expanded_cache_path,
    TMDB_POSITIVE_CACHE_TTL = positive_cache_days * 24 * 60 * 60,
    is_ignored_path = is_ignored_path,
    msg = msg,
    utils = utils,
}
end
