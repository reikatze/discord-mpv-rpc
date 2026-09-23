local msg = require 'mp.msg'
local utils = require 'mp.utils'

local source = debug.getinfo(1, 'S').source
local tests_dir = assert(source:match('^@(.+)[/\\]mpv[/\\][^/\\]+$'))
local root = tests_dir == 'tests' and '.' or tests_dir:gsub('[/\\]tests$', '')
local expected_os = assert(os.getenv('MPV_RPC_TEST_PLATFORM'),
    'MPV_RPC_TEST_PLATFORM is required')

local function fail(reason)
    msg.error('MPV_TEST_FAILURE native IPC: ' .. tostring(reason))
    mp.commandv('quit', 1)
end

local ok, err = xpcall(function()
    assert(rawget(_G, 'jit'), 'the native IPC probe requires LuaJIT')
    local ffi = require 'ffi'
    assert(ffi.os == expected_os,
        string.format('expected ffi.os=%s, got %s', expected_os, ffi.os))

    local ipc_factory = assert(loadfile(root .. '/modules/ipc.lua'))()
    local ipc = assert(ipc_factory({
        config = {CLIENT_ID = 'native-ipc-test', PID = 123},
        helpers = {
            byte = string.byte,
            char = string.char,
            floor = math.floor,
            format = string.format,
            format_json = utils.format_json,
            log_error = msg.error,
            log_info = msg.info,
            log_verbose = msg.verbose,
            log_warn = msg.warn,
            parse_json = utils.parse_json,
            sub = string.sub,
        },
    }, {}))

    local expect_unix = expected_os ~= 'Windows'
    assert(ipc.RPC.unix == expect_unix, 'selected the wrong IPC transport')
    assert(ipc.RPC:handshake(), 'Discord IPC handshake failed')

    ipc.RPC.on_response = function(response, pending)
        if not pending or pending.command ~= 'SET_ACTIVITY'
            or response.nonce ~= pending.nonce then
            return fail('activity acknowledgement did not match its request')
        end
        msg.info('MPV_TEST_NATIVE_IPC_OK ' .. expected_os)
        ipc.RPC:shutdown_fast()
        mp.commandv('quit', 0)
    end

    local sent = ipc.RPC:set_activity({details = 'Native IPC test'})
    assert(sent, 'activity frame could not be sent')
    mp.add_timeout(8, function()
        fail('timed out waiting for the activity acknowledgement')
    end)
end, debug.traceback)

if not ok then fail(err) end
