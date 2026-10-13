-- Regression checks for eligibility, indexed cache generations, season reuse,
-- and asynchronous IPC. No network or master database is used.
return function(root)
local saved_mp = mp
local passed = 0
local function check(value, label)
    assert(value, label)
    passed = passed + 1
end
local noop = function() end
local clock, timers = 100, {}
mp = {
    get_time = function() return clock end,
    add_periodic_timer = function(delay, fn)
        local t = {delay=delay,fn=fn,kill=noop};timers[#timers+1]=t;return t
    end,
    add_timeout = function(delay, fn)
        local t = {delay=delay,fn=fn,kill=noop};timers[#timers+1]=t;return t
    end,
    add_key_binding=noop,register_script_message=noop,
    get_property=function() return '/media/show.mkv' end,
}

local shared = {enabled=false,tmdb_lookup_generation=0}
local network, ignored, requests, deferred = false, false, 0
local metadata = assert(loadfile(root..'/modules/metadata.lua'))()({
    artwork={probe_wsrv=noop},config={TMDB_KEY='key',is_ignored_path=function() return ignored end},
    filename={clean_filename=function() return 'Show' end,directory_context=noop},
    helpers={format=string.format,get_property=mp.get_property,
        get_property_bool=function() return network end,log_verbose=noop},
    http={run_async=function(fn) deferred=fn end},
    tmdb={tmdb_lookup=function() requests=requests+1;return {title='Resolved'} end},
    tmdb_requests={tmdb_abort_inflight_requests=noop},
},shared)
metadata.lookup_poster();check(deferred==nil,'disabled presence starts no lookup')
shared.enabled=true;network=true
metadata.lookup_poster();check(deferred==nil,'network media starts no lookup')
network=false;ignored=true
metadata.lookup_poster();check(deferred==nil,'ignored media starts no lookup')
ignored=false;shared.media_loading=true
metadata.lookup_poster();check(deferred==nil,'loading media starts no lookup')
shared.media_loading=false;shared.tick=function() error('disabled callback published') end
metadata.lookup_poster();shared.enabled=false;deferred()
check(shared.current_tmdb_title==nil,'disabled lookup completion is discarded')
check(requests==1,'eligible lookup runs once')

-- Feed a synthetic generation through the real disk-index reader. Cached
-- positive and negative lookups must avoid index opens, and returned arrays
-- must not allow callers to mutate the cached result.
local real_loadfile, real_open = loadfile, io.open
local generation, opens = 'generation-a', 0
local fake_health = {
    load=function() return {generation=generation,counts={movie=1,tv=1},layout='flat'} end,
    sizes=function() return true end,
    state=function() return {generation=generation,valid=true} end,
    stale=function() return false end,
    maintenance_due=function() return false end,
}
loadfile=function(path)
    if path:match('index_health.lua$') then return function() return function() return fake_health end end end
    return real_loadfile(path)
end
io.open=function(path)
    opens=opens+1
    local offsets=path:match('offsets$')
    return {
        close=noop,
        seek=function(_,kind) return kind=='end' and 17 or 0 end,
        read=function() return offsets and '0000000000000000\n' or 'row\n' end,
    }
end
local index = real_loadfile(root..'/modules/tmdb_index.lua')()({
    config={TMDB_LOCAL_INDEX=true,TMDB_KEY='',utils={},KEY_TOGGLE_DB=''},
    helpers={SCRIPT_DIR=root,log_warn=noop,parse_json=function() return {'show',{generation=='generation-a' and 1 or 2}} end},
    title_normalize={normalize_index=function(s) return s:lower() end},
},{})
local ids=index.candidates('Show',false);check(ids[1]==1,'index returns first generation')
local initial_opens=opens;ids[1]=99
check(index.candidates('Show',false)[1]==1,'index result does not expose cache array')
check(opens==initial_opens,'positive index hit avoids file opens')
index.candidates('Missing',false);local miss_opens=opens
check(#index.candidates('Missing',false)==0 and opens==miss_opens,'negative index hit avoids file opens')
check(index.candidates('Show',true)[1]==1 and opens>miss_opens,'index cache separates media types')
for n=1,257 do index.candidates('absent-'..n,false) end
local evicted_opens=opens
index.candidates('Show',false)
check(opens>evicted_opens,'index cache evicts entries when its bound is reached')
generation='generation-b';clock=clock+11
check(index.candidates('Show',false)[1]==2,'generation change invalidates index cache')
loadfile,io.open=real_loadfile,real_open

local poster_shared={poster_cache={}}
local season_requests, episode_requests, wrong_identity=0,0,false
local episode = assert(loadfile(root..'/modules/tmdb_episode.lua'))()({
    config={TMDB_EPISODE_LOOKUP=true,TMDB_KEY='key',TMDB_LANG='en-US',TMDB_POSITIVE_CACHE_TTL=60*86400},
    cache={unpack_cache_entry=assert(loadfile(root..'/modules/cache.lua'))()({
        config={PATH_SEP='/'},helpers={SCRIPT_DIR=root},
    },{}).unpack_cache_entry,persistent_entry_expired=function(entry) return entry.expires_at and entry.expires_at<=clock end,
        remember_poster=function(key,value) poster_shared.poster_cache[key]=value end,
        remember_posters=function(entries)
            for key,value in pairs(entries) do poster_shared.poster_cache[key]=value end
        end,schedule_poster_cache_save=noop},
    helpers={format=string.format,time=function() return clock end,log_info=noop,log_verbose=noop,log_warn=noop},
    http={url_encode=function(s) return s end},
    tmdb_requests={tmdb_lookup_cancelled=function() return false end,tmdb_get_json_cached=function(url)
        if url:find('/episode/',1,true) then
            episode_requests=episode_requests+1
            if wrong_identity then
                return {season_number=2,episode_number=3,name='Wrong episode'},'ok'
            end
            return nil,'not_found'
        end
        season_requests=season_requests+1
        return {season_number=1,episodes={
            {id=1,season_number=1,episode_number=1,name='First',still_path='/first.jpg'},
            {id=2,season_number=1,episode_number=2,name='Second'},
        }},'ok'
    end},
},poster_shared)
local base={id=10,type='tv',title='Show',poster='/show.jpg',url='https://www.themoviedb.org/tv/10'}
local first=episode.apply_episode(base,1,1,1)
local second=episode.apply_episode(base,1,2,1)
check(first.episode=='01 of 2: First' and first.poster:find('/first.jpg',1,true),'season supplies episode title and artwork')
check(second.episode=='02 of 2: Second' and second.poster=='/show.jpg','season retains show poster fallback')
check(season_requests==1 and episode_requests==0,'sequential episodes share one season request')
check(poster_shared.poster_cache[episode.persistent_key(10,1,1)].expires_at==clock+86400,'season metadata expires within one day')
episode.apply_episode(base,1,3,1)
check(episode_requests==1,'missing season record falls back to individual endpoint')
clock=clock+86401;episode.apply_episode(base,1,1,1)
check(season_requests==2,'expired season metadata refreshes')
wrong_identity=true
poster_shared.poster_cache[episode.persistent_key(10,1,3)]=nil
local mismatch=episode.apply_episode(base,1,3,1)
check(mismatch==base,'mismatched episode keeps the original show metadata')
check(poster_shared.poster_cache[episode.persistent_key(10,1,3)]==nil,
    'mismatched episode is not cached as a hit or a miss')

-- A fragmented READY response is consumed by timer callbacks without blocking.
local reply, chunk, writes, closes, ready_count = nil, '', {}, 0, 0
local send_mode='again'
local ipc = assert(loadfile(root..'/modules/ipc.lua'))()({
    config={CLIENT_ID='test',PID=1},helpers={byte=string.byte,char=string.char,floor=math.floor,
        sub=string.sub,format_json=function(v) return type(v)=='string' and '"'..v..'"' or '{}' end,
        parse_json=function() return reply end,log_error=noop,log_info=noop,log_verbose=noop,log_warn=noop},
    ipc_transport={install=function(rpc)
        rpc.connect=function(self) self.socket=true;return true end
        rpc.close=function(self) self.socket=nil;closes=closes+1 end
        rpc.read_available=function() local result=chunk;chunk='';return result end
        rpc.send_some=function(_,data,offset)
            if send_mode=='again' then return nil,'again' end
            local n=math.min(3,#data-offset);writes[#writes+1]=data:sub(offset+1,offset+n);return n
        end
    end},
},{})
local rpc=ipc.RPC
rpc.on_ready=function() ready_count=ready_count+1;assert(rpc:set_activity({details='ready'})) end
check(rpc:handshake()==false and rpc.handshaking,'handshake returns before READY')
check(rpc:set_activity({})==false,'activity waits for READY')
local reader=timers[#timers];send_mode='partial';reader.fn()
check(table.concat(writes):sub(1,1)==string.char(0),'partial handshake writes preserve framing')
local frame=string.char(1,0,0,0,2,0,0,0)..'{}'
reply={evt='READY'};chunk=frame:sub(1,5);reader.fn()
check(ready_count==0,'fragmented READY waits for full frame')
chunk=frame:sub(6);reader.fn()
check(ready_count==1 and not rpc.handshaking,'READY publishes queued current state once')
reader.fn()
check(#rpc.tx_queue==0,'partial activity writes finish')
reply={evt='READY'};chunk=frame;reader.fn()
check(ready_count==1,'later READY does not republish')
rpc:close();check(#rpc.tx_queue==0,'close clears queued writes')
send_mode='again';rpc:handshake();reader=timers[#timers];clock=clock+4;reader.fn()
check(rpc.socket==nil and ipc.rpc_retry_delay()==1,'handshake deadline disconnects and schedules backoff')
clock=clock+1;rpc:handshake();reader=timers[#timers];clock=clock+4;reader.fn()
check(ipc.rpc_retry_delay()==2,'repeated handshake failure doubles backoff')

local windows = assert(loadfile(root..'/modules/ipc_transport_windows.lua'))()({
    helpers={byte=string.byte,floor=math.floor,format=string.format,log_verbose=noop},
})
local pending_write, pending_read = true, true
local pipe = windows.create({
    open=function() return true end,close=noop,available=function() return 2 end,
    write=function()
        if pending_write then pending_write=false;return nil,'again' end
        return 2
    end,
    read=function()
        if pending_read then pending_read=false;return nil,'again' end
        return '{}'
    end,
})
pipe:connect()
local count, outcome = pipe:send_some('{}',0)
check(count==nil and outcome=='again','pending Windows write yields without waiting')
check(pipe:send_some('{}',0)==2,'Windows write completion reports bytes once')
check(pipe:read_available()=='','pending Windows read preserves connection')
check(pipe:read_available()=='{}','Windows read completion returns bytes')

-- The reconnect scheduler sleeps until the exact next retry, without a
-- periodic watchdog waking throughout the backoff window.
local events, properties, keys = {}, {}, {}
local reconnect_delay, connects, aborts = 8, 0, 0
mp.register_event=function(name,fn) events[name]=fn end
mp.observe_property=function(name,_,fn) properties[name]=fn end
mp.add_key_binding=function(_,name,fn) keys[name]=fn end
mp.osd_message=noop
local presence_rpc={
    handshake=function() connects=connects+1;reconnect_delay=16;return false end,
    set_activity=function() return false end,shutdown_fast=noop,
}
local presence_shared={enabled=true,tmdb_lookup_generation=0}
assert(loadfile(root..'/modules/presence.lua'))()({
    artwork={presence_image=function() return 'fallback' end},
    cache={load_poster_cache=noop,save_poster_cache=noop},
    config={ACTIVITY_WATCHING=3,FALLBACK_IMG='fallback',FALLBACK_TXT='fallback',
        KEY_TOGGLE='D',SMALL_IDLE='',SMALL_PAUSE='',SMALL_PLAY='',is_ignored_path=function() return false end},
    filename={meaningful_chapter_title=noop,tagged_title=noop},
    helpers={floor=math.floor,get_property=mp.get_property,get_property_bool=function() return false end,
        get_property_number=function() return 0 end,log_info=noop,log_warn=noop,
        time=function() return clock end,truncate_utf8=function(s) return s end},
    ipc={RPC=presence_rpc,rpc_retry_delay=function() return reconnect_delay end},
    metadata={clear_title_state=noop,lookup_poster=noop},
    tmdb_requests={tmdb_abort_inflight_requests=function() aborts=aborts+1 end},
},presence_shared)
presence_rpc.on_disconnect()
local reconnect=timers[#timers]
check(reconnect.delay==8,'reconnect timeout uses backoff deadline')
local before=#timers;presence_rpc.on_disconnect()
check(#timers==before,'disconnects share one reconnect timeout')
reconnect.fn()
check(connects==1 and timers[#timers].delay==16,'failed retry schedules the new deadline')
keys['discord-mpv-rpc-toggle']()
check(aborts==1 and presence_shared.tmdb_lookup_generation==1,'disabling invalidates and aborts metadata requests')

-- No usable transport should disable presence without dereferencing nil IPC.
local main_chunk=assert(loadfile(root..'/main.lua'))
local captured_state, presence_loaded
mp.get_script_directory=function() return root end
loadfile=function(path)
    local name=assert(path:match('[/\\]modules[/\\](.+)%.lua$'))
    return function()
        return function(_,state)
            captured_state=state
            if name=='config' then state.enabled=true end
            if name=='ipc_transport' or name=='ipc' then return nil end
            if name=='presence' then presence_loaded=true end
            return {}
        end
    end
end
local supported, startup_error=pcall(main_chunk)
loadfile=real_loadfile
check(supported,'missing IPC transport does not crash startup: '..tostring(startup_error))
check(captured_state.enabled==false and not presence_loaded,
    'missing IPC transport disables presence and skips its event handlers')
check(type(captured_state.tick)=='function','disabled runtime provides a safe metadata tick')

-- A full season update sweeps expiry once and keeps the cache bounded.
local batch_state, expiry_reads, save_timers = {}, 0, 0
mp.add_timeout=function() save_timers=save_timers+1;return {kill=noop} end
local batch_cache=real_loadfile(root..'/modules/cache.lua')()({
    config={PATH_SEP='/',PID=123},helpers={SCRIPT_DIR=root,format=string.format,
        time=function() expiry_reads=expiry_reads+1;return 1000 end,log_verbose=noop},
},batch_state)
for n=1,1000 do batch_state.poster_cache['old-'..n]={expires_at=2000+n} end
batch_state.poster_cache.expired={expires_at=999}
local entries={}
for n=1,20 do entries['new-'..n]={poster='/new.jpg',expires_at=5000+n} end
batch_cache.remember_posters(entries)
check(expiry_reads==1021,'batch prunes expiry once across existing and new records')
check(save_timers==1,'batch schedules one persistent save')
local total=0;for _ in pairs(batch_state.poster_cache) do total=total+1 end
check(total==1000 and batch_state.poster_cache.expired==nil,'batch respects size and expiry limits')
check(batch_state.poster_cache['new-1']~=nil and batch_state.poster_cache['new-20']~=nil,
    'batch retains longer-lived season records')
batch_cache.remember_posters({})
check(expiry_reads==1021 and save_timers==1,'empty batch does no cache work')

-- Directory parsing is shared across episode paths, including a bounded cache.
local normalized_dirs=0
local normalization=real_loadfile(root..'/modules/title_normalize.lua')()()
local original_trim=normalization.trim
normalization.trim=function(value) normalized_dirs=normalized_dirs+1;return original_trim(value) end
local filenames=real_loadfile(root..'/modules/filename.lua')()({
    helpers={floor=math.floor,get_property=noop,get_property_number=noop,
        gsub=string.gsub,match=string.match,sub=string.sub},
    database={parsing=real_loadfile(root..'/db/parsing_keywords.lua')()},title_normalize=normalization,
},{})
local dir_title,dir_year=filenames.directory_context('/media/Show (2024)/S01E01.mkv')
check(dir_title=='Show' and dir_year=='2024','directory cache preserves title and year')
local first_dir_calls=normalized_dirs
filenames.directory_context('/media/Show (2024)/S01E02.mkv')
check(normalized_dirs==first_dir_calls,'episodes share parsed directory metadata')
for n=1,256 do filenames.directory_context('/media/Other '..n..' (2020)/file.mkv') end
local before_evicted=normalized_dirs
filenames.directory_context('/media/Show (2024)/S01E03.mkv')
check(normalized_dirs>before_evicted,'directory cache evicts entries at its bound')

-- One service status governs every image, with failure expiry and recovery.
local artwork_state={poster_cache={},tick=noop}
local probes,status=0,503
mp.get_time=function() return clock end
local images=real_loadfile(root..'/modules/artwork.lua')()({
    cache={load_poster_cache=noop,persistent_entry_expired=function(e) return e.expires_at<=clock end,
        remember_poster=function(k,v) artwork_state.poster_cache[k]=v end},
    config={FALLBACK_IMG='fallback',POSTER_FIT='contain'},
    helpers={gsub=string.gsub,time=function() return clock end,log_verbose=noop,log_warn=noop},
    http={url_encode=function(s) return s end,run_async=function(fn) fn() end,
        curl_request=function() probes=probes+1;return '',status,false end},
},artwork_state)
images.probe_wsrv('https://image.test/one.jpg')
check(images.presence_image('https://image.test/two.jpg')=='https://image.test/two.jpg',
    'service failure applies raw fallback to every poster')
images.probe_wsrv('https://image.test/two.jpg')
check(probes==1,'known service status skips another image probe')
clock=clock+601;status=200;images.probe_wsrv('https://image.test/two.jpg')
check(probes==2 and images.presence_image('https://image.test/two.jpg'):find('https://wsrv.nl/',1,true)==1,
    'expired service failure reprobes and restores contained artwork')
images.probe_wsrv('https://image.test/three.jpg')
check(probes==2,'service recovery is shared with subsequent posters')

mp=saved_mp
return passed
end
