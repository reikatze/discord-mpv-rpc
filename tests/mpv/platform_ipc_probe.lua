local msg=require 'mp.msg'
local utils=require 'mp.utils'
local options=require 'mp.options'
local o={mode='success'}
options.read_options(o,'mpv-native-ipc')
local source=debug.getinfo(1,'S').source
local tests_dir=assert(source:match('^@(.+)[/\\]mpv[/\\][^/\\]+$'))
local root=tests_dir=='tests' and '.' or tests_dir:gsub('[/\\]tests$','')
local expected=assert(os.getenv('MPV_RPC_TEST_PLATFORM'))
local completed=false
local function fail(reason)
    if completed then return end
    completed=true;msg.error('MPV_TEST_FAILURE native IPC: '..tostring(reason));mp.commandv('quit',1)
end
local function finish()
    if completed then return end
    completed=true;msg.info('MPV_TEST_NATIVE_IPC_OK '..expected..' '..o.mode);mp.commandv('quit',0)
end
local ok,err=xpcall(function()
    assert(rawget(_G,'jit'),'native IPC requires LuaJIT')
    local ffi=require 'ffi';assert(ffi.os==expected,'wrong native platform')
    local modules={config={CLIENT_ID='native-ipc-test',PID=123},helpers={
        byte=string.byte,char=string.char,floor=math.floor,format=string.format,
        format_json=utils.format_json,parse_json=utils.parse_json,sub=string.sub,
        log_info=msg.info,log_verbose=msg.verbose,log_warn=msg.warn,log_error=msg.error,
    }}
    for _,name in ipairs({'ipc_transport_unix','ipc_transport_windows','ipc_transport','ipc'}) do
        modules[name]=assert(loadfile(root..'/modules/'..name..'.lua'))()(modules,{})
    end
    local ipc=assert(modules.ipc);local rpc=ipc.RPC
    assert(rpc.unix==(expected~='Windows'),'wrong transport selected')
    local nonce,ready_count,error_count,disconnect_count=nil,0,0,0
    local started=mp.get_time()
    local write_started
    local function publish()
        local sent
        sent,nonce=rpc:set_activity({details=o.mode=='write-timeout' and string.rep('x',512*1024) or 'Native IPC test'},
            {mode=o.mode})
        assert(sent,'could not queue activity')
    end
    rpc.on_ready=function()
        ready_count=ready_count+1
        assert(ipc.rpc_retry_delay()==0,'successful READY did not reset backoff')
        if o.mode=='write-timeout' then write_started=mp.get_time() end
        publish()
    end
    rpc.on_response=function(response,pending)
        local valid,pending_err=pcall(function()
            assert(pending and pending.command=='SET_ACTIVITY' and pending.nonce==nonce)
            assert(response.nonce==nonce and pending.context.mode==o.mode)
            if o.mode=='rejection' then assert(error_count==1,'rejection was not handled') end
            if o.mode=='reconnect' then assert(ready_count==2 and disconnect_count==1,'reconnect was not completed') end
            assert(o.mode=='success' or o.mode=='rejection' or o.mode=='reconnect','unexpected acknowledgement')
        end)
        if not valid then fail(pending_err);return end
        rpc:shutdown_fast();finish()
    end
    rpc.on_error=function(_,pending)
        if o.mode~='rejection' or error_count~=0 or not pending or pending.nonce~=nonce then
            fail('unexpected rejection');return
        end
        error_count=error_count+1
        assert(rpc.pending[pending.nonce]==nil,'rejected command remained pending')
        publish()
    end
    rpc.on_disconnect=function()
        disconnect_count=disconnect_count+1
        local valid,disconnect_err=pcall(function()
            assert(rpc.socket==nil and next(rpc.pending)==nil and #rpc.tx_queue==0,'disconnect did not clear state')
            assert(ipc.rpc_retry_delay()>0,'disconnect did not set backoff')
            if o.mode=='handshake-timeout' then
                assert(ready_count==0 and mp.get_time()-started>=3,'handshake did not respect deadline');finish()
            elseif o.mode=='write-timeout' then
                assert(write_started and mp.get_time()-write_started>=3,'write did not respect deadline');finish()
            elseif o.mode=='disconnect' then
                assert(ready_count==1,'disconnect happened before READY');finish()
            elseif o.mode=='reconnect' then
                assert(disconnect_count==1,'reconnect failed repeatedly')
                mp.add_timeout(ipc.rpc_retry_delay(),function() rpc:handshake() end)
            else error('unexpected disconnect') end
        end)
        if not valid then fail(disconnect_err) end
    end
    assert(rpc:handshake()==false,'handshake must return before READY')
    mp.add_timeout(12,function() fail('native IPC scenario timed out') end)
end,debug.traceback)
if not ok then fail(err) end
