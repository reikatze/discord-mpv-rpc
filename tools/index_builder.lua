-- Bounded sorting runs and two-way disk merges. Requires only Lua and JSON functions.
return function(json,gunzip)
    local function normalize(s)
        return (s:gsub('[A-Z]',function(c) return string.char(c:byte()+32) end)
            :gsub('[\009-\013\032-\047\058-\064\091-\096\123-\126]+',' ')
            :gsub('^ +',''):gsub(' +$',''))
    end
    local function less(a,b)
        if a[1]~=b[1] then return a[1]<b[1] end
        return a[2]<b[2]
    end
    return function(source,base,media,log)
        local handles,temporary={},{}
        local function open(path,mode)
            local f=assert(io.open(path,mode));handles[#handles+1]=f;return f
        end
        local function write(f,s) assert(f:write(s)) end
        local function write_run(f,row)
            write(f,row[1]..'\t'..string.format('%.0f',row[2])..'\n')
        end
        local function read_run(f)
            local s=f:read('*l')
            if not s then return nil end
            local key,id=s:match('^(.*)\t(%d+)$')
            id=tonumber(id)
            assert(key and id and id>0 and id%1==0,'invalid temporary index row')
            return {key,id}
        end
        local success,result=pcall(function()
            local input=open(source,'rb');local raw=assert(input:read('*a'));input:close()
            log('Decompressing '..media..' export (Lua)')
            local holder={data=raw};raw=nil
            local text=gunzip(holder);collectgarbage('collect')
            local runs,batch={},{}
            local function flush()
                table.sort(batch,less)
                local path=base..'.run'..(#runs+1)
                temporary[#temporary+1]=path
                local f=open(path,'wb')
                for _,row in ipairs(batch) do write_run(f,row) end
                assert(f:close());runs[#runs+1]=path;batch={}
            end
            local line_number=0
            for line in text:gmatch('[^\n]+') do
                line_number=line_number+1
                local row=json.parse_json(line)
                assert(type(row)=='table' and type(row.id)=='number' and row.id>0 and row.id%1==0,
                    'invalid export row '..line_number)
                local title=media=='movie' and row.original_title or row.original_name
                assert(type(title)=='string','missing original title at row '..line_number)
                if not row.adult and not row.video then
                    local key=normalize(title)
                    if key~='' and #key<=1024 then
                        batch[#batch+1]={key,row.id}
                        if #batch==20000 then flush() end
                    end
                end
            end
            text=nil;collectgarbage('collect')
            if #batch>0 then flush() end
            assert(#runs>0,'empty export')
            log('Sorting '..media..' index')
            local pass=0
            while #runs>1 do
                pass=pass+1;local next_runs={}
                for i=1,#runs,2 do
                    if not runs[i+1] then next_runs[#next_runs+1]=runs[i]
                    else
                        local path=base..'.merge'..pass..'-'..i;temporary[#temporary+1]=path
                        local a,b,out=open(runs[i],'rb'),open(runs[i+1],'rb'),open(path,'wb')
                        local x,y=read_run(a),read_run(b)
                        while x or y do
                            if x and (not y or less(x,y)) then write_run(out,x);x=read_run(a)
                            else write_run(out,y);y=read_run(b) end
                        end
                        a:close();b:close();assert(out:close())
                        os.remove(runs[i]);os.remove(runs[i+1]);next_runs[#next_runs+1]=path
                    end
                end
                runs=next_runs
            end
            local input=open(runs[1],'rb')
            local data,offsets=open(base..'.jsonl','wb'),open(base..'.offsets','wb')
            local count,previous,ids,last=0,nil,{},nil
            local function emit()
                if not previous then return end
                -- Keep the empty-array overflow sentinel compatible with mpv JSON.
                local values=#ids>4 and '[]' or assert(json.format_json(ids))
                local line='['..assert(json.format_json(previous))..','..values..']\n'
                if #line<=4096 then
                    write(offsets,string.format('%016.0f\n',assert(data:seek())))
                    write(data,line);count=count+1
                end
            end
            while true do
                local row=read_run(input);if not row then break end
                if previous~=row[1] then emit();previous=row[1];ids={};last=nil end
                if row[2]~=last then
                    if #ids<=4 then ids[#ids+1]=row[2] end
                    last=row[2]
                end
            end
            emit();assert(data:close());assert(offsets:close());input:close()
            assert(count>0,'empty index');return count
        end)
        for _,f in ipairs(handles) do pcall(function() f:close() end) end
        for _,path in ipairs(temporary) do os.remove(path) end
        if not success then
            os.remove(base..'.jsonl');os.remove(base..'.offsets');error(result)
        end
        return result
    end
end
