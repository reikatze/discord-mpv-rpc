mp.add_timeout(120,function() mp.msg.error('MPV_TEST_FAILURE suite deadline');mp.commandv('quit',1) end)
local suite_ok,suite_error=xpcall(function()
local utils=require 'mp.utils'
local ffi=require 'ffi'
local script_dir=mp.get_script_directory() or assert(debug.getinfo(1,'S').source:match('^@(.+)[/\\][^/\\]+$'))
script_dir=utils.join_path(utils.getcwd(),script_dir)
local work=assert(os.getenv('MPV_TEST_WORK'),'MPV_TEST_WORK is required')
local executable=assert(os.getenv('MPV_BIN'),'MPV_BIN is required')
local expected=assert(os.getenv('MPV_RPC_TEST_PLATFORM'),'MPV_RPC_TEST_PLATFORM is required')
assert(ffi.os==expected,'unexpected native test platform')
local server=assert(loadfile(script_dir..'/ipc_test_server.lua'))()(ffi)
local modes={'success','rejection','disconnect','reconnect','handshake-timeout','write-timeout'}
local mode,index,handle,timer,deadline,connected,connections
local rx,tx,fragment,rejected,pong='',{},nil,false,false
local finished=false
local child_log
local function fail(reason)
    if finished then return end
    if child_log then
        local log=io.open(child_log,'rb')
        if log then reason=tostring(reason)..'\nChild mpv log:\n'..log:read('*a');log:close() end
    end
    finished=true
    if timer then timer:kill() end
    mp.msg.error('MPV_TEST_FAILURE native IPC runner: '..tostring(reason))
    if handle then mp.abort_async_command(handle);handle=nil end
    server.close();mp.commandv('quit',1)
end
local function word(n)
    return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
local function frame(op,body) return word(op)..word(#body)..body end
local function queue(data) tx[#tx+1]={data=data,offset=0} end
local ack_nonce
local function ack() queue(frame(1,assert(utils.format_json({nonce=ack_nonce})))) end
local function incoming(op,body)
    local value=op==0 or op==1
    value=value and assert(utils.parse_json(body)) or nil
    if op==0 then
        assert(value.client_id=='native-ipc-test','wrong handshake client')
        if mode=='handshake-timeout' then return end
        local ready=frame(1,'{"evt":"READY"}')
        queue(ready:sub(1,5));fragment={at=mp.get_time()+0.4,data=ready:sub(6)}
    elseif op==1 then
        assert(value.cmd=='SET_ACTIVITY' and type(value.nonce)=='string','invalid activity')
        ack_nonce=value.nonce
        if mode=='disconnect' or (mode=='reconnect' and connections==1) then
            server.disconnect();connected=false;rx='';tx={};fragment=nil
        elseif mode=='rejection' and not rejected then
            rejected=true
            queue(frame(1,assert(utils.format_json({evt='ERROR',nonce=value.nonce,data={code=4000,message='test rejection'}}))))
        else
            queue(frame(3,'test-ping'));pong=false
        end
    elseif op==4 then
        assert(body=='test-ping','incorrect PONG');pong=true;ack()
    else error('unexpected client opcode '..op) end
end
local function u32(s,p)
    local a,b,c,d=s:byte(p,p+3);return a+b*256+c*65536+d*16777216
end
local function poll()
    if server.accept() then connected=true;connections=connections+1 end
    if fragment and mp.get_time()>=fragment.at then queue(fragment.data);fragment=nil end
    if connected then
        -- Deliberately stop reading after READY to force a blocked client write.
        local stop_read=mode=='write-timeout' and #tx==0 and not fragment and rx=='handshake-complete'
        if not stop_read then
            for _=1,16 do
                local data=server.read()
                if data==nil then connected=false;server.disconnect();break end
                if data=='' then break end
                rx=rx..data
                while #rx>=8 do
                    local op,size=u32(rx,1),u32(rx,5)
                    assert(size<=1024*1024,'oversized client frame')
                    if #rx<8+size then break end
                    local body=rx:sub(9,8+size);rx=rx:sub(9+size)
                    incoming(op,body)
                    if mode=='write-timeout' and op==0 then rx='handshake-complete';break end
                    if not connected then break end
                end
                if mode=='write-timeout' or not connected then break end
            end
        end
        for _=1,16 do
            local item=tx[1];if not item or not connected then break end
            local count,err=server.write(item.data,item.offset)
            if count then
                item.offset=item.offset+count
                if item.offset==#item.data then table.remove(tx,1) end
            elseif err=='again' then break
            else error('server write failed') end
        end
    end
    if deadline and mp.get_time()>deadline then error('native scenario timed out: '..mode) end
end
local function next_case()
    if finished then return end
    index=(index or 0)+1
    if index>#modes then
        finished=true
        server.close();mp.msg.info('MPV_TEST_NATIVE_SUITE_OK '..expected);mp.commandv('quit',0);return
    end
    mode=modes[index];connections=0;connected=false;rx='';tx={};fragment=nil;rejected=false;pong=false
    child_log=work..'/native-'..mode..'.log'
    deadline=mp.get_time()+15
    timer=mp.add_periodic_timer(0.02,function()
        local ok,err=xpcall(poll,debug.traceback);if not ok then fail(err) end
    end)
    handle=mp.command_native_async({name='subprocess',playback_only=false,capture_stdout=true,capture_stderr=true,
        args={executable,'--no-config','--load-scripts=no','--idle=yes','--vo=null','--ao=null','--terminal=yes',
            '--log-file='..child_log,
            '--script='..script_dir..'/platform_ipc_probe.lua','--script-opts=mpv-native-ipc-mode='..mode}},function(success,result)
        if finished then return end
        handle=nil;timer:kill();server.disconnect();connected=false
        local log=(result and result.stdout or '')..(result and result.stderr or '')
        if not success or not result or result.status~=0 or log:find('MPV_TEST_FAILURE',1,true)
            or not log:find('MPV_TEST_NATIVE_IPC_OK '..expected..' '..mode,1,true) then
            fail(mode..' failed:\n'..log);return
        end
        if (mode=='success' or mode=='rejection' or mode=='reconnect') and not pong then
            fail('client did not answer native PING');return
        end
        mp.msg.info('native IPC '..mode..': ok')
        mp.add_timeout(0,next_case)
    end)
end
mp.add_timeout(0,next_case)

end,debug.traceback)
if not suite_ok then mp.msg.error('MPV_TEST_FAILURE '..tostring(suite_error));mp.commandv('quit',1) end
