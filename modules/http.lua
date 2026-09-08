-- curl subprocesses, coroutine execution, and URL encoding.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local IS_WINDOWS = modules.config.IS_WINDOWS
local utils = modules.config.utils
local byte = modules.helpers.byte
local create_co = modules.helpers.create_co
local format = modules.helpers.format
local gsub = modules.helpers.gsub
local log_error = modules.helpers.log_error
local match = modules.helpers.match
local resume_co = modules.helpers.resume_co
local running_co = modules.helpers.running_co
local sub = modules.helpers.sub
local yield_co = modules.helpers.yield_co

-- curl helper
----------------------------------------------------------------
local function split_curl(stdout)
    if not stdout or stdout == '' then
        return nil, 0
    end
    stdout = gsub(stdout, '\r\n', '\n')
    stdout = gsub(stdout, '\r', '\n')
    local body, code = match(stdout, '^(.*)\n(%d%d%d)\n?$')
    if not code then
        code = match(stdout, '(%d%d%d)\n?$')
        if code then
            body = sub(stdout, 1, #stdout - #code)
            body = gsub(body, '\n+$', '')
        else
            body = stdout
            code = 0
        end
    end
    return body, tonumber(code) or 0
end

local function curl_request(url, extra)
    local args = {
        'curl', '-sS', '--max-time', extra and extra.timeout or '6',
        '-w', '\n%{http_code}',
    }
    if extra and extra.headers then
        for i = 1, #extra.headers do
            args[#args + 1] = '-H'
            args[#args + 1] = extra.headers[i]
        end
    end
    if extra and extra.discard_body then
        -- Keep the HTTP response body out of Lua. This is used for the wsrv
        -- availability probe so a successful image GET does not allocate a
        -- potentially large poster in memory.
        args[#args + 1] = '-o'
        args[#args + 1] = IS_WINDOWS and 'NUL' or '/dev/null'
    end
    args[#args + 1] = url

    local function finish(res)
        if not res then
            return nil, 0, true
        end

        -- `res.status` is the curl process exit status in mpv's subprocess
        -- result. The HTTP status is independently emitted by %{http_code}
        -- and parsed from stdout. Do not confuse the two: HTTP 000 is not
        -- itself proof of a transport failure, and a curl exit code of 0 is
        -- not an HTTP status.
        local process_status = tonumber(res.status)
        local process_error = process_status ~= nil and process_status ~= 0
        local body, http_status = split_curl(res.stdout or '')
        if process_status == nil then
            process_error = true
        end
        return body, http_status, process_error
    end

    local co = running_co()
    if co then
        local done
        local handle
        handle = mp.command_native_async({
            name           = 'subprocess',
            args           = args,
            playback_only  = false,
            capture_stdout = true,
            capture_stderr = false,
        }, function(_, res)
            if done then return end
            done = true
            if extra and extra.on_async_complete then
                pcall(extra.on_async_complete, handle)
            end
            local body, status, transport_error = finish(res)
            local ok, err = resume_co(co, body, status, transport_error)
            if not ok then
                log_error('coroutine: ' .. tostring(err))
            end
        end)
        if handle and extra and extra.on_async_handle then
            pcall(extra.on_async_handle, handle)
        end
        return yield_co()
    end

    return finish(utils.subprocess{ args = args, cancellable = false })
end

local function curl_get(url, control)
    return curl_request(url, {
        headers = { 'Accept: application/json' },
        on_async_handle = control and control.on_async_handle or nil,
        on_async_complete = control and control.on_async_complete or nil,
    })
end

local function run_async(fn)
    local co = create_co(fn)
    local ok, err = resume_co(co)
    if not ok then
        log_error('coroutine: ' .. tostring(err))
    end
end

local function url_encode(s)
    return (gsub(s, '([^%w%-%.%_%~ ])', function(c)
        return format('%%%02X', byte(c))
    end):gsub(' ', '%%20'))
end

return {
    curl_get = curl_get,
    curl_request = curl_request,
    run_async = run_async,
    url_encode = url_encode,
}
end
