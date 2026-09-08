-- Configuration defaults, user options, and platform constants.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)


local utils = require 'mp.utils'
local msg   = require 'mp.msg'
local opts  = require 'mp.options'

local DEFAULT_CLIENT_ID = string.char(49, 53, 52, 54, 49, 51, 52, 48, 55, 52, 56, 56, 50, 55, 56, 57, 52, 52, 54)

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
}
opts.read_options(o, 'discord-mpv-rpc')

if o.client_id == '' then
    o.client_id = DEFAULT_CLIENT_ID
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
local POSTER_FIT   = o.poster_fit or 'contain'
local PID          = utils.getpid()
local IS_WINDOWS   = package.config:sub(1, 1) == '\\'
local PATH_SEP     = package.config:sub(1, 1)

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
    msg = msg,
    utils = utils,
}
end
