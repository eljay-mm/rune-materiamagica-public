-- sense.lua -- auto-walk the directions MM gives from a "sense".
--
--   You sense that sigil-underground may be located w, w, w, w, n, n, n, w, n.
--
-- The place name and the direction list both vary. On that line we walk the
-- directions step-by-step (waiting for each Room.Info), so it can be stopped
-- and won't desync. `sense off` disables the autowalk; `sense on` re-enables.

local H = require("helpstyle")
local walk = require("mapper_walk")

local DIRS = {
    n = true, s = true, e = true, w = true,
    ne = true, nw = true, se = true, sw = true, u = true, d = true,
    north = true, south = true, east = true, west = true, up = true, down = true,
    northeast = true, northwest = true, southeast = true, southwest = true,
}

local function auto()
    local v = rune.store.get("sense.auto")
    if v == nil then return true end    -- default: on
    return v == true
end

local function split_dirs(list)
    local dirs = {}
    for tok in list:gmatch("[^,%s]+") do
        tok = tok:lower()
        if DIRS[tok] then dirs[#dirs + 1] = tok end
    end
    return dirs
end

local function start(place, dirs)
    if #dirs == 0 then
        rune.echo("[sense] no usable directions for " .. place)
        return
    end
    rune.echo(string.format("[sense] walking %d steps to %s: %s",
        #dirs, place, table.concat(dirs, " ")))
    walk.start_dirs(dirs, place)
end

rune.trigger.regex("^You sense that (.+) may be located (.+)\\.$", function(m)
    local place, list = m[1], m[2]
    local dirs = split_dirs(list)
    if auto() then
        start(place, dirs)
    else
        rune.echo(string.format("[sense] %s may be %s (%s)",
            place, table.concat(dirs, " "), "sense on to autowalk"))
    end
end, { name = "sense-line" })

-- A blocked move means the sensed route failed; stop rather than stall out.
for i, phrase in ipairs({ "cannot go that way", "You can't go that way",
                          "Alas, you cannot go" }) do
    rune.trigger.contains(phrase, function()
        if walk.is_active() then
            rune.echo("[sense] blocked ('" .. phrase .. "'); stopped.")
            walk.stop()
        end
    end, { name = "sense-blocked-" .. i })
end

local function help()
    rune.echo(H.title("sense - autowalk the directions from a sense"))
    rune.echo(H.section("Commands:"))
    rune.echo(H.line("sense on | off", "toggle autowalking the sense line"))
    rune.echo(H.line("sense stop", "abort a sensed walk"))
    rune.echo("")
    rune.echo(H.foot("autowalk is " .. (auto() and "on" or "off")
        .. "; walks step-by-step, stopping if a move is blocked."))
end

rune.alias.regex("^sense([ ]+help)?$", help, { name = "sense-help" })

rune.alias.regex("^sense[ ]+(on|off)$", function(m)
    rune.store.set("sense.auto", m[1] == "on")
    rune.echo("[sense] autowalk " .. m[1])
end, { name = "sense-toggle" })

rune.alias.regex("^sense[ ]+stop$", function()
    walk.stop()
    rune.echo("[sense] stopped")
end, { name = "sense-stop" })
