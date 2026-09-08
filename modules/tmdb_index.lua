-- Optional disk-backed TMDb export index. No full export is loaded into Lua.
return function(modules, shared)
    local root = modules.helpers.SCRIPT_DIR .. '/db/tmdb/'
    local parse_json = modules.helpers.parse_json
    local tools_dir = modules.helpers.SCRIPT_DIR .. '/tools/'
    local health = assert(loadfile(tools_dir .. 'index_health.lua'))()(modules.config.utils)
    local enabled = modules.config.TMDB_LOCAL_INDEX ~= false
    local manifest, bad_generation, observed_generation
    local next_launch, next_read = 0, 0
    local function launch()
        if not enabled or mp.get_time() < next_launch then return end
        next_launch = mp.get_time() + 3600
        if not rawget(_G,'jit') then
            modules.helpers.log_warn('automatic DB maintenance requires an mpv build with LuaJIT; using online search')
            return
        end
        local executable = modules.config.TMDB_INDEX_MPV_PATH
        if not executable or executable == '' then
            local ok, platform = pcall(function()
                return assert(loadfile(tools_dir .. 'index_platform.lua'))()
            end)
            if ok then
                local found, path = pcall(platform.executable)
                if found then executable = path end
            end
        end
        if not executable or executable == '' then executable = 'mpv' end
        mp.command_native_async({name='subprocess', playback_only=false, detach=true,
            capture_stdout=false, capture_stderr=false,
            args={executable, '--no-config', '--load-scripts=no', '--idle=yes',
                '--vo=null', '--ao=null', '--terminal=no',
                '--script=' .. tools_dir .. 'update_tmdb_index.lua'}}, function(_,res)
            if not res or res.status ~= 0 then
                modules.helpers.log_warn('could not start background DB maintenance; online search remains available')
            end
        end)
    end
    local function normalize(s)
        s = s:gsub('[A-Z]', function(c) return string.char(c:byte() + 32) end)
        return (s:gsub('[\009-\013\032-\047\058-\064\091-\096\123-\126]+', ' ')
            :gsub('^ +', ''):gsub(' +$', ''))
    end
    local function load_manifest()
        if not enabled then return nil end
        if mp.get_time() < next_read then return manifest end
        next_read = mp.get_time() + 10
        local value = health.load(root)
        if not value or health.stale(value) or not health.sizes(root,value) then
            manifest=nil
            launch()
            return nil
        end
        local verified=false
        local f=io.open(root..'health.json','rb')
        if f then
            local raw=f:read(4096);f:close()
            local ok,state=pcall(parse_json,raw or '')
            if ok and type(state)=='table' and state.generation==value.generation and state.valid==false then
                bad_generation=value.generation
            elseif ok and type(state)=='table' and state.generation==value.generation and state.valid==true then
                verified=true
            end
        end
        if value.generation==bad_generation then manifest=nil;launch();return nil end
        if not verified then manifest=nil;launch();return nil end
        manifest=value
        if observed_generation~=value.generation then
            observed_generation=value.generation
            mp.add_timeout(0,function()
                if enabled and modules.metadata and mp.get_property('path') then
                    modules.metadata.lookup_poster()
                end
            end)
        end
        return manifest
    end
    local function corrupt()
        if manifest and bad_generation~=manifest.generation then
            bad_generation=manifest.generation;next_launch=0
        end
        manifest=nil;next_read=0
        launch()
    end
    local function less(a, b)
        for i = 1, math.min(#a, #b) do
            if a:byte(i) ~= b:byte(i) then return a:byte(i) < b:byte(i) end
        end
        return #a < #b
    end
    local function candidates(title, is_tv)
        local loaded, meta = pcall(load_manifest)
        if not loaded or not meta then return {} end
        local media = is_tv and 'tv' or 'movie'
        local count = meta.counts[media]
        if type(count) ~= 'number' or count < 1 or count % 1 ~= 0 or count > 10000000 then return {} end
        if meta.layout ~= nil and meta.layout ~= 'flat' then return {} end
        local base = root .. meta.generation .. (meta.layout == 'flat' and '-' or '/') .. media
        local offsets = io.open(base .. '.offsets', 'rb')
        local data = io.open(base .. '.jsonl', 'rb')
        if not offsets or not data then
            if offsets then offsets:close() end
            if data then data:close() end
            corrupt();return {}
        end
        local ok, result = pcall(function()
            assert(offsets:seek('end') == count * 17)
            local key = normalize(title)
            local low, high = 0, count - 1
            while low <= high do
                local mid = math.floor((low + high) / 2)
                assert(offsets:seek('set', mid * 17))
                local entry = offsets:read(17)
                assert(entry and entry:match('^%d+\n$'))
                assert(data:seek('set', assert(tonumber(entry))))
                local block = data:read(4096)
                local line = block and block:match('^([^\n]*)\n')
                local row = line and parse_json(line)
                assert(type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'table')
                if row[1] == key then
                    if #row[2] > 4 then return {} end
                    for _, id in ipairs(row[2]) do
                        assert(type(id) == 'number' and id > 0 and id % 1 == 0)
                    end
                    return row[2]
                elseif less(row[1], key) then low = mid + 1
                else high = mid - 1 end
            end
            return {}
        end)
        offsets:close()
        data:close()
        if not ok then corrupt();return {} end
        return result
    end
    local function toggle()
        enabled=not enabled
        manifest=nil;next_read=0
        if enabled then next_launch=0;launch() end
        mp.osd_message('TMDb local DB: '..(enabled and 'on' or 'off'))
    end
    if modules.config.KEY_TOGGLE_DB and modules.config.KEY_TOGGLE_DB~='' then
        mp.add_key_binding(modules.config.KEY_TOGGLE_DB,'toggle-tmdb-db',toggle)
    end
    mp.register_script_message('discord-mpv-rpc-toggle-db',toggle)
    mp.add_timeout(2,launch)
    mp.add_periodic_timer(60,function()
        if enabled then pcall(load_manifest);launch() end
    end)
    return {candidates = candidates, matches = function(a, b)
        return type(b) == 'string' and normalize(a) ~= '' and normalize(a) == normalize(b)
    end}
end
