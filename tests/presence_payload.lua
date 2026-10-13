-- Fixture-driven filename -> TMDb -> artwork -> presence -> Discord IPC tests.
-- mpv jobs use its real JSON codec; standalone Lua needs no extra packages.
return function(root, codec)
local saved_mp = mp
local passed = 0
local noop = function() end
local function equal(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected)
        .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {};for k,v in pairs(value) do out[k] = copy(v) end;return out
end
local function encode(value)
    if type(value) == 'string' then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    if type(value) ~= 'table' then return tostring(value) end
    local items = {}
    for k,v in pairs(value) do items[#items+1] = encode(k) .. ':' .. encode(v) end
    table.sort(items);return '{' .. table.concat(items, ',') .. '}'
end
local function load(name, modules, shared)
    return assert(loadfile(root .. '/modules/' .. name .. '.lua'))()(modules, shared)
end
local function harness(fit, small_icons)
    local props = {path='/media/[Judas] Dragon Ball Daima - S01E04v2.mkv',
        ['media-title']='Unresolved file title',pause=false,['paused-for-cache']=false,
        ['idle-active']=false,['demuxer-via-network']=false,
        ['time-pos']=300,duration=1500,speed=1}
    local events, observers, keys, timers, frames, activities, jobs = {},{},{},{},{},{},{}
    local now, ignored, wsrv_status = 1700000000, false, 200
    local function timer(delay, fn)
        local t = {delay=delay,fn=fn,kill=function(self) self.dead=true end}
        timers[#timers+1]=t;return t
    end
    mp = {
        get_time=function() return 100 end,
        get_property=function(k) return props[k] end,
        get_property_number=function(k) return props[k] end,
        get_property_bool=function(k) return props[k] end,
        get_property_native=function() return nil end,
        register_event=function(k,fn) events[k]=fn end,
        observe_property=function(k,_,fn) observers[k]=fn end,
        add_key_binding=function(_,k,fn) keys[k]=fn end,
        register_script_message=noop,osd_message=noop,
        add_timeout=timer,add_periodic_timer=timer,
    }
    local shared = {enabled=true,script_dir=root,poster_cache={},tmdb_lookup_generation=0}
    local modules = {config={IS_WINDOWS=false,PATH_SEP='/',CLIENT_ID='fixture-client',PID=123,
        ACTIVITY_WATCHING=3,FALLBACK_IMG='fallback-image',FALLBACK_TXT='mpv',KEY_TOGGLE='D',
        SMALL_PLAY=small_icons and 'play-image' or '',
        SMALL_PAUSE=small_icons and 'pause-image' or '',
        SMALL_IDLE=small_icons and 'idle-image' or '',POSTER_FIT=fit,
        TMDB_KEY='fixture-key',TMDB_LANG='en-US',TMDB_EPISODE_LOOKUP=true,
        TMDB_POSITIVE_CACHE_TTL=86400,
        is_ignored_path=function() return ignored end,
        msg={info=noop,warn=noop,error=noop,verbose=noop},utils={
            format_json=function(value)
                if type(value)=='table' and value.assets then activities[#activities+1]=copy(value) end
                return codec and codec.format_json(value) or encode(value)
            end,
            parse_json=codec and codec.parse_json or noop,
        }}}
    modules.helpers=load('helpers',modules,shared)
    modules.helpers.time=function() return now end
    local cache_decoder=load('cache',modules,shared).unpack_cache_entry
    modules.cache={TMDB_NEGATIVE_CACHE_TTL=86400,unpack_cache_entry=cache_decoder,
        persistent_entry_expired=function(e) return e.expires_at and e.expires_at<=now end,
        remember_poster=function(k,v) shared.poster_cache[k]=v end,
        remember_posters=function(entries)
            for k,v in pairs(entries) do shared.poster_cache[k]=v end
        end,
        load_poster_cache=noop,save_poster_cache=noop,schedule_poster_cache_save=noop}
    modules.http={run_async=function(fn) jobs[#jobs+1]=fn end,
        url_encode=function(s) return (tostring(s):gsub('[^%w%-%.%_%~]',function(c)
            return string.format('%%%02X',c:byte()) end)) end,
        curl_request=function() return '',wsrv_status,nil end}
    -- Synthetic IDs and image paths; every API response is local and fixed.
    local tv={id=1001,name='Dragon Ball Daima',first_air_date='2024-10-11',
        poster_path='/show-poster.jpg',media_type='tv',popularity=100}
    local movie={id=2002,title='Birdman (or the Unexpected Virtue of Ignorance)',
        release_date='2014-10-17',poster_path='/movie-poster.jpg',media_type='movie',popularity=100}
    local season={season_number=1,episodes={}}
    for n=1,4 do season.episodes[n]={id=3000+n,season_number=1,episode_number=n,
        name=n==4 and 'Chatty' or 'Episode '..n,still_path=n==4 and '/episode-still.jpg' or nil} end
    local requests={}
    modules.tmdb_requests={tmdb_abort_inflight_requests=noop,
        tmdb_lookup_cancelled=function(token) return token~=shared.tmdb_lookup_generation end,
        tmdb_get_json_cached=function(url)
            requests[#requests+1]=url
            if url:find('/tv/1001/season/1?',1,true) then return copy(season),'ok' end
            if url:find('/search/tv?',1,true) then return {results={copy(tv)}},'ok' end
            if url:find('/search/multi?',1,true) then
                local wrong_year=copy(movie)
                wrong_year.id=9999;wrong_year.release_date='1999-01-01';wrong_year.poster_path='/wrong-year.jpg'
                return {results={wrong_year,copy(tv),copy(movie)}},'ok'
            end
            if url:find('/alternative_titles?',1,true) then return {titles={},results={}},'ok' end
            error('unexpected fixture API request: '..url)
        end}
    modules.tmdb_index={candidates_many=function() return {} end}
    modules.title_normalize=load('title_normalize',modules,shared)
    modules.database={parsing=assert(loadfile(root..'/db/parsing_keywords.lua'))()}
    modules.filename=load('filename',modules,shared)
    for _,name in ipairs({'tmdb_match','tmdb_episode','tmdb','artwork','metadata'}) do
        modules[name]=load(name,modules,shared)
    end
    modules.ipc_transport={install=function(rpc)
        rpc.socket=true
        rpc.close=function(self) self.socket=nil end
        rpc.send_some=function(_,data,offset)
            equal(offset,0,'complete fixture write starts at zero')
            frames[#frames+1]=data;return #data
        end
    end}
    modules.ipc=load('ipc',modules,shared)
    load('presence',modules,shared)
    local function latest()
        local frame=assert(frames[#frames],'no Discord frame was sent')
        local function u32(pos)
            local a,b,c,d=frame:byte(pos,pos+3)
            return a+b*256+c*65536+d*16777216
        end
        local op,size=u32(1),u32(5)
        equal(op,1,'Discord command opcode');equal(size,#frame-8,'Discord frame length')
        local body=frame:sub(9)
        assert(body:find('"cmd":"SET_ACTIVITY"',1,true),'wrong Discord command')
        passed=passed+1
        if codec then
            local command=assert(codec.parse_json(body),'invalid Discord JSON')
            equal(command.cmd,'SET_ACTIVITY','decoded Discord command')
            equal(command.args.pid,123,'Discord process ID')
            equal(type(command.nonce),'string','Discord nonce')
            return command.args.activity
        end
        return activities[#activities]
    end
    local function drain_jobs()
        while #jobs>0 do local fn=table.remove(jobs,1);fn() end
    end
    local function refresh()
        for _,t in ipairs(timers) do
            if not t.dead and t.delay==0.075 then t.dead=true;t.fn() end
        end
    end
    return {props=props,events=events,observers=observers,keys=keys,frames=frames,
        shared=shared,modules=modules,requests=requests,season=season,
        latest=latest,jobs=drain_jobs,refresh=refresh,
        ignored=function(v) ignored=v end,wsrv=function(v) wsrv_status=v end,
        now=function(v) now=v end}
end
local function verify(a,title,state,poster,url)
    equal(a.type,3,'WATCHING activity');equal(a.status_display_type,2,'display details')
    equal(a.name,title,'activity name');equal(a.details,title,'details title')
    equal(a.state,state,'episode or playback state')
    equal(a.details_url,url,'details link');equal(a.state_url,url,'state link')
    equal(a.assets.large_image,poster,'thumbnail URL');equal(a.assets.large_text,title,'thumbnail tooltip')
    equal(a.assets.large_url,url,'thumbnail link')
end
for _,fit in ipairs({'raw','contain'}) do
    local h=harness(fit,true)
    local function image(path)
        local raw='https://image.tmdb.org/t/p/w500'..path
        if fit=='raw' then return raw end
        return 'https://wsrv.nl/?url=image.tmdb.org%2Ft%2Fp%2Fw500'
            ..path:gsub('/','%%2F')..'&w=512&h=512&fit=contain&cbg=111111'
    end
    h.events['file-loaded']();h.jobs()
    local a=h.latest()
    local tvurl='https://www.themoviedb.org/tv/1001/season/1/episode/4'
    verify(a,'Dragon Ball Daima','04 of 4: Chatty',image('/episode-still.jpg'),tvurl)
    equal(a.assets.small_image,'play-image','playing icon');equal(a.assets.small_text,'Playing','playing tooltip')
    equal(a.timestamps.start,1699999700,'TV elapsed timestamp')
    equal(a.timestamps['end'],1700001200,'TV remaining timestamp')
    equal(1700000000-a.timestamps.start,300,'TV current seconds')
    equal(a.timestamps['end']-1700000000,1200,'TV remaining seconds')
    equal(h.shared.current_clean_title,'Dragon Ball Daima','parsed TV title')
    equal(#h.requests,2,'TV search and one season response')
    h.props.pause=true;h.observers.pause('pause',true);h.refresh();a=h.latest()
    equal(a.timestamps,nil,'paused progress is removed');equal(a.assets.small_text,'Paused','paused tooltip')
    equal(a.assets.small_image,'pause-image','paused icon')
    equal(a.state,'04 of 4: Chatty','pause retains episode title')
    h.props['time-pos']=600;h.props.pause=false;h.now(1700000100)
    h.observers.pause('pause',false);h.refresh();a=h.latest()
    equal(a.timestamps.start,1699999500,'resume uses position after paused seek')
    equal(a.timestamps['end'],1700001000,'resume remaining time')
    h.props.speed=2;h.observers.speed('speed',2);h.refresh();a=h.latest()
    equal(a.timestamps.start,1699999800,'2x elapsed timestamp')
    equal(a.timestamps['end'],1700000550,'2x remaining timestamp')
    h.props['time-pos']=900;h.events['playback-restart']();h.refresh();a=h.latest()
    equal(a.timestamps.start,1699999650,'seek rebases elapsed time')
    equal(a.timestamps['end'],1700000400,'seek rebases remaining time')
    h.props['paused-for-cache']=true;h.observers['paused-for-cache']('paused-for-cache',true)
    h.refresh();a=h.latest()
    equal(a.timestamps,nil,'buffering progress is removed');equal(a.assets.small_text,'Buffering','buffering tooltip')
    equal(a.assets.small_image,'pause-image','buffering icon')
    -- Change media in the same instance to catch stale TV episode/title/poster data.
    h.events['start-file']()
    h.props.path='/media/Birdman (or the Unexpected Virtue of Ignorance) (2014) 1080p BluRay.mkv'
    h.props['paused-for-cache']=false;h.props.speed=1;h.props['time-pos']=1800;h.props.duration=7200
    h.events['file-loaded']();h.jobs();a=h.latest()
    verify(a,'Birdman (or the Unexpected Virtue of Ignorance)','Playing',image('/movie-poster.jpg'),
        'https://www.themoviedb.org/movie/2002')
    equal(h.shared.current_episode,nil,'movie removes old TV episode')
    equal(a.timestamps.start,1699998300,'movie elapsed timestamp')
    equal(a.timestamps['end'],1700005500,'movie remaining timestamp')
    equal(1700000100-a.timestamps.start,1800,'movie current seconds')
    equal(a.timestamps['end']-1700000100,5400,'movie remaining seconds')
    local count=#h.frames;h.shared.tick(false)
    equal(#h.frames,count,'unchanged activity is not resent')
    h.props.speed=0;h.props['time-pos']=-20;h.shared.tick(true);a=h.latest()
    equal(a.timestamps.start,1700000100,'negative position clamps to zero')
    equal(a.timestamps['end'],1700007300,'invalid speed defaults to 1x')
    h.props['time-pos']=8000;h.shared.tick(true);a=h.latest()
    equal(a.timestamps['end'],1700000100,'position beyond duration has no remaining time')
    h.props.duration=0;h.shared.tick(true);equal(h.latest().timestamps,nil,'unknown duration has no progress')
    h.props['idle-active']=true;h.observers['idle-active']('idle-active',true);h.refresh();a=h.latest()
    equal(a.assets.small_image,'idle-image','idle icon');equal(a.assets.small_text,'Idle','idle tooltip')
    equal(a.timestamps,nil,'idle progress is removed')
    if fit=='contain' then
        -- A fresh instance probes a failed service, then sends the raw image.
        local failed=harness('contain',true);failed.wsrv(503)
        failed.events['file-loaded']();failed.jobs()
        equal(failed.latest().assets.large_image,'https://image.tmdb.org/t/p/w500/episode-still.jpg',
            'failed image proxy falls back to raw thumbnail')
    end
end
local fallback=harness('raw',true)
fallback.season.episodes[4].still_path=nil
fallback.events['file-loaded']();fallback.jobs()
equal(fallback.latest().assets.large_image,'https://image.tmdb.org/t/p/w500/show-poster.jpg',
    'episode without a still uses the show poster')
local h=harness('raw',false)
h.shared.tick(true)
local a=h.latest()
equal(a.assets.large_image,'fallback-image','missing metadata uses fallback image')
equal(a.assets.large_text,'mpv','fallback tooltip');equal(a.details_url,nil,'fallback has no stale link')
equal(a.assets.small_image,nil,'empty small icon is omitted');equal(a.assets.small_text,nil,'empty small tooltip is omitted')
h.shared.current_tmdb_title='"Quoted" \\ title\n界';h.shared.tick(true)
equal(h.latest().name,'"Quoted" \\ title\n界','Discord title preserves escaped text and Unicode')
h.shared.current_tmdb_title=string.rep('界',50);h.shared.tick(true);a=h.latest()
equal(#a.name,120,'UTF-8 title obeys byte limit');equal(a.name:sub(-3),'…','title ends with ellipsis')
local count=#h.frames
h.shared.enabled=false;h.shared.tick(true);equal(#h.frames,count,'disabled presence sends no activity')
h.shared.enabled=true;h.ignored(true);h.shared.tick(true);equal(#h.frames,count,'ignored media sends no activity')
h.ignored(false);h.props['demuxer-via-network']=true;h.shared.tick(true)
equal(#h.frames,count,'network media sends no activity')
h.props['demuxer-via-network']=false;h.events['end-file']()
equal(h.frames[#h.frames]:sub(9):find('"activity":null',1,true)~=nil,true,'end-file clears Discord activity')
equal(h.shared.current_tmdb_title,nil,'end-file clears title');equal(h.shared.current_poster,nil,'end-file clears poster')
mp=saved_mp
return passed
end
