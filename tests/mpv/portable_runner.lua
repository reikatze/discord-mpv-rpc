mp.add_timeout(120,function() mp.msg.error('MPV_TEST_FAILURE suite deadline');mp.commandv('quit',1) end)
local suite_ok,suite_error=xpcall(function()
-- Runs the same real mpv lifecycle cases on Linux, macOS, and Windows.
local utils=require 'mp.utils'
local script_dir=mp.get_script_directory() or assert(debug.getinfo(1,'S').source:match('^@(.+)[/\\][^/\\]+$'))
script_dir=utils.join_path(utils.getcwd(),script_dir)
local root=script_dir:gsub('[/\\]tests[/\\]mpv$','')
local executable=assert(os.getenv('MPV_BIN'))
local media=assert(os.getenv('MPV_TEST_MEDIA'))
local work=assert(os.getenv('MPV_TEST_WORK'))
local ffmpeg=os.getenv('FFMPEG_BIN')
if ffmpeg=='' then ffmpeg=nil end
local sep='/'
local server_handle,child_handle,case_timer
local child_log
local completed=false
local function cleanup()
    if server_handle then mp.abort_async_command(server_handle);server_handle=nil end
    if child_handle then mp.abort_async_command(child_handle);child_handle=nil end
end
local function fail(reason)
    if completed then return end
    if child_log then
        local log=io.open(child_log,'rb')
        if log then reason=tostring(reason)..'\nChild mpv log:\n'..log:read('*a');log:close() end
    end
    completed=true;cleanup();mp.msg.error('MPV_TEST_FAILURE portable runner: '..tostring(reason));mp.commandv('quit',1)
end
local function copy(path)
    local input=assert(io.open(media,'rb'));local output=assert(io.open(path,'wb'))
    while true do local data=input:read(65536);if not data then break end;assert(output:write(data)) end
    input:close();assert(output:close())
end
local scene=work..sep..'[Judas] Dragon Ball Daima - S01E04v2.mkv'
local movie=work..sep..'Birdman (or the Unexpected Virtue of Ignorance) (2014) 1080p BluRay.mkv'
local ignored=work..sep..'private.mkv'
copy(scene);copy(movie);copy(ignored)
local config=work..'/config'
local f=assert(io.open(config..'/script-opts/discord-mpv-rpc.conf','wb'))
f:write('enabled=yes\ntmdb_local_index=no\ntmdb_api_key=ignored-test-key\nignored_paths='..assert(utils.format_json({work}))..'\n');f:close()
local probe='--script='..script_dir..'/probe.lua'
local main={'--script='..root..'/main.lua','--script-opts=discord-mpv-rpc-enabled=no,discord-mpv-rpc-tmdb_local_index=no'}
local cases={
    {name='unit',marker='MPV_TEST_UNIT_OK',args={'--idle=yes','--script='..script_dir..'/unit_runner.lua'}},
    {name='idle',marker='MPV_TEST_IDLE_OK',main=true,args={'--idle=yes',probe,'--script-opts-append=mpv-rpc-test-mode=idle'}},
    {name='playback',marker='MPV_TEST_PLAYBACK_OK',main=true,args={'--frames=3',probe,'--script-opts-append=mpv-rpc-test-mode=playback',media}},
    {name='scene filename',marker='MPV_TEST_FILENAME_OK',main=true,args={'--frames=3',probe,'--script-opts-append=mpv-rpc-test-mode=filename','--script-opts-append=mpv-rpc-test-expected_title=Dragon Ball Daima','--script-opts-append=mpv-rpc-test-expected_tv=yes','--script-opts-append=mpv-rpc-test-expected_season=1','--script-opts-append=mpv-rpc-test-expected_episode=4',scene}},
    {name='movie filename',marker='MPV_TEST_FILENAME_OK',main=true,args={'--frames=3',probe,'--script-opts-append=mpv-rpc-test-mode=filename','--script-opts-append=mpv-rpc-test-expected_title=Birdman (or the Unexpected Virtue of Ignorance)','--script-opts-append=mpv-rpc-test-expected_year=2014',movie}},
    {name='ignored path',marker='MPV_TEST_PLAYBACK_OK',excluded=true,args={'--config-dir='..config,'--config=yes','--length=2','--script='..root..'/main.lua',probe,'--script-opts-append=mpv-rpc-test-mode=playback',ignored}},
    {name='presence toggle',marker='MPV_TEST_TOGGLE_OK',main=true,args={'--idle=yes',probe,'--script-opts-append=mpv-rpc-test-mode=toggle'}},
}
local port=38000+utils.getpid()%1000
if ffmpeg then cases[#cases+1]={name='network stream',marker='MPV_TEST_STREAM_OK',stream=true,excluded=true,args={
    '--length=2','--script='..root..'/main.lua',probe,
    '--script-opts=discord-mpv-rpc-enabled=yes,discord-mpv-rpc-tmdb_local_index=no,discord-mpv-rpc-tmdb_api_key=stream-test-key',
    '--script-opts-append=mpv-rpc-test-mode=stream','http://127.0.0.1:'..port..'/live.ts'}} end
local index=0
local function next_case()
    index=index+1
    if index>#cases then
        completed=true;mp.msg.info('MPV_TEST_PORTABLE_SUITE_OK '..#cases..' cases');mp.commandv('quit',0);return
    end
    local test=cases[index]
    child_log=work..'/portable-'..index..'.log'
    local args={executable,'--no-config','--load-scripts=no','--vo=null','--ao=null','--terminal=yes','--msg-color=no','--msg-level=main=v'}
    args[#args+1]='--log-file='..child_log
    if test.main then for _,arg in ipairs(main) do args[#args+1]=arg end end
    for _,arg in ipairs(test.args) do args[#args+1]=arg end
    local function launch()
        if completed then return end
        case_timer=mp.add_timeout(20,function() fail(test.name..' timed out') end)
        child_handle=mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stdout=true,capture_stderr=true},function(success,result)
            child_handle=nil;case_timer:kill()
            if server_handle then mp.abort_async_command(server_handle);server_handle=nil end
            local log=(result and result.stdout or '')..(result and result.stderr or '')
            if not success or not result or result.status~=0 or log:find('MPV_TEST_FAILURE',1,true)
                or log:find('Lua error',1,true) or not log:find(test.marker,1,true) then fail(test.name..' failed:\n'..log);return end
            if test.excluded and (log:find('cleaned title=',1,true) or log:find('connected to Discord',1,true)
                or log:find('Discord unavailable',1,true)) then fail(test.name..' started excluded work:\n'..log);return end
            mp.msg.info(test.name..': ok');mp.add_timeout(0,next_case)
        end)
    end
    if test.stream then
        server_handle=mp.command_native_async({name='subprocess',playback_only=false,capture_stdout=true,capture_stderr=true,
            args={ffmpeg,'-hide_banner','-loglevel','error','-re','-stream_loop','-1','-i',media,'-map','0:v:0','-c:v','copy','-an','-f','mpegts','-listen','1','http://127.0.0.1:'..port}},function() end)
        mp.add_timeout(0.5,launch)
    else launch() end
end
mp.register_event('shutdown',cleanup)
mp.add_timeout(0,next_case)

end,debug.traceback)
if not suite_ok then mp.msg.error('MPV_TEST_FAILURE '..tostring(suite_error));mp.commandv('quit',1) end
