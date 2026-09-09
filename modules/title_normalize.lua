-- Shared title normalization for display cleanup, matching, cache keys, and
-- the disk-backed TMDb index. Only ASCII bytes are classified as punctuation;
-- UTF-8 title bytes are preserved unchanged.
return function()
local function ascii_lower(s)
    return (s:gsub('[A-Z]', function(c)
        return string.char(c:byte() + 32)
    end))
end

local function trim(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('%s+', ' ')
    s = s:gsub('^%s+', '')
    return (s:gsub('%s+$', ''))
end

local function normalize_index(s)
    if type(s) ~= 'string' then return '' end
    s = ascii_lower(s)
    -- Keep this exact range compatible with existing bundled index files.
    s = s:gsub('[\009-\013\032-\047\058-\064\091-\096\123-\126]+', ' ')
    return trim(s)
end

local function normalize_match(s)
    if type(s) ~= 'string' then return '' end
    -- Preserve the established TMDb behavior for ampersands while keeping the
    -- disk index compatible with generations built before this module existed.
    s = s:gsub('&', ' and ')
    s = ascii_lower(s)
    -- Numeric ranges deliberately stop at DEL. Bytes 128-255 are parts of
    -- UTF-8 sequences and are never classified through locale-sensitive %w.
    s = s:gsub('[\001-\032\033-\047\058-\064\091-\096\123-\127]+', ' ')
    return trim(s)
end

local function leading_bracket_alternative(s)
    if type(s) ~= 'string' then return nil end
    local alternative = s
    local removed = false
    while true do
        local next_value, count = alternative:gsub('^%s*%b[]%s*', '', 1)
        if count == 0 then break end
        alternative = next_value
        removed = true
    end
    alternative = trim(alternative)
    if not removed or alternative == '' or normalize_match(alternative) == normalize_match(s) then
        return nil
    end
    return alternative
end

return {
    trim = trim,
    normalize_index = normalize_index,
    normalize_match = normalize_match,
    same = function(a, b)
        local left, right = normalize_match(a), normalize_match(b)
        return left ~= '' and left == right
    end,
    leading_bracket_alternative = leading_bracket_alternative,
}
end
