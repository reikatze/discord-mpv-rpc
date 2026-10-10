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
local season_requests, episode_requests=0,0
local episode = assert(loadfile(root..'/modules/tmdb_episode.lua'))()({
    config={TMDB_EPISODE_LOOKUP=true,TMDB_KEY='key',TMDB_LANG='en-US',TMDB_POSITIVE_CACHE_TTL=60*86400},
    cache={persistent_entry_expired=function(entry) return entry.expires_at and entry.expires_at<=clock end,
        remember_poster=function(key,value) poster_shared.poster_cache[key]=value end,schedule_poster_cache_save=noop},
    helpers={format=string.format,time=function() return clock end,log_info=noop,log_verbose=noop,log_warn=noop},
    http={url_encode=function(s) return s end},
    tmdb_requests={tmdb_lookup_cancelled=function() return false end,tmdb_get_json_cached=function(url)
        if url:find('/episode/',1,true) then episode_requests=episode_requests+1;return nil,'not_found' end
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

-- A fragmented READY response is consumed by timer callbacks, never recv_raw.
local reply, chunk, writes, closes, ready_count = nil, '', {}, 0, 0
local send_mode='again'
local ipc = assert(loadfile(root..'/modules/ipc.lua'))()({
    config={CLIENT_ID='test',PID=1},helpers={byte=string.byte,char=string.char,floor=math.floor,
        sub=string.sub,format_json=function(v) return type(v)=='string' and '"'..v..'"' or '{}' end,
        parse_json=function() return reply end,log_error=noop,log_info=noop,log_verbose=noop,log_warn=noop},
    ipc_transport={install=function(rpc)
        rpc.connect=function(self) self.socket=true;return true end
        rpc.close=function(self) self.socket=nil;closes=closes+1 end
        rpc.recv_raw=function() error('blocking receive called') end
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

mp=saved_mp
return passed
end
