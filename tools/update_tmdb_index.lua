-- Run explicitly in a separate mpv instance; never loaded by main.lua.
local utils=require 'mp.utils'
local options=require 'mp.options'
local settings={date='',movie_export='',tv_export=''}
options.read_options(settings,'tmdb-index')
local tools_dir=mp.get_script_directory()
if not tools_dir or tools_dir=='' then
    tools_dir=debug.getinfo(1,'S').source:match('^@(.+)[/\\][^/\\]+$') or 'tools'
end
local root=tools_dir..'/../db/tmdb/'
local function log(s) mp.msg.info('TMDb index: '..s) end
local FULL_CHECK_INTERVAL=24*60*60

local function valid_generation(name)
    return type(name)=='string' and #name==33 and name:match('^g%x+$')~=nil
end

local function remove_tree(path)
    local entries=utils.readdir(path,'all')
    if entries then
        for _,name in ipairs(entries) do remove_tree(path..'/'..name) end
    end
    os.remove(path)
end

local function cleanup_generations(meta)
    local active=meta.generation
    for _,name in ipairs(utils.readdir(root,'all') or {}) do
        if valid_generation(name) then
            if name~=active then remove_tree(root..name) end
        else
            local generation=name:match('^(g%x+)%-')
            if valid_generation(generation) then
                if generation~=active or name:match('%.json%.gz$') then
                    os.remove(root..name)
                end
            end
        end
    end
    if meta.layout~='flat' then
        local active_dir=root..active..'/'
        for _,name in ipairs(utils.readdir(active_dir,'files') or {}) do
            if name:match('%.json%.gz$') then os.remove(active_dir..name) end
        end
    end
    os.remove(root..'current.json.bak')
end

local function run()
    local deflate=assert(loadfile(tools_dir..'/vendor/LibDeflate.lua'))()
    local gunzip=assert(loadfile(tools_dir..'/gzip.lua'))()(deflate)
    local title_normalize=assert(loadfile(tools_dir..'/../modules/title_normalize.lua'))()()
    local build=assert(loadfile(tools_dir..'/index_builder.lua'))()
        (utils,gunzip,title_normalize.normalize_index)
    local date=settings.date~='' and settings.date or os.date('!%Y-%m-%d',os.time()-86400)
    local y,m,d=date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    assert(y,'date must be YYYY-MM-DD')
    local stamp=os.time{year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=12}
    assert(stamp and os.date('%Y-%m-%d',stamp)==date,'invalid calendar date')
    assert((settings.movie_export=='')==(settings.tv_export==''),'provide both local export paths')
    local generation=string.format('g%08x%08x%08x%08x',os.time(),utils.getpid(),
        math.floor(mp.get_time()*1000000)%4294967296,math.random(0,2147483647))
    local owned={}
    local function path(suffix)
        local p=root..generation..'-'..suffix;owned[#owned+1]=p;return p
    end
    local counts,sources={},{}
    local tmp=path('current.tmp')
    local ok,err=pcall(function()
        -- db/tmdb is shipped with the script; no external mkdir is needed.
        local probe=assert(io.open(tmp,'wb'),'db/tmdb must exist and be writable');probe:close()
        for _,media in ipairs({'movie','tv'}) do
            local prefix=media=='movie' and 'movie_ids' or 'tv_series_ids'
            local filename=string.format('%s_%s_%s_%s.json.gz',prefix,m,d,y)
            local url='https://files.tmdb.org/p/exports/'..filename
            local target=path(filename)
            local supplied=media=='movie' and settings.movie_export or settings.tv_export
            if supplied~='' then
                local input=assert(io.open(supplied,'rb'))
                local output=assert(io.open(target,'wb'))
                local copied,copyerr=pcall(function()
                    while true do
                        local chunk=input:read(65536);if not chunk then break end
                        assert(output:write(chunk))
                    end
                    assert(output:flush())
                end)
                input:close();local closed=output:close();assert(copied,copyerr);assert(closed)
            else
                log('Downloading '..filename)
                local res=mp.command_native({name='subprocess',playback_only=false,
                    capture_stdout=false,capture_stderr=true,args={'curl','--fail','--location',
                    '--silent','--show-error','--retry','2','--connect-timeout','20','--max-time','300',
                    '--output',target,url}})
                assert(res and res.status==0,'download failed: '..tostring(res and res.stderr))
            end
            local base=root..generation..'-'..media
            owned[#owned+1]=base..'.jsonl';owned[#owned+1]=base..'.offsets'
            counts[media]=build(target,base,media,log);sources[media]=url
            os.remove(target)
            log(media..': '..counts[media]..' title keys')
            collectgarbage('collect')
        end
        local manifest={schema=1,layout='flat',generation=generation,counts=counts,
            created_at=os.time(),export_date=date,sources=sources}
        local health=assert(loadfile(tools_dir..'/index_health.lua'))()(utils)
        manifest.integrity=health.integrity(root,manifest)
        local f=assert(io.open(tmp,'wb'))
        local written,why=f:write(assert(utils.format_json(manifest))..'\n')
        local closed=f:close();assert(written,why);assert(closed)
        local current=root..'current.json'
        if not os.rename(tmp,current) then
            -- Windows may refuse replacement. Retain the previous pointer for
            -- recovery across a crash during the short publication window.
            local backup=root..'current.json.bak'
            local exists=io.open(current,'rb')
            assert(exists,'could not publish index');exists:close()
            os.remove(backup)
            assert(os.rename(current,backup),'could not preserve previous index pointer')
            if not os.rename(tmp,current) then
                os.rename(backup,current)
                error('could not publish index; previous pointer retained in current.json or current.json.bak')
            end
        end
    end)
    if not ok then
        for _,p in ipairs(owned) do os.remove(p) end
        error(err)
    end
    log('Ready. Running playback instances will pick up the completed index automatically.')
end
local function maintain()
    local platform=assert(loadfile(tools_dir..'/index_platform.lua'))()
    platform.mkdir(tools_dir..'/../db')
    platform.mkdir(root)
    local unlock=platform.lock(root..'update.lock')
    if not unlock then log('Another updater holds the lock, or db/tmdb is not writable.');return end
    local function save(name,value)
        local f=io.open(root..name,'wb')
        if f then f:write(assert(utils.format_json(value)));f:close() end
    end
    local ok,err=pcall(function()
        local health=assert(loadfile(tools_dir..'/index_health.lua'))()(utils)
        local meta=health.load(root)
        local now=os.time()
        local valid=false
        local sizes_ok=meta and health.sizes(root,meta) or false
        if sizes_ok and health.stale(meta) then
            -- The stale generation will be replaced and is no longer used by
            -- playback, so a full checksum here would only delay the update.
            valid=true
        elseif sizes_ok then
            local state=health.state(root)
            local recent=state and state.generation==meta.generation and state.valid
                and state.checked_at<=now+300 and now-state.checked_at<FULL_CHECK_INTERVAL
            if recent then
                valid=true
            else
                local checked,result=pcall(health.valid,root,meta)
                valid=checked and result or false
                save('health.json',{generation=meta.generation,valid=valid,checked_at=now})
            end
        elseif meta then
            save('health.json',{generation=meta.generation,valid=false,checked_at=now})
        end
        if valid and not health.stale(meta) then
            cleanup_generations(meta)
            log('Index is healthy and less than one week old; no download or build.')
            return
        end
        local f=io.open(root..'attempt.json','rb')
        if f then
            local raw=f:read(1024);f:close()
            local decoded,attempt=pcall(utils.parse_json,raw or '')
            if decoded and type(attempt)=='table' and type(attempt.started_at)=='number'
                and os.time()>=attempt.started_at and os.time()-attempt.started_at<3600 then
                log('Update retry deferred for up to one hour.');return
            end
        end
        save('attempt.json',{started_at=os.time()})
        run()
        local current=assert(health.load(root))
        save('health.json',{generation=current.generation,valid=true,checked_at=os.time()})
        os.remove(root..'attempt.json')
        cleanup_generations(current)
    end)
    unlock()
    assert(ok,err)
end
mp.add_timeout(0,function()
    local ok,err=pcall(maintain)
    if not ok then mp.msg.error(tostring(err)) end
    mp.commandv('quit',ok and '0' or '1')
end)
