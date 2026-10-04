-- terrain.lua -- terrain indicator in the room header.
--
-- Port of the MUSHclient terrain_o_vision plugin: MM prints a room header like
--   (-----------------------------------------------) Room Name
-- and GMCP room.info carries `terraininfo`. Gag the header and reprint it with
-- the terrain embedded in the dashes. A header with no fresh room.info behind
-- it (peeking in a direction, televiewing) shows "?" instead.
--
-- Only the terrain types in KEEP are shown; a room with none of them keeps its
-- header unchanged.

local style = rune.style

rune.gmcp.subscribe("Room")

local terrain_pending = nil

rune.gmcp.on("Room.Info", function(data)
    terrain_pending = data and data.terraininfo or nil
end, { name = "terrain-room-pending" })

-- GMCP terraininfo tokens we care about, and how they're displayed.
local KEEP = {
    diggable = "dig",
    hard = "hard",
    sheltered = "sheltered",
    underwater = "underwater",
}

local function filter_terrain(info)
    local out = {}
    for token in info:gmatch("%S+") do
        local shown = KEEP[token]
        if shown then out[#out + 1] = shown end
    end
    return table.concat(out, " ")
end

local terrain_trigger = rune.trigger.regex(
    "^(\\([^)]*--[^)]*\\))( +)(.+)$",
    function(_, ctx)
        local raw = ctx.line:raw()
        local terrain = terrain_pending
        terrain_pending = nil

        if terrain then
            terrain = filter_terrain(terrain)
            if terrain == "" then
                -- Nothing we show on this room: leave the header as-is.
                rune.echo(raw)
                return
            end
        else
            terrain = "?"
        end

        -- Splice into the raw line so the original colors and anything else
        -- on the line (room name, tags, ...) are preserved untouched. The
        -- terrain words are cyan; the dashes keep the run's own colour.
        local s, e = raw:find("%-%-%-%-%-+")
        if s then
            local prefix, suffix = raw:sub(1, s - 1), raw:sub(e + 1)
            local sgr = "\027[0m"
            for code in prefix:gmatch("\027%[[%d;]*m") do sgr = code end
            local before = math.max(1, (e - s + 1) - #terrain - 3)
            raw = prefix .. string.rep("-", before) ..
                style.cyan(terrain) .. sgr .. "---" .. suffix
        end
        rune.echo(raw)
    end,
    { name = "terrain-roomline", gag = true })

rune.command.add("terrain", function(args)
    local mode = (args or ""):match("^%s*(%S+)")
    if mode == "off" or mode == "normal" then
        terrain_trigger:disable()
        rune.echo("[terrain] off")
    else
        terrain_trigger:enable()
        rune.echo("[terrain] on")
    end
end, "Show terrain in the room header (/terrain on|off)")
