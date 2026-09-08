-- Local parsing rules, loaded once at startup.
return function(modules, shared)
    local path = modules.helpers.SCRIPT_DIR .. modules.config.PATH_SEP
        .. 'db' .. modules.config.PATH_SEP .. 'parsing_keywords.lua'
    local chunk, err = loadfile(path)
    assert(chunk, 'discord-mpv-rpc: cannot load ' .. path .. ': ' .. tostring(err))
    local data = chunk()
    assert(type(data) == 'table' and type(data.release_suffixes) == 'table'
        and type(data.release_groups) == 'table', 'invalid parsing keyword table')
    return {parsing = data}
end
