-- Filename cleanup, title/year/episode parsing, and chapter metadata.
-- Each factory owns its private locals; dependencies are supplied by main.lua.
return function(modules, shared)
local floor = modules.helpers.floor
local get_property = modules.helpers.get_property
local get_property_number = modules.helpers.get_property_number
local gsub = modules.helpers.gsub
local match = modules.helpers.match
local sub = modules.helpers.sub
local title_normalize = modules.title_normalize

-- Parsed filename cache: mpv can trigger several events for the same path.
local parsed_filename_cache = {}
local PARSED_FILENAME_CACHE_MAX = 256

-- Filename -> title / year / is_tv
----------------------------------------------------------------
local function basename_without_extension(path)
    local name = match(path, '([^/\\\\]+)$') or path
    return gsub(name, '%.[^%.]+$', '')
end

local function parent_directory(path)
    return match(path, '^(.*)[/\\\\][^/\\\\]+$')
end

local function extract_episode_info(name)
    -- Standard TV/scene forms:
    --   Show.S02E05 / Show S02 E05 / Show S02-E05
    local season, ep = match(name, '[sS](%d+)%s*[-%.]?%s*[eE]%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Explicit season + dash + episode: Show S2 - 03 / S02-03
    season, ep = match(name, '[sS](%d+)%s*%-%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Common alternate notation: Show 2x05 / Show 02x05
    season, ep = match(name, '[%s%._%-](%d+)[xX](%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Explicit words are less ambiguous than bare numbers.
    season, ep = match(name, '[sS]eason%s*(%d+)%s*[,%-]?%s*[eE]pisode%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    season, ep = match(name, '[sS]eason%s*(%d+)%s*[,%-]?%s*[eE]p?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    season, ep = match(name, '[sS](%d+)%s*[eE]pisode%.?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end
    season, ep = match(name, '[sS](%d+)%s*[eE]p%.?%s*(%d+)')
    if season then
        return tonumber(season), tonumber(ep), true
    end

    -- Anime/scene style: Show - 05 - Episode Title
    -- Only treat a number as an episode when it is separated by dashes,
    -- avoiding accidental matches inside the show title.
    ep = match(name, '%s%-%s*(%d+)%s*%-%s*')
    if ep then
        return 1, tonumber(ep), true
    end

    -- Existing parenthesized form: Show - 05 (Episode Title)
    ep = match(name, '%s%-%s*(%d+)%s*%(')
    if ep then
        return 1, tonumber(ep), true
    end

    -- Simple "Show - 05" at the end. Permit common release/version tags
    -- after the episode number (e.g. "Show - 05v2"), but don't treat an
    -- arbitrary number elsewhere in a filename as an episode.
    ep = match(name, '%s%-%s*(%d+)[vV]%d+%s*$')
    if ep then
        return 1, tonumber(ep), true
    end
    ep = match(name, '%s%-%s*(%d+)%s*$')
    if ep then
        return 1, tonumber(ep), true
    end

    return nil, nil, false
end

local function extract_year(name)
    -- Parenthesized years are explicit. If more than one is present, the last
    -- is normally the release year rather than a numeric title component.
    local year, year_start, year_end
    local from = 1
    while true do
        local first, last, value
        local a1, b1, y1 = name:find('%((19%d%d)%)', from)
        local a2, b2, y2 = name:find('%((20%d%d)%)', from)
        if a1 and (not a2 or a1 < a2) then first,last,value=a1,b1,y1
        elseif a2 then first,last,value=a2,b2,y2 end
        if not first then break end
        year, year_start, year_end = value, first, last
        from = last + 1
    end
    if year then return year, year_start, year_end end

    -- For bare years, use the final plausible token and require meaningful
    -- title text before it. Thus "1917.2019" selects 2019, while a title that
    -- is itself just "1917" is not erased.
    from = 1
    while true do
        local first, last, value = name:find('%f[%d](19%d%d)%f[%D]', from)
        local a2, b2, y2 = name:find('%f[%d](20%d%d)%f[%D]', from)
        if not first or (a2 and a2 < first) then first,last,value=a2,b2,y2 end
        if not first then break end
        local before = sub(name, 1, first - 1)
        if before:find('[%w\128-\255]') then
            year, year_start, year_end = value, first, last
        end
        from = last + 1
    end
    return year, year_start, year_end
end

local function derive_title(name, year, is_tv, year_start)
    if is_tv then
        local title = match(name, '^(.-)%s*[sS]%d+%s*[-%.]?%s*[eE]%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*%-%s*%d+')
            or match(name, '^(.-)[%s%._%-]%d+[xX]%d+')
            or match(name, '^(.-)%s*[sS]eason%s*%d+%s*[,%-]?%s*[eE]pisode%s*%d+')
            or match(name, '^(.-)%s*[sS]eason%s*%d+%s*[,%-]?%s*[eE]p?%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*[eE]pisode%.?%s*%d+')
            or match(name, '^(.-)%s*[sS]%d+%s*[eE]p%.?%s*%d+')
            or match(name, '^(.-)%s*%-%s*%d+%s*%-%s*')
            or match(name, '^(.-)%s*%-%s*%d+%s*%(')
            or match(name, '^(.-)%s*%-%s*%d+%s*[vV]%d+%s*$')
            or match(name, '^(.-)%s*%-%s*%d+%s*$')
            or name
        if year and year_start and year_start <= #title then
            title = sub(name, 1, year_start - 1)
        end
        return title
    end

    if year and year_start then return sub(name, 1, year_start - 1) end

    return name
end

-- Match tags on a lowercase copy, retaining the original title's spelling.
-- Keep matching at release boundaries so words inside real titles survive.
local release_suffixes = modules.database.parsing.release_suffixes
local release_groups = modules.database.parsing.release_groups

local function exact_release_tag(value)
    for i = 1, #release_suffixes do
        if value:match('^' .. release_suffixes[i] .. '$') then return true end
    end
    for i = 1, #release_groups do
        if value == release_groups[i]:lower() then return true end
    end
    return false
end

local function known_bracket_content(content)
    content = title_normalize.trim(content:lower())
    if content == '' then return false end
    if exact_release_tag(content) then return true end
    for token in content:gmatch('[^%s,;/]+') do
        if not exact_release_tag(token) then
            local recognized = true
            local pieces = 0
            for piece in token:gmatch('[^_%-]+') do
                pieces = pieces + 1
                if not exact_release_tag(piece) then recognized = false;break end
            end
            if pieces < 2 or not recognized then return false end
        end
    end
    return true
end

local function strip_filename_release_tags(name)
    name = gsub(name, '%b[]', function(block)
        local content = sub(block, 2, -2)
        return known_bracket_content(content) and ' ' or block
    end)
    -- Unbracketed group prefixes require a dash, avoiding damage to titles
    -- such as "Judas and the Black Messiah".
    for _, group in ipairs(release_groups) do
        local escaped = group:lower():gsub('([^%w])', '%%%1')
        local _, last = name:lower():find('^%s*' .. escaped .. '%s*%-%s*')
        if last then name = sub(name, last + 1) end
    end

    local previous
    repeat
        previous = name
        name = gsub(name, '[%s%._%-]+$', '')
        for i = 1, #release_suffixes do
            local tag = release_suffixes[i]
            local lower = name:lower()
            local first = lower:find('[%s%._%-]+' .. tag .. '$')
                or lower:find('[%s%._%-]+%(' .. tag .. '%)$')
            if first then name = sub(name, 1, first - 1) end
        end
    until name == previous
    return name
end

local function normalize_filename_title(title)
    title = strip_filename_release_tags(title)
    -- Keep meaningful parenthetical title text. Years are removed by
    -- derive_title()/directory_context(), and recognized technical tags are
    -- already handled by strip_filename_release_tags().
    title = gsub(title, '[%.%_]', ' ')
    title = strip_filename_release_tags(title)
    title = gsub(title, '^%s*%-%s*', '')
    return title_normalize.trim(title)
end

local function directory_context(path)
    local dir = parent_directory(path)
    if not dir or dir == '' then return nil, nil end

    local name = match(dir, '([^/\\]+)$') or dir
    local year, year_start = extract_year(name)
    if not year then return nil, nil end

    local title = derive_title(name, year, false, year_start)
    title = normalize_filename_title(title)
    if title == '' then return nil, year end
    return title, year
end

local function trim_parsed_filename_cache()
    local count = 0
    for _ in pairs(parsed_filename_cache) do count = count + 1 end
    if count <= PARSED_FILENAME_CACHE_MAX then return end
    for key in pairs(parsed_filename_cache) do
        parsed_filename_cache[key] = nil
        count = count - 1
        if count <= PARSED_FILENAME_CACHE_MAX then break end
    end
end

local function clean_filename(path)
    local cached = parsed_filename_cache[path]
    if cached then
        return cached.title, cached.year, cached.is_tv, cached.season, cached.episode
    end

    local name = basename_without_extension(path)
    -- Strip release metadata before parsing bare anime episode numbers.
    name = strip_filename_release_tags(name)

    local season, ep, is_tv = extract_episode_info(name)
    local year, year_start = extract_year(name)
    local title = derive_title(name, year, is_tv, year_start)
    title = normalize_filename_title(title)

    -- If the filename omits its year, inherit a year from a media/show
    -- directory such as "[Judas] Koukaku Kidoutai (2026)". A year explicitly
    -- present in the filename always wins.
    if not year then
        local dir_title, dir_year = directory_context(path)
        if dir_year then
            year = dir_year
            -- If the directory has a useful title and the filename title is
            -- empty/generic, prefer the directory title. Otherwise preserve
            -- the filename title because it may contain a more specific alias.
            if (not title or title == '') and dir_title and dir_title ~= '' then
                title = dir_title
            end
        end
    end

    local result = {
        title = title, year = year, is_tv = is_tv, season = season, episode = ep,
    }
    parsed_filename_cache[path] = result
    trim_parsed_filename_cache()
    return title, year, is_tv, season, ep
end

local function tagged_title()
    local meta = mp.get_property_native('metadata')
    if type(meta) ~= 'table' then
        return nil
    end
    local t = meta.title or meta.TITLE or meta.Title
    if type(t) ~= 'string' then
        return nil
    end
    t = gsub(t, '^%s+', '')
    t = gsub(t, '%s+$', '')
    if #t < 2 or match(t, '^https?://') or match(t, '%.%w%w%w%w?$') then
        return nil
    end
    return t
end

local function chapter_title()
    local title = get_property('chapter-metadata/title')
    if title and title ~= '' then
        return title
    end
    local idx = get_property_number('chapter')
    if not idx then
        return nil
    end
    title = get_property('chapter-list/' .. floor(idx) .. '/title')
    if title and title ~= '' then
        return title
    end
    return nil
end

local function meaningful_chapter_title()
    local title = chapter_title()
    if not title then return nil end

    title = gsub(title, '^%s+', '')
    title = gsub(title, '%s+$', '')
    if title == '' then return nil end

    -- Some muxers/editors use the chapter timestamp itself as the title.
    if match(title, '^%d%d?:%d%d:%d%d$') or match(title, '^%d%d?:%d%d:%d%d[.,]%d+$') then
        return nil
    end

    -- Avoid displaying generic scene/chapter labels when there is no useful
    -- episode title. Real descriptive chapter names are still preserved.
    local lower = title:lower()
    if match(lower, '^chapter%s+%d+$')
        or match(lower, '^scene%s+%d+$')
        or lower == 'no scene description'
        or lower == 'no chapter description' then
        return nil
    end

    return title
end

return {
    clean_filename = clean_filename,
    directory_context = directory_context,
    meaningful_chapter_title = meaningful_chapter_title,
    tagged_title = tagged_title,
}
end
