-- Gzip framing/checksums in Lua; DEFLATE handled by the bundled LibDeflate.
return function(deflate)
    local ok, bit = pcall(require, 'bit')
    if not ok then bit = rawget(_G, 'bit32') end
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
    local function crc32(s)
        local c=4294967295
        for i=1,#s do
            c=unsigned(xor(math.floor(c/256),crc_table[unsigned(xor(c,s:byte(i)))%256]))
        end
        return unsigned(xor(c,4294967295))
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
