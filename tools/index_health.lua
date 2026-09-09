-- Shared manifest checks; full validation runs only in the background worker.
return function(utils)
    local M={}
    local ffi
    if rawget(_G,'jit') then
        local ok,loaded=pcall(require,'ffi')
        if ok then ffi=loaded end
    end
    local byte_ptr=ffi and ffi.typeof('const uint8_t*') or nil
    function M.base(root,meta,media)
        return root..meta.generation..(meta.layout=='flat' and '-' or '/')..media
    end
    function M.load(root)
        local f=io.open(root..'current.json','rb') or io.open(root..'current.json.bak','rb')
        if not f then return nil end
        local raw=f:read(16385);f:close()
        if not raw or #raw>16384 then return nil end
        local ok,m=pcall(utils.parse_json,raw)
        if not ok or type(m)~='table' or m.schema~=1 or type(m.generation)~='string'
            or #m.generation~=33 or not m.generation:match('^g%x+$')
            or (m.layout~=nil and m.layout~='flat') or type(m.counts)~='table'
            or type(m.export_date)~='string' then return nil end
        local y,mo,d=m.export_date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        y,mo,d=tonumber(y),tonumber(mo),tonumber(d)
        if not y or y<1970 or y>2100 or mo<1 or mo>12 then return nil end
        local function leap(n) return n%4==0 and (n%100~=0 or n%400==0) end
        local months={31,leap(y) and 29 or 28,31,30,31,30,31,31,30,31,30,31}
        if d<1 or d>months[mo] then return nil end
        local days=d-1
        for n=1970,y-1 do days=days+(leap(n) and 366 or 365) end
        for n=1,mo-1 do days=days+months[n] end
        m.exported_at=days*86400
        if m.exported_at>os.time()+86400 then return nil end
        for _,media in ipairs({'movie','tv'}) do
            local n=m.counts[media]
            if type(n)~='number' or n<1 or n%1~=0 or n>10000000 then return nil end
        end
        return m
    end
    function M.state(root)
        local f=io.open(root..'health.json','rb')
        if not f then return nil end
        local raw=f:read(4097);f:close()
        if not raw or #raw>4096 then return nil end
        local ok,state=pcall(utils.parse_json,raw)
        if not ok or type(state)~='table' or type(state.generation)~='string'
            or type(state.valid)~='boolean' or type(state.checked_at)~='number' then
            return nil
        end
        return state
    end
    function M.stale(m) return os.time()-m.exported_at>=7*86400 end
    function M.sizes(root,m)
        for _,media in ipairs({'movie','tv'}) do
            local base=M.base(root,m,media)
            local a,b=io.open(base..'.offsets','rb'),io.open(base..'.jsonl','rb')
            local good=a and b and a:seek('end')==m.counts[media]*17 and b:seek('end')>0
            if a then a:close() end;if b then b:close() end
            if not good then return false end
        end
        return true
    end
    -- Adler-32 catches same-size accidental edits, not just truncated files.
    function M.fingerprint(path)
        local f=assert(io.open(path,'rb'));local a,b,size=1,0,0
        while true do
            local s=f:read(65536);if not s then break end
            size=size+#s
            if byte_ptr then
                -- 5552 is the largest safe Adler-32 block before reduction.
                -- FFI removes per-byte string.byte and modulo calls.
                local p=ffi.cast(byte_ptr,s)
                local i=0
                while i<#s do
                    local stop=math.min(i+5552,#s)
                    while i<stop do a=a+p[i];b=b+a;i=i+1 end
                    a=a%65521;b=b%65521
                end
            else
                for i=1,#s do a=(a+s:byte(i))%65521;b=(b+a)%65521 end
            end
        end
        f:close();return {size=size,adler=b*65536+a}
    end
    function M.integrity(root,m)
        local result={}
        for _,media in ipairs({'movie','tv'}) do
            local base=M.base(root,m,media)
            for _,suffix in ipairs({'jsonl','offsets'}) do
                result[media..'.'..suffix]=M.fingerprint(base..'.'..suffix)
            end
        end
        return result
    end
    function M.valid(root,m)
        if not M.sizes(root,m) then return false end
        if type(m.integrity)=='table' then
            local got=M.integrity(root,m)
            for k,v in pairs(got) do
                local expected=m.integrity[k]
                if type(expected)~='table' or expected.size~=v.size or expected.adler~=v.adler then return false end
            end
        else
            -- Legacy snapshots: validate every record and offset before trusting them.
            for _,media in ipairs({'movie','tv'}) do
                local base=M.base(root,m,media)
                local a,b=assert(io.open(base..'.offsets','rb')),assert(io.open(base..'.jsonl','rb'))
                local ok=pcall(function()
                    for _=1,m.counts[media] do
                        assert(tonumber(a:read(17))==b:seek())
                        local line=assert(b:read('*l'));local row=utils.parse_json(line)
                        assert(type(row)=='table' and type(row[1])=='string' and type(row[2])=='table' and #row[2]<=4)
                        for _,id in ipairs(row[2]) do assert(type(id)=='number' and id>0 and id%1==0) end
                    end
                    assert(b:read(1)==nil)
                end)
                a:close();b:close();if not ok then return false end
            end
        end
        return true
    end
    return M
end
