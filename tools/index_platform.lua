-- OS filesystem primitives through mpv's LuaJIT. No helper executables.
local ffi=require 'ffi'
local windows=ffi.os=='Windows'
local C=ffi.C
local M={}
if windows then
    ffi.cdef[[
    int MultiByteToWideChar(unsigned int,unsigned long,const char*,int,unsigned short*,int);
    int CreateDirectoryW(const unsigned short*,void*);
    void* CreateFileW(const unsigned short*,unsigned long,unsigned long,void*,unsigned long,unsigned long,void*);
    int CloseHandle(void*);
    unsigned long GetModuleFileNameW(void*,unsigned short*,unsigned long);
    int WideCharToMultiByte(unsigned int,unsigned long,const unsigned short*,int,char*,int,const char*,int*);
    ]]
    local function wide(s)
        local n=C.MultiByteToWideChar(65001,0,s,-1,nil,0);assert(n>0)
        local b=ffi.new('unsigned short[?]',n);assert(C.MultiByteToWideChar(65001,0,s,-1,b,n)>0);return b
    end
    function M.mkdir(path) C.CreateDirectoryW(wide(path),nil) end
    function M.lock(path)
        local h=C.CreateFileW(wide(path),3221225472,0,nil,4,128,nil)
        if h==ffi.cast('void*',-1) then return nil end
        return function() C.CloseHandle(h) end
    end
    function M.executable()
        local b=ffi.new('unsigned short[32768]');local n=C.GetModuleFileNameW(nil,b,32768)
        if n==0 or n>=32768 then return nil end
        local out=ffi.new('char[131072]');local len=C.WideCharToMultiByte(65001,0,b,n,out,131072,nil,nil)
        return len>0 and ffi.string(out,len) or nil
    end
else
    ffi.cdef[[int mkdir(const char*,unsigned int); int open(const char*,int,...);
    int close(int); int flock(int,int); long readlink(const char*,char*,unsigned long);]]
    function M.mkdir(path) C.mkdir(path,448) end
    function M.lock(path)
        local create=ffi.os=='OSX' and 512 or 64
        local fd=C.open(path,2+create,ffi.new('int',384))
        if fd<0 then return nil end
        if C.flock(fd,6)~=0 then C.close(fd);return nil end
        return function() C.close(fd) end
    end
    function M.executable()
        if ffi.os=='OSX' then
            ffi.cdef[[int _NSGetExecutablePath(char*,unsigned int*);]]
            local n=ffi.new('unsigned int[1]',32768);local b=ffi.new('char[32768]')
            return C._NSGetExecutablePath(b,n)==0 and ffi.string(b) or nil
        end
        local b=ffi.new('char[32768]');local n=C.readlink('/proc/self/exe',b,32768)
        return n>0 and ffi.string(b,n) or nil
    end
end
return M
