-- Lua patterns matched only at trailing release boundaries.
-- Group prefixes require a dash; bracketed tags are handled by the parser.
return {
    release_suffixes = {
    'web[%.%s%-]?dl', 'webrip', 'blu[%.%s%-]?ray', 'b[dr]rip',
    'hdrip', 'dvdrip', 'hdtv', 'amzn', 'nf', 'dsnp', 'hmax',
    'proper', 'repack', 'remux', '[xh][%.%s%-]?26[45]', 'hevc', 'avc',
    'av1', 'aac', 'e[%.%s%-]?ac3', 'ac3', 'dts[%.%s%-]?hd', 'dts',
    'truehd', 'ddp%d*', 'atmos', 'flac', 'opus', 'mp3',
    '[257][%. ]1', '[257][%. ]1[%. ]%d',
    '480[pi]', '576[pi]', '720[pi]', '1080[pi]', '2160[pi]', '4320[pi]',
    '[248]k', '10[%.%s%-]?bit', '8[%.%s%-]?bit', '12[%.%s%-]?bit',
    'hdr10%+?', 'hdr', 'sdr', 'judas', 'subsplease', 'horriblesubs',
},
    release_groups = {'judas', 'subsplease', 'horriblesubs'},
}
