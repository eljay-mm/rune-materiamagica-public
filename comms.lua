-- comms.lua -- communication-channel pane with a per-channel filter.
--
-- Routes tells/clan/talk into a dedicated pane. The pane is a copy: the
-- main output still receives every line (never gagged). A capped buffer holds
-- all channels so switching the filter can replay history; that buffer is
-- persisted across restarts. The filter itself is per-session (starts "all").
--
-- MM-specific formats: tweak the regexes below if they change.

local H = require("helpstyle")

rune.pane.create("comms")

local CAP = 500
local FILTERS = { all = true, tell = true, clan = true, talk = true, relay = true }
local TITLES = { all = "all", tell = "tells", clan = "clan", talk = "talk", relay = "relay" }

-- The filter is per-session: always starts on "all".
local filter = "all"

-- The pane title reflects the filter; changing it re-declares the layout
-- (panes have no runtime title setter).
rune.comms_title = "Comms (" .. TITLES[filter] .. ")"

-- Ordered history of every routed line: { category = "...", raw = "..." }.
-- Persisted (capped) so the pane survives a restart/reload.
local history = {}
local dirty = false

do
    local saved = rune.store.get("comms.history")
    if type(saved) == "table" then
        for _, e in ipairs(saved) do
            local cat, raw = e.c, e.r
            if FILTERS[cat] and type(raw) == "string" then
                history[#history + 1] = { category = cat, raw = raw }
            end
        end
        while #history > CAP do table.remove(history, 1) end
    end
end

local function save_history()
    if not dirty then return end
    dirty = false
    local out = {}
    for i, e in ipairs(history) do
        out[i] = { c = e.category, r = e.raw }
    end
    rune.store.set("comms.history", out)
end

local function pane_matches(category)
    return filter == "all" or filter == category
end

local function mirror(text, category)
    history[#history + 1] = { category = category, raw = text }
    dirty = true
    while #history > CAP do table.remove(history, 1) end
    if pane_matches(category) then
        rune.pane.write("comms", text)
    end
    -- Always pass through to main output; never gag.
    return nil
end

local function replay()
    rune.pane.clear("comms")
    for _, entry in ipairs(history) do
        if pane_matches(entry.category) then
            rune.pane.write("comms", entry.raw)
        end
    end
end

local function set_filter(f)
    if not FILTERS[f] then return end
    if f == filter then
        rune.echo("[comms] showing: " .. f)
        return
    end
    filter = f
    rune.comms_title = "Comms (" .. TITLES[f] .. ")"
    if rune_build_layout then
        rune_build_layout(rune.store.get("quest_title"), rune.comms_title)
    end
    replay()
    rune.echo("[comms] showing: " .. f)
end

rune.trigger.regex("^([^\\s]+) tells you '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "tell")
end, { name = "comms-tell-in" })

rune.trigger.regex("^You tell ([^\\s]+) '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "tell")
end, { name = "comms-tell-out" })

rune.trigger.regex("^\\[CLAN\\] ([^\\s]+): '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "clan")
end, { name = "comms-clan-in" })

rune.trigger.regex("^\\[CLAN\\] (.+) has entered Materia Magica\\.$",
    function(m, ctx)
        return mirror(ctx.line:raw(), "clan")
    end, { name = "comms-clan-entered" })

rune.trigger.regex("^\\[CLAN\\] (.+) has left Materia Magica\\.$",
    function(m, ctx)
        return mirror(ctx.line:raw(), "clan")
    end, { name = "comms-clan-left" })

rune.trigger.regex(
    "^\\[(\\d+)\\] clan members heard you say, '(.+)'$",
    function(m, ctx)
        return mirror(ctx.line:raw(), "clan")
    end,
    { name = "comms-clan-out" })

-- Talk (PK channels): two forms.
--   With count suffix:    [TALK A|B|C] <who>: '<msg>' [<n online>]
--   Without count suffix: [TALK A|B|C] <who>: '<msg>'
-- Two plain triggers rather than one regex with alternation, to stay
-- within the subset of syntax Rune's regex wrapper accepts.

rune.trigger.regex(
    "^\\[TALK [ABC]\\] ([^\\s]+): '(.+)' \\[(\\d+)\\]$",
    function(m, ctx)
        return mirror(ctx.line:raw(), "talk")
    end,
    { name = "comms-talk-counted" })

rune.trigger.regex(
    "^\\[TALK [ABC]\\] ([^\\s]+): '(.+)'$",
    function(m, ctx)
        return mirror(ctx.line:raw(), "talk")
    end,
    { name = "comms-talk-bare" })

-- Relay channels:
--   in:  <player>@<#channel>: <message>
--   out: [<n>] people in <#channel> heard you relay '<message>'
rune.trigger.regex("^([^@\\s]+)@(#[^:\\s]+): (.+)$", function(m, ctx)
    return mirror(ctx.line:raw(), "relay")
end, { name = "comms-relay-in" })

rune.trigger.regex("^\\[\\d+\\] .* heard you relay '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "relay")
end, { name = "comms-relay-out" })

-- Scroll the comms pane. Rune's default pgup/pgdown/ctrl+home/ctrl+end
-- target the reserved output pane only, so comms needs its own binds.
-- shift+pgup/pgdown is grabbed by some terminals for scrollback, so
-- ctrl+alt+pgup / ctrl+alt+pgdown is the working pair.
local function comms_up()
    rune.pane.scroll_up("comms", 5)
end
local function comms_down()
    rune.pane.scroll_down("comms", 5)
end

rune.bind("ctrl+alt+pgup",   comms_up,   { group = "comms" })
rune.bind("ctrl+alt+pgdown", comms_down, { group = "comms" })

rune.alias.regex(
    "^comms[ ]+(show|hide|toggle|clear|top|bottom|all|tell|clan|talk|relay)$",
    function(m)
        local cmd = m[1]
        if cmd == "clear" then
            history = {}
            dirty = true
            save_history()
            rune.pane.clear("comms")
            rune.echo("[comms] cleared")
        elseif cmd == "top" then
            rune.pane.scroll_to_top("comms")
        elseif cmd == "bottom" then
            rune.pane.scroll_to_bottom("comms")
        elseif FILTERS[cmd] then
            set_filter(cmd)
        else
            local on = rune.pane.toggle("comms")
            rune.echo("[comms] " .. (on and "shown" or "hidden"))
        end
    end, { name = "comms-toggle" })

rune.alias.regex("^comms([ ]+help)?$", function()
    rune.echo(H.title("comms pane (tells, clan, talk, relay)"))
    rune.echo(H.line("comms show | hide | toggle", "show/hide the comms pane"))
    rune.echo(H.line("comms all | tell | clan | talk | relay", "show only that channel (all are buffered)"))
    rune.echo(H.line("comms clear", "clear the buffer and the pane"))
    rune.echo(H.line("comms top | bottom", "jump to buffer extremes"))
    rune.echo(H.line("ctrl+alt+pgup | ctrl+alt+pgdown", "scroll comms pane (5 lines)", 34))
    rune.echo("")
    rune.echo(H.foot("Lines matching the tell/clan/talk/relay patterns are written to the pane AND pass through the main output (never gagged)."))
end, { name = "comms-help" })

-- Persistence: replay the saved buffer once the UI is up, and save it
-- periodically (plus on disconnect). The filter is not persisted.
rune.hooks.on("ready", replay, { name = "comms-initial-replay" })
rune.timer.every(5, save_history, { name = "comms-save" })
rune.hooks.on("disconnected", save_history, { name = "comms-save-disconnect" })
