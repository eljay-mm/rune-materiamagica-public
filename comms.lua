-- comms.lua -- communication-channel pane with a per-channel filter.
--
-- Routes tells/clan/talk/relay/formation/alliance into a dedicated pane. The
-- pane is a copy: the main output still receives every line (never gagged).
-- A capped buffer holds all channels so switching the filter can replay
-- history; that buffer is persisted across restarts, separately for each
-- character. The filter itself is per-session (starts "all").
--
-- The character name comes from GMCP (see PACKAGES / NAME_FIELDS below), so
-- the saved history is loaded once the name arrives after connecting. Lines
-- routed before that are held in memory and merged in.
--
-- MM-specific formats: tweak the regexes below if they change.

local H = require("helpstyle")

rune.pane.create("comms")

local CAP = 500
local FILTERS = { all = true, tell = true, clan = true, talk = true, relay = true, form = true, ally = true }
local TITLES = { all = "all", tell = "tells", clan = "clan", talk = "talk", relay = "relay", form = "form", ally = "ally" }

-- GMCP packages that might carry the character name, and the fields to try.
local PACKAGES = { "Char.Info", "Char.Base", "Char.Status", "Char.Name" }
local NAME_FIELDS = { "name", "charname", "character", "char" }

-- Character identity, set from GMCP. Until then history is memory-only.
local charname = nil
local history_key = nil
local gmcp_debug = false

-- The filter is per-session: always starts on "all".
local filter = "all"

-- The pane title reflects the filter; changing it re-declares the layout
-- (panes have no runtime title setter).
rune.comms_title = "Comms (" .. TITLES[filter] .. ")"

-- Ordered history of every routed line: { category = "...", raw = "..." }.
-- Persisted (capped) so the pane survives a restart/reload.
local history = {}
local dirty = false

local function sanitize(name)
    -- Safe for storage keys; lowercase so GMCP capitalisation never matters.
    local s = tostring(name or ""):gsub("[^%w_-]", "_"):lower()
    return s
end

local function load_history(key)
    local out = {}
    local saved = rune.store.get(key)
    if type(saved) == "table" then
        for _, e in ipairs(saved) do
            local cat, raw = e.c, e.r
            if FILTERS[cat] and type(raw) == "string" then
                out[#out + 1] = { category = cat, raw = raw }
            end
        end
        while #out > CAP do table.remove(out, 1) end
    end
    return out
end

local function save_history()
    if not dirty or not history_key then return end
    dirty = false
    local out = {}
    for i, e in ipairs(history) do
        out[i] = { c = e.category, r = e.raw }
    end
    rune.store.set(history_key, out)
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

-- Called when GMCP tells us who we are (or that we switched characters).
local function adopt_name(raw_name)
    local name = sanitize(raw_name)
    if name == "" or name == charname then return end

    local pending = history   -- lines routed before the name was known

    if charname then
        -- Switched characters: persist the old one, start the new one clean.
        save_history()
        pending = {}
    end

    charname = name
    history_key = "comms.history." .. name

    local merged = load_history(history_key)
    for _, e in ipairs(pending) do
        merged[#merged + 1] = e
    end
    while #merged > CAP do table.remove(merged, 1) end

    history = merged
    dirty = (#pending > 0)
    replay()
end

local function name_from(data)
    if type(data) == "string" then
        return data
    end
    if type(data) == "table" then
        for _, field in ipairs(NAME_FIELDS) do
            local v = data[field]
            if type(v) == "string" and v ~= "" then
                return v
            end
        end
    end
    return nil
end

local function describe(data)
    if type(data) ~= "table" then return tostring(data) end
    local parts = {}
    for k, v in pairs(data) do
        if type(v) ~= "table" and type(v) ~= "function" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

if rune.gmcp and rune.gmcp.on then
    for _, package in ipairs(PACKAGES) do
        pcall(rune.gmcp.on, package, function(data)
            if gmcp_debug then
                rune.echo("[comms] " .. package .. ": " .. describe(data))
            end
            local n = name_from(data)
            if n then adopt_name(n) end
        end)
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

-- Formation tells:
--   in:  <player> tells the formation '<message>'
--   out: You tell the formation '<message>'
rune.trigger.regex("^([^\\s]+) tells the formation '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "form")
end, { name = "comms-form-in" })

rune.trigger.regex("^You tell the formation '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "form")
end, { name = "comms-form-out" })

-- Alliance:
--   in:  [ALLIED <num>] ...
--   out: [<num>] alliance members heard you say, '<message>'
rune.trigger.regex("^\\[ALLIED (\\d+)\\] (.+)$", function(m, ctx)
    return mirror(ctx.line:raw(), "ally")
end, { name = "comms-ally-in" })

rune.trigger.regex("^\\[(\\d+)\\] alliance members heard you say, '(.+)'$", function(m, ctx)
    return mirror(ctx.line:raw(), "ally")
end, { name = "comms-ally-out" })

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
    "^comms[ ]+(show|hide|toggle|clear|top|bottom|all|tell|clan|talk|relay|form|ally|debug|name)$",
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
        elseif cmd == "debug" then
            gmcp_debug = not gmcp_debug
            rune.echo("[comms] GMCP debug " .. (gmcp_debug and "ON" or "OFF"))
        elseif cmd == "name" then
            rune.echo("[comms] character: " .. (charname or "(not yet received via GMCP)"))
        elseif FILTERS[cmd] then
            set_filter(cmd)
        else
            local on = rune.pane.toggle("comms")
            rune.echo("[comms] " .. (on and "shown" or "hidden"))
        end
    end, { name = "comms-toggle" })

rune.alias.regex("^comms([ ]+help)?$", function()
    rune.echo(H.title("comms pane (tells, clan, talk, relay, formation, alliance)"))
    rune.echo(H.line("comms show | hide | toggle", "show/hide the comms pane"))
    rune.echo(H.line("comms all | tell | clan | talk | relay | form | ally", "show only that channel (all are buffered)"))
    rune.echo(H.line("comms clear", "clear the buffer and the pane"))
    rune.echo(H.line("comms top | bottom", "jump to buffer extremes"))
    rune.echo(H.line("comms name | debug", "show GMCP character name / dump GMCP name packages"))
    rune.echo(H.line("ctrl+alt+pgup | ctrl+alt+pgdown", "scroll comms pane (5 lines)", 34))
    rune.echo("")
    rune.echo(H.foot("Lines matching the tell/clan/talk/relay/formation/alliance patterns are written to the pane AND pass through the main output (never gagged)."))
end, { name = "comms-help" })

-- Persistence: replay the buffer once the UI is up, and save it
-- periodically (plus on disconnect). The filter is not persisted.
rune.hooks.on("ready", replay, { name = "comms-initial-replay" })
rune.timer.every(5, save_history, { name = "comms-save" })
rune.hooks.on("disconnected", save_history, { name = "comms-save-disconnect" })
