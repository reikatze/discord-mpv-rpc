-- mpv Discord Rich Presence: module loading and per-script shared state.
-- Install main.lua alongside the modules and db subdirectories.
local script_dir = mp.get_script_directory()
if not script_dir or script_dir == '' then
    local source = debug.getinfo(1, 'S').source
    script_dir = source:match('^@(.+)[/\\][^/\\]+$') or '.'
end
local sep = package.config:sub(1, 1)
local modules = {}
local state = {}

local function load_module(name)
    local path = script_dir .. sep .. 'modules' .. sep .. name .. '.lua'
    local chunk, err = loadfile(path)
    assert(chunk, 'discord-mpv-rpc: cannot load ' .. path .. ': ' .. tostring(err))
    modules[name] = chunk()(modules, state)
end

load_module('config')
load_module('helpers')
load_module('title_normalize')
load_module('database')
load_module('tmdb_index')
load_module('cache')
load_module('http')
load_module('filename')
load_module('ipc')
load_module('artwork')
load_module('tmdb_requests')
load_module('tmdb')
load_module('metadata')
load_module('presence')
