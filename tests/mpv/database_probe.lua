local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    database = '',
    expected_id = 204266,
    title = 'Trigun Stampede',
}
options.read_options(o, 'mpv-rpc-db-test')

local source = debug.getinfo(1, 'S').source
local root = assert(source:match('^@(.+)[/\\]tests[/\\]mpv[/\\][^/\\]+$'))

local function fail(message)
    msg.error('MPV_TEST_FAILURE ' .. tostring(message))
    mp.commandv('quit', 1)
end

mp.add_timeout(0, function()
    local ok, err = xpcall(function()
        assert(o.database ~= '', 'database path is required')
        local title_normalize =
            assert(loadfile(root .. '/modules/title_normalize.lua'))()()
        local index = assert(loadfile(root .. '/modules/tmdb_index.lua'))()({
            config = {
                KEY_TOGGLE_DB = '',
                TMDB_INDEX_MPV_PATH = '',
                TMDB_INDEX_ROOT = o.database,
                TMDB_KEY = '',
                TMDB_LOCAL_INDEX = true,
                utils = utils,
            },
            helpers = {
                SCRIPT_DIR = root,
                log_warn = function(message) msg.warn(message) end,
                parse_json = utils.parse_json,
            },
            title_normalize = title_normalize,
        }, {})

        assert(index._test.maintenance_enabled() == false,
            'maintenance was enabled without a TMDb API key')
        local ids = index.candidates(o.title, true)
        assert(#ids == 1 and ids[1] == o.expected_id,
            string.format('expected database ID %d, got %s',
                o.expected_id, table.concat(ids, ',')))
        msg.info('MPV_TEST_DATABASE_OK id=' .. tostring(ids[1]))
        mp.commandv('quit', 0)
    end, debug.traceback)
    if not ok then fail(err) end
end)
