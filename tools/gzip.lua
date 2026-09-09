-- Gzip framing/checksums in Lua; DEFLATE handled by the bundled LibDeflate.
return function(deflate)
    local ok, bit = pcall(require, 'bit')
    if not ok then bit = rawget(_G, 'bit32') end
    local ffi
    if rawget(_G, 'jit') then
        local ffi_ok, loaded = pcall(require, 'ffi')
        if ffi_ok then ffi = loaded end
    end
    local function arithmetic_xor(a,b)
        local n,p=0,1
        for _=1,32 do
            local x,y=a%2,b%2
            if x~=y then n=n+p end
            a=math.floor(a/2); b=math.floor(b/2); p=p*2
        end
        return n
    end
    local xor=bit and bit.bxor or arithmetic_xor
    local function unsigned(n) return n % 4294967296 end
    local crc_table={}
    for i=0,255 do
        local c=i
        for _=1,8 do
            c=c%2==1 and unsigned(xor(math.floor(c/2),3988292384)) or math.floor(c/2)
        end
        crc_table[i]=c
    end
    local crc32
    if ffi and bit and bit.band and bit.rshift then
        -- LuaJIT traces this pointer loop and performs the CRC with native
        -- 32-bit operations. The Lua string stays alive for the whole call.
        local byte_ptr=ffi.typeof('const uint8_t*')
        local band,bxor,rshift=bit.band,bit.bxor,bit.rshift
        crc32=function(s)
            local c=-1
            local p=ffi.cast(byte_ptr,s)
            for i=0,#s-1 do
                c=bxor(rshift(c,8),crc_table[band(bxor(c,p[i]),255)])
            end
            c=bxor(c,-1)
            return c<0 and c+4294967296 or c
        end
    else
        crc32=function(s)
            local c=4294967295
            for i=1,#s do
                c=unsigned(xor(math.floor(c/256),crc_table[unsigned(xor(c,s:byte(i)))%256]))
            end
            return unsigned(xor(c,4294967295))
        end
    end
    local function u32(s,p)
        local a,b,c,d=s:byte(p,p+3)
        assert(d,'truncated gzip trailer')
        return a+b*256+c*65536+d*16777216
    end
    return function(source)
        local holder = type(source)=='table' and source or nil
        local raw = holder and holder.data or source
        if holder then holder.data=nil end
        assert(type(raw)=='string','gzip input must be a string')
        assert(#raw>=18 and raw:sub(1,3)=='\031\139\008','invalid gzip header')
        local flags=raw:byte(4)
        assert(flags<32,'reserved gzip flags')
        local p=11
        if math.floor(flags/4)%2==1 then
            local a,b=raw:byte(p,p+1);assert(b,'truncated extra header')
            p=p+2+a+b*256
        end
        for _,flag in ipairs({8,16}) do
            if math.floor(flags/flag)%2==1 then
                local stop=raw:find('\000',p,true);assert(stop,'unterminated gzip header')
                p=stop+1
            end
        end
        if math.floor(flags/2)%2==1 then
            local a,b=raw:byte(p,p+1);assert(b,'truncated header CRC')
            assert(crc32(raw:sub(1,p-1))%65536==a+b*256,'gzip header CRC mismatch')
            p=p+2
        end
        assert(p<=#raw-8,'truncated gzip body')
        local expected_size=u32(raw,#raw-3)
        local expected_crc=u32(raw,#raw-7)
        local compressed=raw:sub(p,#raw-8)
        raw=nil;collectgarbage('collect')
        local text,remaining=deflate:DecompressDeflate(compressed)
        compressed=nil;collectgarbage('collect')
        assert(text and remaining==0,'invalid DEFLATE data or unsupported concatenated gzip members')
        assert(#text%4294967296==expected_size,'gzip size mismatch')
        assert(crc32(text)==expected_crc,'gzip CRC mismatch')
        return text
    end
end
