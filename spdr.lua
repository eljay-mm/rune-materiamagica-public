-- spdr.lua -- named speedwalk destinations (port of MM's spdn).
--
-- Destination shortcuts come from the MM speedwalk DB converted to
-- mapper/spdr.json (uid -> { shortcut, desc }) and seeded into
-- rune.store["spdr.destinations"]. Add/remove with spdr add/del.

local mapstore = require("mapper_store")
local graph = require("mapper_graph")
local walk = require("mapper_walk")
local H = require("helpstyle")

local spdr = rune.store.get("spdr.destinations")
if type(spdr) ~= "table" then
    local f = io.open((rune.config_dir or ".") .. "/mapper/spdr.json", "r")
    if f then
        local text = f:read("*a")
        f:close()
        local data = rune.json.decode(text)
        if type(data) == "table" then
            spdr = data
            rune.store.set("spdr.destinations", spdr)
        end
    end
end
if type(spdr) ~= "table" then spdr = {} end

local function save()
    rune.store.set("spdr.destinations", spdr)
end

local function lookup(name)
    name = name:lower()
    for uid, e in pairs(spdr) do
        if type(e) == "table" and (e.shortcut or ""):lower() == name then
            return uid
        end
    end
end

-- Case-insensitive; "%" is a wildcard (segments must appear in order).
local function wild(text, needle)
    text = (text or ""):lower()
    needle = (needle or ""):lower()
    if needle == "" then return true end
    if not needle:find("%%") then
        return text:find(needle, 1, true) ~= nil
    end
    local pos = 1
    for part in needle:gmatch("[^%%]+") do
        local i = text:find(part, pos, true)
        if not i then return false end
        pos = i + #part
    end
    return true
end

local function rows(pred)
    local out = {}
    for uid, e in pairs(spdr) do
        if type(e) == "table" and (not pred or pred(e, uid)) then
            out[#out + 1] = { uid = uid, shortcut = e.shortcut or "?", desc = e.desc or "" }
        end
    end
    table.sort(out, function(a, b) return a.shortcut:lower() < b.shortcut:lower() end)
    return out
end

-- Walk to a room id using the shared map + step engine.
local function walk_to(uid)
    if not mapstore.get(uid) then
        rune.echo("[spdr] room " .. uid .. " is not in the map yet")
        return
    end
    local from = mapstore.position and mapstore.position.uid
    if not from then
        rune.echo("[spdr] I don't know where you are.")
        return
    end
    local matches, exhausted = graph.find_paths(from, function(u)
        if u == uid then return "dest" end
    end)
    local d = matches[uid]
    if not d then
        local hint = exhausted and " (depth limit hit; try `mapper depth inf`)" or ""
        rune.echo("[spdr] no path from " .. from .. " to " .. uid .. hint)
        return
    end
    if #d.path == 0 then
        rune.echo("[spdr] already there (" .. uid .. ")")
        return
    end
    rune.echo("[spdr] " .. uid .. " (" .. #d.path .. " steps): " .. graph.build_speedwalk(d.path))
    if rune.store.get("mapper.enable_speedwalk_sends") == false then
        rune.echo("[spdr] (sends disabled; `mapper sends on` to enable)")
        return
    end
    walk.start(d.path, uid)
end

-- One match -> walk; several -> picker (Enter walks).
local function picker(list, title)
    if #list == 0 then
        rune.echo("[spdr] no matching destinations")
        return
    end
    if #list == 1 then
        walk_to(list[1].uid)
        return
    end
    local items = {}
    for i = 1, math.min(#list, 1000) do
        local r = list[i]
        items[#items + 1] = {
            text = r.shortcut,
            desc = "#" .. r.uid .. "  " .. r.desc,
            value = r.uid,
        }
    end
    rune.ui.picker.show({
        title = title .. " (" .. #list .. ")",
        items = items,
        on_select = function(uid) walk_to(uid) end,
    })
end

local function help()
    rune.echo(H.title("spdr (named speedwalk destinations)"))
    rune.echo(H.section("Navigation:"))
    rune.echo(H.line("spdr <abbrev>", "walk to a destination"))
    rune.echo(H.section("Search:"))
    rune.echo(H.line("spdr <text>", "picker of matches; Enter walks"))
    rune.echo(H.line("spdr all", "picker of every destination"))
    rune.echo(H.section("Manage:"))
    rune.echo(H.line("spdr add <abbrev> <room#> <desc>", ""))
    rune.echo(H.line("spdr del <abbrev>", ""))
    rune.echo("")
    rune.echo(H.foot(#rows(nil) .. " destinations known; stored in rune.store"))
end

local function run(arg)
    if not arg or arg == "" then
        help()
        return
    end
    local uid = lookup(arg)
    if uid then
        walk_to(uid)
        return
    end
    picker(rows(function(e)
        return wild(e.desc, arg) or wild(e.shortcut, arg)
    end), "spdr: " .. arg)
end

rune.alias.regex("^spdr$", help, { name = "spdr" })

rune.alias.regex("^spdr[ ]+all$", function()
    picker(rows(nil), "spdr: all")
end, { name = "spdr-all", priority = 40 })

rune.alias.regex("^spdr[ ]+add[ ]+([^ ]+)[ ]+([0-9A-Fa-f]+)[ ]+(.+)$", function(m)
    spdr[m[2]] = { shortcut = m[1], desc = m[3] }
    save()
    rune.echo("[spdr] added " .. m[1] .. " -> " .. m[2])
end, { name = "spdr-add", priority = 40 })

rune.alias.regex("^spdr[ ]+del[ ]+([^ ]+)$", function(m)
    local uid = lookup(m[1])
    if not uid then
        rune.echo("[spdr] no destination named '" .. m[1] .. "'")
        return
    end
    spdr[uid] = nil
    save()
    rune.echo("[spdr] removed " .. m[1] .. " (room " .. uid .. ")")
end, { name = "spdr-del", priority = 40 })

rune.alias.regex("^spdr[ ]+(.+)$", function(m) run(m[1]) end, { name = "spdr-go" })
