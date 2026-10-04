-- mapper_store.lua -- room database + position, persisted as a compact
-- line-based file (no JSON caps, fast load/save).
--
-- File: <config_dir>/mapper/map.db, one room per line, fields separated by
-- US (0x1f): uid, name, area, flags, terrain, terraininfo, coord, exits,
-- tags, bookmark. exits use "dir=uid" joined by RS (0x1e); tags joined by
-- GS (0x1d).

local M = {}

M.rooms = {}
M.position = nil            -- { uid = "...", area = "..." }
M.dirty = false
M.file = (rune.config_dir or ".") .. "/mapper/map.db"

local US, RS, GS = "\31", "\30", "\29"

local SHORT_DIRS = { "n", "nw", "w", "sw", "s", "se", "e", "ne", "u", "d", "in", "out" }
local DIR_TO_SHORT = {
    north = "n", northwest = "nw", west = "w", southwest = "sw",
    south = "s", southeast = "se", east = "e", northeast = "ne",
    up = "u", down = "d", ["in"] = "in", out = "out",
    n = "n", nw = "nw", w = "w", sw = "sw", s = "s", se = "se", e = "e", ne = "ne",
    u = "u", d = "d",
}
local DIR_ORDER = { "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d", "in", "out" }

local function clean(s)
    return (tostring(s or ""):gsub("[\r\n\29\30\31]", " "))
end

local function split(s, sep)
    local out = {}
    local start = 1
    while true do
        local i = s:find(sep, start, true)
        if not i then out[#out + 1] = s:sub(start); break end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return out
end

local function parse_exits(exits)
    local out = {}
    if type(exits) ~= "table" then return out end
    for dir, e in pairs(exits) do
        local short = DIR_TO_SHORT[tostring(dir):lower()]
        if short then
            local v
            if type(e) == "string" or type(e) == "number" then
                v = tostring(e)
            elseif type(e) == "table" then
                v = e.uid or e.to or e.num
                v = v and tostring(v)
            end
            if v and v ~= "" then out[short] = v end
        end
    end
    return out
end

local function encode_room(r)
    local ex = {}
    for _, dir in ipairs(DIR_ORDER) do
        if r.exits and r.exits[dir] then ex[#ex + 1] = dir .. "=" .. clean(r.exits[dir]) end
    end
    local coord = ""
    if type(r.coord) == "table" then
        coord = string.format("%s,%s,%s", r.coord.x or 0, r.coord.y or 0, r.coord.z or 0)
    end
    local tags = ""
    if type(r.tags) == "table" then tags = table.concat(r.tags, GS)
    elseif r.tags then tags = clean(r.tags) end
    return table.concat({
        clean(r.uid), clean(r.name), clean(r.area), clean(r.flags),
        clean(r.terrain), clean(r.terraininfo), coord,
        table.concat(ex, RS), tags, clean(r.bookmark),
    }, US)
end

local function decode_room(line)
    local f = split(line, US)
    local uid = f[1]
    if not uid or uid == "" then return nil end
    local r = { uid = uid }
    if f[2] and f[2] ~= "" then r.name = f[2] end
    if f[3] and f[3] ~= "" then r.area = f[3] end
    if f[4] and f[4] ~= "" then r.flags = f[4] end
    if f[5] and f[5] ~= "" then r.terrain = f[5] end
    if f[6] and f[6] ~= "" then r.terraininfo = f[6] end
    if f[7] and f[7] ~= "" then
        local x, y, z = f[7]:match("([^,]*),([^,]*),([^,]*)")
        r.coord = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
    if f[8] and f[8] ~= "" then
        r.exits = {}
        for pair in f[8]:gmatch("[^" .. RS .. "]+") do
            local dir, dest = pair:match("^(%a+)=(.*)$")
            if dir and dest and dest ~= "" then r.exits[dir] = dest end
        end
    end
    if f[9] and f[9] ~= "" then
        r.tags = {}
        for t in f[9]:gmatch("[^" .. GS .. "]+") do r.tags[#r.tags + 1] = t end
    end
    if f[10] and f[10] ~= "" then r.bookmark = f[10] end
    return r
end

function M.load()
    M.rooms = {}
    local f = io.open(M.file, "r")
    if not f then
        return true, "no map yet"
    end
    local text = f:read("*a")
    f:close()
    local n = 0
    for line in text:gmatch("[^\n]+") do
        local r = decode_room(line)
        if r then M.rooms[r.uid] = r; n = n + 1 end
    end
    M.dirty = false
    return true, n .. " rooms"
end

function M.save()
    local dir = M.file:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir .. "'") end
    local lines = {}
    for _, r in pairs(M.rooms) do
        lines[#lines + 1] = encode_room(r)
    end
    local f = io.open(M.file, "w")
    if not f then return false, "cannot write " .. M.file end
    f:write(table.concat(lines, "\n"))
    f:close()
    M.dirty = false
    return true
end

function M.mark_dirty()
    M.dirty = true
end

function M.get(uid)
    if uid == nil then return nil end
    return M.rooms[tostring(uid)]
end

function M.upsert(info)
    if type(info) ~= "table" then return nil end
    local uid = info.num or info.id
    if not uid then return nil end
    uid = tostring(uid)
    local r = M.rooms[uid] or {}
    r.uid = uid
    r.name = info.name or r.name
    r.area = info.area or info.zone or r.area
    r.exits = parse_exits(info.exits)
    if info.flags and info.flags ~= "_empty" then
        r.flags = info.flags
    end
    if info.terrain then r.terrain = info.terrain end
    if info.terraininfo then r.terraininfo = info.terraininfo end
    if info.coord then r.coord = info.coord end
    r.last_visited = os.time()
    M.rooms[uid] = r
    M.position = { uid = uid, area = r.area }
    M.dirty = true
    return r
end

function M.put(uid, room)
    if uid == nil or type(room) ~= "table" then return end
    uid = tostring(uid)
    room.uid = uid
    M.rooms[uid] = room
end

function M.has_tag(room, tag)
    if not room or not room.tags then return false end
    if type(room.tags) == "table" then
        for _, t in ipairs(room.tags) do
            if t == tag then return true end
        end
        return false
    end
    return tostring(room.tags):find(tag, 1, true) ~= nil
end

function M.set_tag(uid, tag, on)
    local r = M.get(uid)
    if not r then return false end
    if type(r.tags) ~= "table" then r.tags = {} end
    local found
    for i, t in ipairs(r.tags) do
        if t == tag then found = i; break end
    end
    if on and not found then
        r.tags[#r.tags + 1] = tag
    elseif not on and found then
        table.remove(r.tags, found)
    end
    M.dirty = true
    return true
end

function M.set_bookmark(uid, text)
    uid = tostring(uid)
    local r = M.rooms[uid]
    if not r then
        r = { uid = uid }
        M.rooms[uid] = r
    end
    if text and text ~= "" then
        r.bookmark = text
    else
        r.bookmark = nil
    end
    M.dirty = true
    return true
end

function M.count()
    local n = 0
    for _ in pairs(M.rooms) do n = n + 1 end
    return n
end

M.SHORT_DIRS = SHORT_DIRS

return M
