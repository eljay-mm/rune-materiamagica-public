-- mapper.lua -- Materia Magica mapper for Rune (native).
--
-- Room database + BFS pathfinding + real step-by-step walking. No SQLite,
-- no Python. Map data lives in <config_dir>/mapper/map.json.
--
-- Commands: `mapper help`.

local store = require("mapper_store")
local graph = require("mapper_graph")
local walk = require("mapper_walk")
local H = require("helpstyle")

local MAX_MATCHES = 1000

local ok, info = store.load()
if ok then
    rune.dbg("[mapper] loaded " .. tostring(info))
else
    rune.echo("[mapper] " .. tostring(info))
end

-- GMCP Room feed -------------------------------------------------------------

rune.gmcp.subscribe("Room")

rune.gmcp.on("Room.Info", function(data)
    local r = store.upsert(data)
    if r then
        walk.on_room(r.uid)
        if rune.store.get("mapper.announce") == true then
            rune.echo(string.format("[%s] %s", r.uid, r.name or "?"))
        end
    end
end, { name = "mapper-room-info" })

local function echo_here()
    local uid = store.position and store.position.uid
    if not uid then
        rune.echo("[mapper] no room yet.")
        return
    end
    local r = store.get(uid)
    rune.echo(string.format("[mapper] room %s - %s @ %s",
        uid, (r and r.name) or "?", (r and r.area) or "?"))
end

-- Persist periodically and on disconnect. Saving rewrites the chunk files,
-- so this is infrequent; tags/bookmarks also save via `mapper save`.
rune.timer.every(300, function()
    if store.dirty then store.save() end
end, { name = "mapper-autosave" })

rune.hooks.on("disconnected", function()
    if store.dirty then store.save() end
end, { name = "mapper-save-disconnect" })

-- Helpers --------------------------------------------------------------------

local function cur_uid()
    return store.position and store.position.uid
end

local function show_room_line(uid, room, extra)
    local parts = { tostring(uid), " - ", (room and room.name) or "?" }
    if room and room.area then parts[#parts + 1] = " @ "; parts[#parts + 1] = room.area end
    if extra then parts[#parts + 1] = " "; parts[#parts + 1] = extra end
    rune.echo(table.concat(parts))
end

-- Nearby search: BFS from here, restricted to the current area, sorted
-- nearest-first. Returns a list of { uid, room, steps }, or nil + message.
local function find_nearby(what)
    local from = cur_uid()
    if not from then return nil, "I don't know where you are." end
    if not store.rooms[from] then return nil, "current room not in database yet." end
    local area = store.position and store.position.area
    local matches = graph.find_paths(from, function(uid, room)
        if area and room and room.area ~= area then return nil end
        return graph.name_match(room, what)
    end)
    local list = {}
    for uid, data in pairs(matches) do
        list[#list + 1] = { uid = uid, room = store.rooms[uid], steps = #data.path }
    end
    table.sort(list, function(a, b)
        if a.steps ~= b.steps then return a.steps < b.steps end
        return tostring(a.uid) < tostring(b.uid)
    end)
    return list
end

local function map_path(from_uid, to_uid)
    if not store.get(from_uid) or not store.get(to_uid) then
        rune.echo("[mapper path] unknown room.")
        return
    end
    local matches, exhausted = graph.find_paths(from_uid, function(uid)
        if uid == tostring(to_uid) then return "dest" end
        return nil
    end)
    local data = matches[tostring(to_uid)]
    if data then
        rune.echo("[mapper path] " .. from_uid .. " -> " .. to_uid .. ": " .. graph.build_speedwalk(data.path))
    else
        local hint = exhausted and " (depth limit hit; try 'mapper depth inf')" or ""
        rune.echo("[mapper path] no path from " .. from_uid .. " to " .. to_uid .. hint)
    end
end

local function start_walk_to(dest)
    local from = cur_uid()
    if not from then rune.echo("[mapper] I don't know where you are."); return end
    if not store.get(dest) then
        rune.echo("[mapper] destination " .. dest .. " not in database.")
        return
    end
    local matches, exhausted = graph.find_paths(from, function(uid)
        if uid == tostring(dest) then return "dest" end
        return nil
    end)
    local data = matches[tostring(dest)]
    if not data then
        local hint = exhausted and " (depth limit hit; try 'mapper depth inf')" or ""
        rune.echo("[mapper] no path found to " .. dest .. hint)
        return
    end
    if #data.path == 0 then
        rune.echo("[mapper goto] " .. dest .. " (already here)")
        return
    end
    local sw = graph.build_speedwalk(data.path)
    rune.echo("[mapper goto] " .. dest .. " (" .. #data.path .. " steps): " .. sw)
    if rune.store.get("mapper.enable_speedwalk_sends") == false then
        rune.echo("[mapper goto] (sends disabled; `mapper sends on` to enable)")
        return
    end
    walk.start(data.path, tostring(dest))
end

local function map_roominfo(uid)
    if uid == "" then uid = nil end
    uid = uid and tostring(uid) or cur_uid()
    if not uid then rune.echo("[mapper] no room and no known position."); return end
    local r = store.get(uid)
    if not r then rune.echo("[mapper] room " .. uid .. " not in database."); return end
    rune.echo("Room " .. uid .. ":")
    rune.echo("  name:    " .. tostring(r.name))
    rune.echo("  area:    " .. tostring(r.area or "?"))
    rune.echo("  flags:   " .. tostring(r.flags or "(none)"))
    rune.echo("  terrain: " .. tostring(r.terrain or "?"))
    if r.bookmark then rune.echo("  bookmark: " .. r.bookmark) end
    if r.tags then
        local tags = type(r.tags) == "table" and table.concat(r.tags, ",") or tostring(r.tags)
        rune.echo("  tags:    " .. tags)
    end
    local dirs = {}
    for d in pairs(r.exits or {}) do dirs[#dirs + 1] = d end
    table.sort(dirs)
    rune.echo("  exits:   " .. table.concat(dirs, " "))
end

local function map_adjacent(name)
    local uid = cur_uid()
    if not uid or not store.get(uid) then rune.echo("[mapper] I don't know where you are."); return end
    local my_name = store.get(uid).name
    rune.echo("Adjacent rooms (name != '" .. tostring(my_name) .. "'):")
    local count = 0
    for dir, dest in pairs(store.get(uid).exits or {}) do
        local room = store.get(dest)
        if room and room.name ~= my_name and (not name or graph.name_match(room, name)) then
            show_room_line(dest, room, "(via " .. dir .. ")")
            count = count + 1
        end
    end
    if count == 0 then rune.echo("  (none)") end
end

local function map_bookmarks(search)
    rune.echo("Bookmarks" .. (search and (" matching '" .. search .. "'") or "") .. ":")
    local count = 0
    for uid, room in pairs(store.rooms) do
        if room.bookmark then
            if not search or room.bookmark:lower():find(search:lower(), 1, true) then
                show_room_line(uid, room, "[" .. room.bookmark .. "]")
                count = count + 1
            end
        end
    end
    if count == 0 then rune.echo("  (none)") end
end

-- Nearby rooms matching a tag or a flag substring; nearest-first picker.
local function map_list_nearby(tag, label, flagpat)
    local from = cur_uid()
    if not from then rune.echo("[mapper] I don't know where you are."); return end
    local matches = graph.find_paths(from, function(uid, room)
        if store.has_tag(room, tag) then return tag end
        if flagpat and room and room.flags then
            local fl = room.flags:lower()
            for _, pat in ipairs(flagpat) do
                if fl:find(pat, 1, true) then return tag end
            end
        end
        return nil
    end)
    local list = {}
    for uid, data in pairs(matches) do
        list[#list + 1] = { uid = uid, room = store.rooms[uid], steps = #data.path }
    end
    table.sort(list, function(a, b)
        if a.steps ~= b.steps then return a.steps < b.steps end
        return tostring(a.uid) < tostring(b.uid)
    end)
    if #list == 0 then
        rune.echo("[mapper] no " .. label .. " found (visited/tagged rooms only)")
        return
    end
    if #list == 1 then
        start_walk_to(list[1].uid)
        return
    end
    local items = {}
    for i = 1, math.min(#list, MAX_MATCHES) do
        local h = list[i]
        items[#items + 1] = {
            text = h.room.name or ("#" .. h.uid),
            desc = h.uid .. "  " .. h.steps .. " steps  " .. tostring(h.room.area or ""),
            value = h.uid,
        }
    end
    rune.ui.picker.show({
        title = label .. " (" .. #list .. ")",
        items = items,
        on_select = function(uid) start_walk_to(uid) end,
    })
end

-- Tag a room (or the current room when id is empty/absent) and report.
local function tag_target(tag, id, on)
    if id == "" then id = nil end
    local uid = id or cur_uid()
    if not uid then
        rune.echo("[mapper] I don't know where you are.")
        return
    end
    local room = store.get(uid)
    if not room then
        rune.echo("[mapper] room " .. uid .. " is not in the map.")
        return
    end
    local had = store.has_tag(room, tag)
    store.set_tag(uid, tag, on)
    if on then
        rune.echo("[mapper] tagged " .. uid .. " as " .. tag)
    elseif had then
        rune.echo("[mapper] removed tag '" .. tag .. "' from " .. uid)
    else
        rune.echo("[mapper] no '" .. tag .. "' tag on " .. uid)
    end
end

-- Commands -------------------------------------------------------------------

-- Search all rooms by name (optionally filtered by area).
local function search_by_name(name, area_filter)
    local matches = {}
    for uid, room in pairs(store.rooms) do
        if graph.name_match(room, name) then
            if not area_filter
                or (room.area and room.area:lower():find(area_filter:lower(), 1, true)) then
                matches[#matches + 1] = { uid = uid, room = room }
            end
        end
    end
    return matches
end

-- One match -> walk; several -> picker. Rune's substitute for Mudlet's
-- clickable room numbers.
local function show_matches(matches, title)
    if #matches == 0 then
        rune.echo("[mapper] no matching rooms")
        return
    end
    if #matches == 1 then
        start_walk_to(matches[1].uid)
        return
    end
    table.sort(matches, function(a, b)
        local an, bn = a.room.name or "", b.room.name or ""
        if an ~= bn then return an < bn end
        return tostring(a.uid) < tostring(b.uid)
    end)
    local items = {}
    for i = 1, math.min(#matches, MAX_MATCHES) do
        local h = matches[i]
        items[#items + 1] = {
            text = h.room.name or ("#" .. h.uid),
            desc = h.uid .. "  " .. tostring(h.room.area or ""),
            value = h.uid,
        }
    end
    rune.ui.picker.show({
        title = title .. " (" .. #matches .. ")",
        items = items,
        on_select = function(uid) start_walk_to(uid) end,
    })
end

rune.alias.regex("^mapper[ ]+nearby[ ]+(.+)$", function(m)
    local list, err = find_nearby(m[1])
    if not list then rune.echo("[mapper nearby] " .. err); return end
    if #list == 0 then
        rune.echo("[mapper nearby] no nearby matches in " ..
            tostring(store.position and store.position.area or "?"))
        return
    end
    if #list == 1 then
        start_walk_to(list[1].uid)
        return
    end
    local items = {}
    for i = 1, math.min(#list, MAX_MATCHES) do
        local h = list[i]
        items[#items + 1] = {
            text = h.room.name or ("#" .. h.uid),
            desc = h.uid .. "  " .. h.steps .. " steps  " .. tostring(h.room.area or ""),
            value = h.uid,
        }
    end
    rune.ui.picker.show({
        title = "Nearby: " .. m[1] .. " (" .. #list .. ")",
        items = items,
        on_select = function(uid) start_walk_to(uid) end,
    })
end, { name = "mapper-nearby" })

rune.alias.regex("^mapper[ ]+where[ ]+(.+)$", function(m)
    local arg = m[1]
    local name, area = arg:match("^(.-)%s+a:(.+)$")
    if not name then name = arg end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        rune.echo("[mapper] where: a room name is required")
        return
    end
    show_matches(search_by_name(name, area), "Where")
end, { name = "mapper-where" })

rune.alias.regex("^mapper[ ]+path[ ]+([0-9A-Fa-f]+)$", function(m)
    local from = cur_uid()
    if not from then rune.echo("[mapper] I don't know where you are."); return end
    map_path(from, m[1])
end, { name = "mapper-path" })

rune.alias.regex("^mapper[ ]+path[ ]+([0-9A-Fa-f]+)[ ]+([0-9A-Fa-f]+)$", function(m)
    map_path(m[1], m[2])
end, { name = "mapper-path2" })

rune.alias.regex("^mapper[ ]+goto[ ]+(.+)$", function(m)
    local arg = m[1]
    if store.get(arg) then
        start_walk_to(arg)
    else
        show_matches(search_by_name(arg), "Go to")
    end
end, { name = "mapper-goto" })

rune.alias.regex("^mapper[ ]+stop$", function()
    walk.stop()
    rune.echo("[mapper] stopped.")
end, { name = "mapper-stop" })

rune.alias.regex("^mapper[ ]+resume$", function()
    local dest = walk.get_destination()
    if not dest then rune.echo("[mapper] nothing to resume."); return end
    rune.echo("[mapper] resuming to " .. dest .. " (" .. walk.remaining_count() .. " steps left)")
    start_walk_to(dest)
end, { name = "mapper-resume" })

rune.alias.regex("^mapper[ ]+roominfo(|[ ]+([0-9A-Fa-f]+))$", function(m)
    map_roominfo(m[2])
end, { name = "mapper-roominfo" })

rune.alias.regex("^mapper[ ]+(here|whereami)$", echo_here, { name = "mapper-here" })

rune.alias.regex("^mapper[ ]+peek[ ]+([0-9A-Fa-f]+)$", function(m)
    map_roominfo(m[1])
end, { name = "mapper-peek" })

rune.alias.regex("^mapper[ ]+adjacent[ ]*(.*)$", function(m)
    map_adjacent(m[1] ~= "" and m[1] or nil)
end, { name = "mapper-adjacent" })

rune.alias.regex("^mapper[ ]+safes$", function() map_list_nearby("safe", "Safe rooms", {"safe"}) end, { name = "mapper-safes" })
rune.alias.regex("^mapper[ ]+cpks$", function() map_list_nearby("cpk", "CPK rooms", {"cpk", "player-kill-chaotic"}) end, { name = "mapper-cpks" })
rune.alias.regex("^mapper[ ]+dts$", function() map_list_nearby("dt", "DT rooms") end, { name = "mapper-dts" })
rune.alias.regex("^mapper[ ]+shops$", function() map_list_nearby("shop", "Shops", {"shop"}) end, { name = "mapper-shops" })
rune.alias.regex("^mapper[ ]+train(|er)s$", function() map_list_nearby("trainer", "Trainers", {"trainer"}) end, { name = "mapper-trainers" })

rune.alias.regex("^mapper[ ]+flags[ ]+(.+)$", function(m)
    rune.echo("Rooms with flags matching '" .. m[1] .. "':")
    local count = 0
    local pat = m[1]:lower()
    for uid, room in pairs(store.rooms) do
        if room.flags and room.flags:lower():find(pat, 1, true) then
            show_room_line(uid, room)
            count = count + 1
        end
    end
    if count == 0 then rune.echo("  (none)") end
end, { name = "mapper-flags" })

rune.alias.regex("^mapper[ ]+notflags[ ]+(.+)$", function(m)
    rune.echo("Rooms WITHOUT flags matching '" .. m[1] .. "':")
    local count = 0
    local pat = m[1]:lower()
    for uid, room in pairs(store.rooms) do
        if not room.flags or not room.flags:lower():find(pat, 1, true) then
            show_room_line(uid, room)
            count = count + 1
        end
    end
    if count == 0 then rune.echo("  (none)") end
end, { name = "mapper-notflags" })

rune.alias.regex("^mapper[ ]+bookmarks?$", function() map_bookmarks(nil) end, { name = "mapper-bookmark" })
rune.alias.regex("^mapper[ ]+bookmark[ ]+find[ ]+(.+)$", function(m) map_bookmarks(m[1]) end, { name = "mapper-bookmark-find" })

local function bookmark_find(text)
    local hits = {}
    local needle = text:lower()
    for uid, room in pairs(store.rooms) do
        if room.bookmark and room.bookmark:lower():find(needle, 1, true) then
            hits[#hits + 1] = { uid = uid, room = room }
        end
    end
    return hits
end

rune.alias.regex("^mapper[ ]+bookmark[ ]+goto[ ]+(.+)$", function(m)
    local hits = bookmark_find(m[1])
    if #hits == 0 then
        rune.echo("[mapper] no bookmark matching '" .. m[1] .. "'")
        return
    end
    if #hits == 1 then
        start_walk_to(hits[1].uid)
        return
    end
    table.sort(hits, function(a, b) return a.room.bookmark < b.room.bookmark end)
    local items = {}
    for _, h in ipairs(hits) do
        items[#items + 1] = {
            text = h.room.bookmark,
            desc = h.uid .. "  " .. tostring(h.room.name or ""),
            value = h.uid,
        }
    end
    rune.ui.picker.show({
        title = "Bookmarks (" .. #hits .. ")",
        items = items,
        on_select = function(uid) start_walk_to(uid) end,
    })
end, { name = "mapper-bookmark-goto" })

rune.alias.regex("^mapper[ ]+bookmark[ ]+pick$", function()
    local items = {}
    for uid, room in pairs(store.rooms) do
        if room.bookmark then
            items[#items + 1] = {
                text = room.bookmark,
                desc = uid .. "  " .. tostring(room.name or ""),
                value = uid,
            }
        end
    end
    if #items == 0 then
        rune.echo("[mapper] no bookmarks set.")
        return
    end
    table.sort(items, function(a, b) return a.text < b.text end)
    rune.ui.picker.show({
        title = "Bookmarks",
        items = items,
        on_select = function(uid) start_walk_to(uid) end,
    })
end, { name = "mapper-bookmark-pick" })

-- Bookmark any room by id: "mapper bookmark add <text> at <room#>"
rune.alias.regex("^mapper[ ]+bookmark[ ]+add[ ]+(.+) at ([0-9A-Fa-f]+)$", function(m)
    local text, id = m[1], m[2]
    if not store.get(id) then
        rune.echo("[mapper] warning: room " .. id .. " is not in the map")
    end
    store.set_bookmark(id, text)
    rune.echo("[mapper] bookmark set on " .. id .. ": " .. text)
end, { name = "mapper-bookmark-add-at", priority = 40 })

rune.alias.regex("^mapper[ ]+bookmark[ ]+add[ ]+(.+)$", function(m)
    local uid = cur_uid()
    if uid and store.set_bookmark(uid, m[1]) then
        rune.echo("[mapper] bookmark set on " .. uid .. ": " .. m[1])
    else
        rune.echo("[mapper] I don't know where you are.")
    end
end, { name = "mapper-bookmark-add" })

rune.alias.regex("^mapper[ ]+bookmark[ ]+del$", function()
    local uid = cur_uid()
    if uid and store.set_bookmark(uid, nil) then
        rune.echo("[mapper] bookmark cleared on " .. uid)
    else
        rune.echo("[mapper] I don't know where you are.")
    end
end, { name = "mapper-bookmark-del" })

-- Clear by room id (all-hex arg) ...
rune.alias.regex("^mapper[ ]+bookmark[ ]+del[ ]+([0-9A-Fa-f]+)$", function(m)
    local id = m[1]
    local r = store.get(id)
    if r and r.bookmark then
        store.set_bookmark(id, nil)
        rune.echo("[mapper] bookmark cleared on " .. id)
    else
        rune.echo("[mapper] no bookmark on room " .. id)
    end
end, { name = "mapper-bookmark-del-id", priority = 40 })

-- ... otherwise by (unique) name.
rune.alias.regex("^mapper[ ]+bookmark[ ]+del[ ]+(.+)$", function(m)
    local hits = bookmark_find(m[1])
    if #hits == 0 then
        rune.echo("[mapper] no bookmark matching '" .. m[1] .. "'")
        return
    end
    if #hits > 1 then
        rune.echo("[mapper] " .. #hits .. " bookmarks match '" .. m[1] .. "'; be more specific:")
        for _, h in ipairs(hits) do
            show_room_line(h.uid, h.room, "[" .. h.room.bookmark .. "]")
        end
        return
    end
    store.set_bookmark(hits[1].uid, nil)
    rune.echo("[mapper] bookmark cleared on " .. hits[1].uid ..
        " (" .. hits[1].room.bookmark .. ")")
end, { name = "mapper-bookmark-del-text", priority = 41 })

rune.alias.regex("^mapper[ ]+depth(|[ ]+([0-9]+|inf|off))$", function(m)
    if m[1] == "" then
        local v = rune.store.get("mapper.scan_depth")
        if v == nil or v == false then
            rune.echo("[mapper] depth: unlimited")
        else
            rune.echo("[mapper] depth: " .. tostring(v))
        end
    elseif m[2] == "inf" or m[2] == "off" then
        rune.store.set("mapper.scan_depth", false)
        rune.echo("[mapper] depth: unlimited")
    else
        local n = tonumber(m[2])
        if not n or n < 1 then
            rune.echo("[mapper] depth must be a positive integer or 'inf'")
        else
            rune.store.set("mapper.scan_depth", n)
            rune.echo("[mapper] depth: " .. n)
        end
    end
end, { name = "mapper-depth" })

rune.alias.regex("^mapper[ ]+sends(|[ ]+(on|off))$", function(m)
    local newval
    if m[1] == "" then
        local cur = rune.store.get("mapper.enable_speedwalk_sends")
        newval = not ((cur == nil) or (cur == true))
    elseif m[1] == "on" then
        newval = true
    else
        newval = false
    end
    rune.store.set("mapper.enable_speedwalk_sends", newval)
    rune.echo("[mapper] sends: " .. (newval and "ON (default)" or "OFF (dry-run)"))
end, { name = "mapper-sends" })

rune.alias.regex("^mapper[ ]+safewalk(|[ ]+(on|off))$", function(m)
    local cur = rune.store.get("mapper.safewalk") == true
    local newval
    if m[1] == "" then newval = not cur
    elseif m[1] == "on" then newval = true
    else newval = false end
    rune.store.set("mapper.safewalk", newval)
    rune.echo("[mapper] safewalk: " .. (newval and "ON" or "OFF"))
end, { name = "mapper-safewalk" })

rune.alias.regex("^mapper[ ]+announce(|[ ]+(on|off))$", function(m)
    local cur = rune.store.get("mapper.announce") == true
    local newval
    if m[1] == "" then newval = not cur
    elseif m[1] == "on" then newval = true
    else newval = false end
    rune.store.set("mapper.announce", newval)
    rune.echo("[mapper] announce room on move: " .. (newval and "ON" or "OFF"))
end, { name = "mapper-announce" })

rune.alias.regex("^mapper[ ]+map[ ]+wilds(|[ ]+(on|off))$", function(m)
    local cur = rune.store.get("mapper.map_wilds") == true
    local newval
    if m[1] == "" then newval = not cur
    elseif m[1] == "on" then newval = true
    else newval = false end
    rune.store.set("mapper.map_wilds", newval)
    rune.echo("[mapper] map wilds: " .. (newval and "ON" or "OFF") .. " (not yet enforced)")
end, { name = "mapper-map-wilds" })

rune.alias.regex("^mapper[ ]+dt(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target("dt", m[2], true)
end, { name = "mapper-dt" })
rune.alias.regex("^mapper[ ]+trap(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target("trap", m[2], true)
end, { name = "mapper-trap" })
rune.alias.regex("^mapper[ ]+no(|\-)speed(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target("no-speed", m[3], true)
end, { name = "mapper-no-speed" })
rune.alias.regex("^mapper[ ]+shop(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target("shop", m[2], true)
end, { name = "mapper-shop" })
rune.alias.regex("^mapper[ ]+train(|er)(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target("trainer", m[3], true)
end, { name = "mapper-trainer" })

rune.alias.regex("^mapper[ ]+untag[ ]+([^ ]+)(|[ ]+([0-9A-Fa-f]+))$", function(m)
    tag_target(m[1], m[3], false)
end, { name = "mapper-untag" })

rune.alias.regex("^mapper[ ]+save$", function()
    local ok2, err = store.save()
    rune.echo("[mapper] save: " .. (ok2 and "ok" or tostring(err)))
end, { name = "mapper-save" })

rune.alias.regex("^mapper[ ]+reload[ -_]db$", function()
    local before = store.count()
    local ok2, msg = store.load()
    rune.echo(string.format("[mapper] map reload: %s (was %d rooms, now %d)",
        ok2 and "ok" or "failed", before, store.count()))
end, { name = "mapper-reload-db" })

rune.alias.regex("^mapper[ ]+stats$", function()
    rune.echo("[mapper] " .. store.count() .. " rooms loaded.")
    rune.echo("[mapper] map dir: " .. store.file)
    rune.echo("[mapper] sends: " ..
        ((rune.store.get("mapper.enable_speedwalk_sends") == false) and "OFF (dry-run)" or "ON"))
    rune.echo("[mapper] safewalk: " .. ((rune.store.get("mapper.safewalk") == true) and "ON" or "OFF"))
    local depth = rune.store.get("mapper.scan_depth")
    if depth == nil or depth == false then
        rune.echo("[mapper] scan depth: unlimited")
    else
        rune.echo("[mapper] scan depth: " .. tostring(depth))
    end
    if store.position then
        rune.echo("[mapper] position: " .. store.position.uid ..
            " @ " .. tostring(store.position.area))
    end
end, { name = "mapper-stats" })


local function mapper_help()
    rune.echo(H.title("mapper (rooms, paths, bookmarks)"))
    rune.echo(H.section("Search:"))
    rune.echo(H.line("mapper nearby <name>", "this area -> picker; Enter walks"))
    rune.echo(H.line("mapper where <name>", "all areas -> picker; Enter walks"))
    rune.echo(H.line("mapper where <name> a:<area>", "picker, filtered by area"))
    rune.echo(H.line("mapper bookmark", "list bookmarks (add/goto/pick below)"))
    rune.echo(H.section("Navigation:"))
    rune.echo(H.line("mapper path <id>", "show path from here"))
    rune.echo(H.line("mapper path <id1> <id2>", "path between rooms"))
    rune.echo(H.line("mapper goto <id|name>", "walk there (picker if several match)"))
    rune.echo(H.line("mapper stop | resume", "abort / continue a walk"))
    rune.echo(H.section("Bookmarks:"))
    rune.echo(H.line("mapper bookmark add <text>", "bookmark the current room"))
    rune.echo(H.line("mapper bookmark add <text> at <#>", "bookmark any room by number", 32))
    rune.echo(H.line("mapper bookmark del [<text>|<#>]", "clear by name/#; bare = here", 32))
    rune.echo(H.line("mapper bookmark goto <text>", "walk to a bookmarked room"))
    rune.echo(H.line("mapper bookmark pick", "pick a bookmark and walk there"))
    rune.echo(H.section("Room info:"))
    rune.echo(H.line("mapper here", "show your current room #"))
    rune.echo(H.line("mapper roominfo [<id>] / peek <id>", ""))
    rune.echo(H.line("mapper adjacent [<name>]", "adjacent rooms with a different name"))
    rune.echo(H.section("Nearby by tag/flag:"))
    rune.echo(H.line("mapper safes / cpks / dts / shops / trainers", ""))
    rune.echo(H.line("mapper flags <pat> / notflags <pat>", ""))
    rune.echo(H.section("Settings:"))
    rune.echo(H.line("mapper sends [on|off]", "dry-run toggle (default ON)"))
    rune.echo(H.line("mapper depth [N|inf]", "BFS cap (default unlimited)"))
    rune.echo(H.line("mapper safewalk [on|off]", "avoid PK rooms and DTs"))
    rune.echo(H.line("mapper announce [on|off]", "echo room # on every move"))
    rune.echo(H.section("Tag current room:"))
    rune.echo(H.line("mapper dt / trap / no-speed / shop / trainer [<id>]", ""))
    rune.echo(H.line("mapper untag <tag> [<id>]", ""))
    rune.echo(H.section("Maintenance:"))
    rune.echo(H.line("mapper save | reload-db | stats", ""))
    rune.echo("")
    rune.echo(H.foot("Map: " .. store.file))
end

rune.alias.regex("^mapper$", mapper_help, { name = "mapper" })
rune.alias.regex("^mapper(|\_GMCP)(|( |\:)help)$", mapper_help, { name = "mapper-help" })
rune.alias.regex("^(|MM\_)GMCP\_Mapper(|_GMCP)(|( |\:)help)$", mapper_help, { name = "mm-gmcp-mapper-help" })
