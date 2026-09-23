-- Select and install the native Discord IPC transport.
return function(modules)
local unix = package.config:sub(1, 1) == '/'
local implementation = unix
    and modules.ipc_transport_unix or modules.ipc_transport_windows
local transport = implementation.native()
if not transport then
    transport = unix and implementation.luasocket()
        or implementation.file_fallback()
end
if not transport then
    modules.helpers.log_error('need LuaJIT or LuaSocket')
    return nil
end

local function install(target)
    target.unix = transport.unix
    for _, name in ipairs({
        'connect', 'read_available', 'send_raw', 'recv_raw', 'close',
    }) do
        target[name] = transport[name]
    end
end

return {install = install}
end
