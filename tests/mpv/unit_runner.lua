local msg = require 'mp.msg'
local real_mp = mp
local source = debug.getinfo(1, 'S').source
local tests_dir = assert(source:match('^@(.+)[/\\]mpv[/\\][^/\\]+$'))
local unit_file = tests_dir .. '/run.lua'

local ok, err = xpcall(function()
    dofile(unit_file)
end, debug.traceback)

-- tests/run.lua installs a deliberately small mp mock. Restore the real mpv
-- API before reporting the result or terminating this mpv process.
_G.mp = real_mp

if not ok then
    msg.error('MPV_TEST_FAILURE unit suite: ' .. tostring(err))
    real_mp.commandv('quit', 1)
    return
end

msg.info('MPV_TEST_UNIT_OK')
real_mp.commandv('quit', 0)
