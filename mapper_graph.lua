-- mapper_graph.lua -- BFS pathfinding and speedwalk string building.

local store = require("mapper_store")
local M = {}

local function safewalk_enabled()
    return rune.store.get("mapper.safewalk") == true
end

local function depth_limit()
    local v = rune.store.get("mapper.scan_depth")
    if v == nil or v == false then return nil end
    local n = tonumber(v)
    if not n or n < 1 then return nil end
    return n
end

local function blocks_walk(room)
    if not room then return false end
    if store.has_tag(room, "no-speed") or store.has_tag(room, "dt") then return true end
    if safewalk_enabled() then
        if room.flags and room.flags:find("player%-kill%-") then return true end
        if store.has_tag(room, "dt") then return true end
    end
    return false
end

local function reconstruct(dest_uid, explored)
    local rev = {}
    local node = explored[dest_uid]
    while node and node.parent do
        rev[#rev + 1] = { dir = node.dir, uid = node.uid }
        node = node.parent
    end
    local n = #rev
    local path = {}
    for i = n, 1, -1 do
        path[#path + 1] = rev[i]
    end
    return path
end

-- Parent-pointer BFS. Returns (paths, depth_exhausted) where
-- paths[uid] = { reason, path = { {dir, uid}, ... } }.
function M.find_paths(start_uid, predicate, opts)
    opts = opts or {}
    local limit = opts.depth
    if limit == nil then limit = depth_limit() end
    local explored = {}
    local paths = {}
    local root = { uid = start_uid, parent = nil, dir = nil }
    explored[start_uid] = root
    local particles = { root }
    local depth = 0
    local exhausted = false

    while #particles > 0 do
        depth = depth + 1
        if limit and depth > limit then
            exhausted = true
            break
        end
        local nxt = {}
        for _, part in ipairs(particles) do
            local room = store.rooms[part.uid]
            if room and room.exits then
                for dir, dest in pairs(room.exits) do
                    dest = tostring(dest)
                    if explored[dest] == nil then
                        local dest_room = store.rooms[dest]
                        if not blocks_walk(dest_room) then
                            local new_part = { uid = dest, parent = part, dir = dir }
                            explored[dest] = new_part
                            local reason = predicate(dest, dest_room)
                            if reason then paths[dest] = { reason = reason } end
                            nxt[#nxt + 1] = new_part
                        end
                    end
                end
            end
        end
        particles = nxt
    end

    for uid, data in pairs(paths) do
        data.path = reconstruct(uid, explored)
    end
    return paths, exhausted
end

function M.build_speedwalk(path)
    if not path or #path == 0 then return nil end
    local grouped = {}
    for _, step in ipairs(path) do
        local n = #grouped
        if n == 0 or grouped[n].dir ~= step.dir then
            grouped[#grouped + 1] = { dir = step.dir, count = 1 }
        else
            grouped[n].count = grouped[n].count + 1
        end
    end
    local parts = {}
    for _, g in ipairs(grouped) do
        local s = ""
        if g.count > 1 then s = s .. g.count end
        if #g.dir == 1 then
            s = s .. g.dir
        else
            s = s .. "(" .. g.dir .. ")"
        end
        parts[#parts + 1] = s
    end
    return table.concat(parts, " ")
end

function M.name_match(room, needle)
    if not room or not room.name or not needle then return nil end
    local nl = room.name:lower()
    local pl = needle:lower()
    if nl:find(pl, 1, true) then return room.name end
    return nil
end

return M
