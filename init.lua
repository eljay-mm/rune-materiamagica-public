-- Rune config for Materia Magica. Every bookmark shares this one config;
-- there are no per-character profiles.
--   rune login   -- auto-types YourCharacter at the login prompt
--   rune mm     -- blank profile, type any character

-- "login" carries the character to auto-login.
rune.world.add("login", "materiamagica.com:4000", { character = "YourCharacter" })
-- Same server, but a differently-spelled address so it doesn't match
-- login's auto-login (Rune reports the address exactly as stored and has no
-- per-bookmark login hook). DNS hostnames are case-insensitive.
rune.world.add("mm", "MateriaMagica.com:4000")

local pending_character

rune.hooks.on("connecting", function(addr)
    pending_character = nil
    for _, w in ipairs(rune.world.list()) do
        local entry = rune.world.get(w.name)
        if entry.address == addr and entry.character then
            pending_character = entry.character
        end
    end
end, { name = "autologin-arm" })

local function send_character()
    if pending_character then
        rune.send_raw(pending_character)
        pending_character = nil
    end
end

-- The login prompt arrives without a trailing newline.
rune.trigger.contains("By what name shall we know thee?", send_character,
    { name = "autologin-name-prompt", on = "prompt" })
rune.trigger.contains("By what name shall we know thee?", send_character,
    { name = "autologin-name-line" })

-- Keep the last command in the input line, selected: Enter resends it,
-- typing replaces it. Off by default.
rune.config.set("keep_input", true)

-- Mouse wheel scrollback is left to the terminal so copy/paste behaves
-- normally. Scroll the game output with PgUp/PgDn or Ctrl+F instead.
-- To let Rune capture the wheel instead, set this to true (then use
-- Shift+drag to select text):
-- rune.config.set("mouse", true)

-- Comms pane: tell/clan/PK-talk routing, scroll binds, aliases.
-- See comms.lua.
require("comms")

-- Wound lines -> inline target health bar. See enemy.lua.
require("enemy")

-- HP/SP/ST prompt bar and the top character/wealth line. See stats.lua.
require("stats")

-- Quest detail pane, populated by viewing a quest (`quest status <vnum>`).
-- See quests.lua.
require("quests")

-- Materia Magica mapper: room DB, pathfinding, step-by-step walking.
-- See mapper.lua (map data in mapper/map.db).
require("mapper")

-- Local browser map of the mapper, wired both ways (`/webmap on`).
-- See webmap.lua (server + front end in webmap/).
-- Only loaded when the webmap add-on is present: the public copy of this
-- config ships without it, so guard the require instead of erroring.
local webmap_file = io.open((rune.config_dir or ".") .. "/webmap.lua", "r")
if webmap_file then
    webmap_file:close()
    require("webmap")
end

-- Terrain indicator in the room header. See terrain.lua.
require("terrain")

-- Named speedwalk destinations (`spdr`). See spdr.lua.
require("spdr")

-- Hide/show all panes at once (`/panes`). See panes.lua.
require("panes")

-- Pouch of plenitude auto-looter/sorter (`autopouch`). See autopouch.lua.
require("autopouch")

-- Autowalk the directions from a `sense` (`sense`). See sense.lua.
require("sense")

-- Simple scheduled commands (e.g. twiddle every 5 min). See timers.lua.
require("timers")

-- Layout ---------------------------------------------------------------------
-- The top-level UI tree lives here, with the config it describes.
--
-- Panes have no runtime title setter, so changing a title means re-declaring
-- the layout: stats/quests/comms call rune_build_layout(...) again when their
-- title changes. Hidden pane states are read back and preserved across that.
--
-- The top line is the character/wealth bar; below it the output and the
-- comms/quests sidebar. Panes have no runtime title setter, so quests/comms
-- re-declare the layout when their title changes; hidden pane states are
-- preserved across that.
function rune_build_layout(quests_title, comms_title)
    comms_title = comms_title or rune.comms_title or "Comms"
    rune.ui.layout({
        type = "column",
        children = {
            { type = "bar", name = "worth" },
            { type = "row", size = "1fr", children = {
                { type = "pane", name = "output", size = "1fr",
                  border = "none" },
                { type = "column", size = "38%", children = {
                    { type = "pane", name = "comms", size = "50%",
                      border = "full", title = comms_title,
                      hidden = rune.pane.is_hidden("comms") or false },
                    -- explicit 1-row gap so the panes read as separate boxes
                    { type = "pane", name = "pad_gap", size = 1, border = "none" },
                    { type = "pane", name = "quests", size = "1fr",
                      border = "full", title = quests_title or "Quests",
                      hidden = rune.pane.is_hidden("quests") or false },
                    -- 1-row bottom margin before the input line
                    { type = "pane", name = "pad_b", size = 1, border = "none" },
                }},
            }},
            { type = "input" },
            { type = "bar", name = "status" },
        },
    })
end

rune_build_layout(rune.store.get("quest_title"))
