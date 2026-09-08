-- Logging, UTF-8 truncation, script paths, and memory-cache helpers.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local IS_WINDOWS = modules.config.IS_WINDOWS
local msg = modules.config.msg
local utils = modules.config.utils

local floor  = math.floor
local char   = string.char
local byte   = string.byte
local sub    = string.sub
local gsub   = string.gsub
local match  = string.match
local format = string.format
local time   = os.time
local format_json = utils.format_json
local parse_json  = utils.parse_json
local create_co   = coroutine.create
local resume_co   = coroutine.resume
local yield_co    = coroutine.yield
local running_co  = coroutine.running

local get_property        = mp.get_property
local get_property_number = mp.get_property_number
local get_property_bool   = mp.get_property_bool
local function log_info(s)  msg.info('discord-mpv-rpc: ' .. s) end
local function log_warn(s)  msg.warn('discord-mpv-rpc: ' .. s) end
local function log_error(s) msg.error('discord-mpv-rpc: ' .. s) end
local function log_verbose(s) msg.verbose('discord-mpv-rpc: ' .. s) end
-- Keep outgoing text within a conservative byte budget without splitting UTF-8.
local function truncate_utf8(text, limit)
    if #text <= limit then return text end
    local cut = limit - 3
    while cut > 0 do
        local next_byte = byte(text, cut + 1)
        if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
        cut = cut - 1
    end
    return sub(text, 1, cut) .. '…'
end

----------------------------------------------------------------
-- Script directory (works for AppData and portable_config)
-- Cache lives next to this file:
--   .../scripts/discord-mpv-rpc/main.lua
--   .../scripts/discord-mpv-rpc/discord-mpv-rpc-posters.json
----------------------------------------------------------------
local function get_script_dir()
    local script_dir = mp.get_script_directory()
    if script_dir and script_dir ~= '' then
        return script_dir
    end

    if IS_WINDOWS then
        return (os.getenv('APPDATA') or '.') .. '\\mpv\\scripts\\discord-mpv-rpc'
    end
    local xdg = os.getenv('XDG_CONFIG_HOME')
    if xdg and xdg ~= '' then
        return xdg .. '/mpv/scripts/discord-mpv-rpc'
    end
    return (os.getenv('HOME') or '.') .. '/.config/mpv/scripts/discord-mpv-rpc'
end

local SCRIPT_DIR = get_script_dir()
local function trim_memory_cache(cache, max_entries)
    local now = mp.get_time()
    local count = 0

    -- Expired entries are always the first to go.
    for key, entry in pairs(cache) do
        if type(entry) == 'table' and entry.expires and now >= entry.expires then
            cache[key] = nil
        else
            count = count + 1
        end
    end

    if count <= max_entries then return end

    -- These caches are optimization-only. Arbitrary eviction keeps memory
    -- bounded without adding LRU bookkeeping to the hot path.
    local remove = count - max_entries
    for key in pairs(cache) do
        cache[key] = nil
        remove = remove - 1
        if remove <= 0 then break end
    end
end

return {
    SCRIPT_DIR = SCRIPT_DIR,
    byte = byte,
    char = char,
    create_co = create_co,
    floor = floor,
    format = format,
    format_json = format_json,
    get_property = get_property,
    get_property_bool = get_property_bool,
    get_property_number = get_property_number,
    gsub = gsub,
    log_error = log_error,
    log_info = log_info,
    log_verbose = log_verbose,
    log_warn = log_warn,
    match = match,
    parse_json = parse_json,
    resume_co = resume_co,
    running_co = running_co,
    sub = sub,
    time = time,
    trim_memory_cache = trim_memory_cache,
    truncate_utf8 = truncate_utf8,
    yield_co = yield_co,
}
end
