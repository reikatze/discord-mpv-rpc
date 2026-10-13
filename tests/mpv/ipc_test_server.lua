-- CI-only Discord peer using real OS IPC. The production client is launched
-- in a separate mpv process and exercises its normal native transport.
return function(ffi)
local C = ffi.C
local server = {}
if ffi.os == 'Windows' then
    ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;
    HANDLE CreateNamedPipeW(const wchar_t*,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,void*);
    BOOL ConnectNamedPipe(HANDLE,void*);
    BOOL DisconnectNamedPipe(HANDLE);
    BOOL PeekNamedPipe(HANDLE,void*,DWORD,DWORD*,DWORD*,DWORD*);
    BOOL ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
    BOOL WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
    BOOL CloseHandle(HANDLE);
    DWORD GetLastError(void);
    ]]
    local path = '\\\\.\\pipe\\discord-ipc-0'
    local wide = ffi.new('wchar_t[?]',#path+1)
    for i=1,#path do wide[i-1]=path:byte(i) end
    -- Exclusive ownership prevents touching an existing Discord pipe. NOWAIT
    -- is used only by this small test peer; the client uses overlapped I/O.
    local handle = C.CreateNamedPipeW(wide,0x80003,1,1,4096,4096,0,nil)
    assert(handle ~= ffi.cast('HANDLE',-1),'could not create isolated test pipe')
    local count,buffer=ffi.new('DWORD[1]'),ffi.new('char[4096]')
    local connected=false
    function server.accept()
        if connected then return false end
        local result=C.ConnectNamedPipe(handle,nil)
        if result==0 and C.GetLastError()==535 then connected=true;return true end
        return false
    end
    function server.read()
        if C.PeekNamedPipe(handle,nil,0,nil,count,nil)==0 then return nil,'closed' end
        if count[0]==0 then return '', 'again' end
        if C.ReadFile(handle,buffer,math.min(4096,tonumber(count[0])),count,nil)==0 then
            return nil,'closed'
        end
        return ffi.string(buffer,count[0])
    end
    function server.write(data,offset)
        local remaining=math.min(4096,#data-offset)
        if C.WriteFile(handle,data:sub(offset+1,offset+remaining),remaining,count,nil)==0 then
            return nil,'closed'
        end
        if count[0]==0 then return nil,'again' end
        return tonumber(count[0])
    end
    function server.disconnect() C.DisconnectNamedPipe(handle);connected=false end
    function server.close() C.CloseHandle(handle) end
else
    local osx=ffi.os=='OSX'
    if osx then
        ffi.cdef[[struct test_sockaddr_un {unsigned char len;unsigned char family;char path[104];};]]
    else
        ffi.cdef[[struct test_sockaddr_un {unsigned short family;char path[108];};]]
    end
    ffi.cdef[[
    int socket(int,int,int);int bind(int,const void*,unsigned);int listen(int,int);
    int accept(int,void*,void*);int fcntl(int,int,int);int close(int);
    int recv(int,void*,size_t,int);int send(int,const void*,size_t,int);
    int setsockopt(int,int,int,const void*,unsigned);
    void (*signal(int,void (*)(int)))(int);
    ]]
    C.signal(13,ffi.cast('void (*)(int)',1))
    local bit=require 'bit'
    local function nonblocking(fd)
        local flags=C.fcntl(fd,3,0)
        assert(flags>=0 and C.fcntl(fd,4,bit.bor(flags,osx and 4 or 0x800))==0)
    end
    local path=assert(os.getenv('XDG_RUNTIME_DIR'),'XDG_RUNTIME_DIR must be an isolated test directory')..'/discord-ipc-0'
    assert(#path<(osx and 104 or 108),'test socket path too long')
    local listener=assert(tonumber(C.socket(1,1,0)))
    assert(listener>=0,'could not create test socket')
    local address=ffi.new('struct test_sockaddr_un')
    address.family=1;ffi.copy(address.path,path)
    local size=ffi.sizeof(address)
    if osx then size=2+#path+1;address.len=size end
    assert(C.bind(listener,address,size)==0,'could not bind isolated test socket')
    assert(C.listen(listener,1)==0);nonblocking(listener)
    local client,buffer=nil,ffi.new('char[4096]')
    local function again(err) return err==4 or err==11 or err==35 end
    function server.accept()
        if client then return false end
        local fd=C.accept(listener,nil,nil)
        if fd<0 then return false end
        client=tonumber(fd);nonblocking(client)
        local small=ffi.new('int[1]',1024)
        C.setsockopt(client,osx and 0xffff or 1,osx and 0x1002 or 8,small,ffi.sizeof(small))
        return true
    end
    function server.read()
        local count=C.recv(client,buffer,4096,0)
        if count>0 then return ffi.string(buffer,count) end
        if count<0 and again(ffi.errno()) then return '', 'again' end
        return nil,'closed'
    end
    function server.write(data,offset)
        local count=C.send(client,data:sub(offset+1),#data-offset,0)
        if count>0 then return tonumber(count) end
        if count<0 and again(ffi.errno()) then return nil,'again' end
        return nil,'closed'
    end
    function server.disconnect() if client then C.close(client);client=nil end end
    function server.close() server.disconnect();C.close(listener);os.remove(path) end
end
return server
end
