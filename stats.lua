-- stats.lua -- HP/SP/ST prompt bar + the top character/wealth line.
--
-- MM prompts <3679hp 3196sp 3075st> after commands/rounds (sometimes with text
-- before or after). We rewrite the prompt in place into a one-line bar:
--   HP ██████████ 3679   SP ██████████ 3196   ST ██████████ 3075
-- Bar fills use the maxes from GMCP Char.MaxStats; without them the prompt
-- shows plain numbers.
--
-- The top line (the "worth" bar) carries the character name, level, and
-- wealth.

local style = rune.style

local maxes = {}     -- maxhp, maxsp, maxst
local worth = {}     -- gold, bank, qp, pracs
local status = {}    -- level, totallevel
local char_name

local function commas(n)
    n = tonumber(n)
    if not n then return nil end
    local s = tostring(math.floor(n))
    local k
    repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

local function gauge(cur, max, width, color)
    cur, max = tonumber(cur), tonumber(max)
    if not (cur and max) or max <= 0 then return "" end
    local filled = math.floor(width * cur / max + 0.5)
    if filled < 0 then filled = 0 elseif filled > width then filled = width end
    return color(string.rep("▰", filled)) ..
           style.gray(string.rep("▱", width - filled))
end

-- Pure yellow (RGB 255,255,0). SGR 33 ("yellow") renders as orange/amber in
-- many terminal themes.
local function yellow(s)
    return "\27[38;5;226m" .. tostring(s) .. "\27[0m"
end

local function hp_color(ratio)
    if ratio < 0.25 then return style.red end
    if ratio < 0.50 then return yellow end
    return style.green
end

-- Prompt bar -----------------------------------------------------------------

local BAR_MAX = 10

local function seg(label, cur, max, color, width)
    if max and max > 0 then
        return label .. " " .. gauge(cur, max, width, color) .. " " .. cur
    end
    return label .. " " .. cur
end

-- The prompt renders in the output pane; size the bars so the whole line
-- (including any prefix/suffix text) fits across it.
local function prompt_line(hp, sp, st, extra)
    local w = rune.state and rune.state.width or 0
    local pane = w > 0 and (w - math.floor(0.38 * w + 0.5)) or 68
    local nums = #tostring(hp) + #tostring(sp) + #tostring(st)
    local bar = math.floor((pane - (extra or 0) - nums - 18) / 3)
    if bar < 3 then bar = 3 elseif bar > BAR_MAX then bar = BAR_MAX end

    local hpcolor = style.green
    if maxes.maxhp and maxes.maxhp > 0 then
        hpcolor = hp_color(hp / maxes.maxhp)
    end
    return seg("HP", hp, maxes.maxhp, hpcolor, bar) .. "   " ..
           seg("SP", sp, maxes.maxsp, style.blue, bar) .. "   " ..
           seg("ST", st, maxes.maxst, yellow, bar)
end

-- Rewrite the prompt (<hp sp st>, with any text around it) into a bar line.
-- Off by default (`promptbar on` enables it). Splice into the raw line so any
-- prefix/suffix keeps its original colors, even when the prompt itself carries
-- color codes.
local function promptbar_on()
    local v = rune.store.get("stats.promptbar")
    if v == nil then return false end   -- default: off
    return v == true
end

-- Strip SGR escapes while remembering each kept character's index in raw.
local function clean_and_map(raw)
    local clean, map = {}, {}
    local i = 1
    while i <= #raw do
        local a, b = raw:find("\27%[[%d;]*m", i)
        if a == i then
            i = b + 1
        else
            clean[#clean + 1] = raw:sub(i, i)
            map[#map + 1] = i
            i = i + 1
        end
    end
    return table.concat(clean), map
end

rune.trigger.regex("^(.*)(<(\\d+)hp (\\d+)sp (\\d+)st>)(.*)$", function(m, ctx)
    if not promptbar_on() then return nil end
    local hp, sp, st = tonumber(m[3]), tonumber(m[4]), tonumber(m[5])
    -- Separate the prefix from the bar (e.g. "[*] HP …").
    local sep = (m[1] ~= "" and not m[1]:match("%s$")) and " " or ""
    local bar = prompt_line(hp, sp, st, #m[1] + #sep + #m[6])

    local raw = ctx.line:raw()
    local clean, map = clean_and_map(raw)
    local cs = clean:find(m[2], 1, true)   -- the prompt, ignoring its colors
    if cs then
        local rs, re = map[cs], map[cs + #m[2] - 1]
        -- Reset before the bar so the prefix's color doesn't bleed into the
        -- bar's plain labels; reset after so a suffix keeps its own codes.
        return raw:sub(1, rs - 1) .. sep .. "\27[0m" .. bar .. "\27[0m" ..
            raw:sub(re + 1)
    end
    return m[1] .. sep .. bar .. m[6]      -- fallback: cleaned rebuild
end, { name = "stats-prompt", on = "prompt" })

rune.alias.regex("^promptbar +(on|off)$", function(m)
    rune.store.set("stats.promptbar", m[1] == "on")
    rune.echo("[promptbar] " .. m[1])
end, { name = "promptbar-toggle" })

rune.alias.regex("^promptbar([ ]+help)?$", function()
    rune.echo("[promptbar] currently " .. (promptbar_on() and "on" or "off")
        .. " (promptbar on|off)")
end, { name = "promptbar-help" })

-- Top line -------------------------------------------------------------------

rune.ui.bar("worth", function()
    local name = char_name or rune.store.get("char_name") or "?"
    local head = name
    if status.level then
        head = name .. " (" .. status.level
        if status.totallevel then head = head .. "/" .. status.totallevel end
        head = head .. ")"
    end
    local parts = { head }
    local function add(label, v)
        local s = commas(v)
        if s then parts[#parts + 1] = style.magenta(label) .. " " .. s end
    end
    add("On Hand:", worth.gold)
    add("Bank:", worth.bank)
    add("Quest Points:", worth.qp)
    add("Practices:", worth.pracs)
    return table.concat(parts, "   ")
end)

-- GMCP -----------------------------------------------------------------------

rune.gmcp.subscribe("Char")

-- MM pushes most char data on its own, but maxstats has to be asked for, and
-- it does not re-send it when gear changes. MM ignores an empty body, so send
-- {"":""} (same as the MM MUSHclient scripts).
local last_request = 0
local function request_maxstats()
    if not rune.gmcp.is_enabled() then return end
    local now = os.time()
    if now - last_request < 1 then return end
    last_request = now
    rune.gmcp.send("char.maxstats", { [""] = "" })
end

local function request_all()
    request_maxstats()
    if rune.gmcp.is_enabled() then
        rune.gmcp.send("char.status", { [""] = "" })
        rune.gmcp.send("char.worth", { [""] = "" })
        rune.gmcp.send("char.base", { [""] = "" })
    end
end

-- A fresh connect negotiates GMCP before character login, so the
-- connect-time requests can be ignored. Re-send the subscription and ask
-- again once we're in-game.
local requested = false
local function on_login()
    if requested then return end
    requested = true
    request_all()
end

-- Re-sending Core.Supports.Set after login seems to make MM push Char.*.
local function resync_gmcp()
    rune.gmcp.unsubscribe("Char")
    rune.gmcp.subscribe("Char")
    requested = true
    request_all()
end

-- Safety net: keep re-requesting until we have the maxes, then stop.
local bootstrap
local function stop_bootstrap()
    if bootstrap then bootstrap:remove(); bootstrap = nil end
end

local function start_bootstrap()
    stop_bootstrap()
    local attempts = 0
    bootstrap = rune.timer.every(2, function(ctx)
        if (maxes.maxhp and status.level) or attempts >= 15 then
            ctx:remove(); bootstrap = nil
            return
        end
        attempts = attempts + 1
        resync_gmcp()
    end, { name = "stats-bootstrap" })
end

rune.hooks.on("connecting", function()
    requested = false
    start_bootstrap()
end, { name = "stats-login-reset" })

-- In-game banners: reconnect and fresh login.
rune.trigger.regex("Welcome( back)? to Materia Magica", resync_gmcp,
    { name = "stats-welcome" })
rune.trigger.regex("^You are player \\[", resync_gmcp,
    { name = "stats-welcome-fresh" })

rune.hooks.on("gmcp_enabled", request_all,
    { name = "stats-request", priority = 200 })
rune.hooks.on("reloaded", request_all, { name = "stats-reload-request" })

rune.gmcp.on("Char.MaxStats", function(data)
    maxes.maxhp = tonumber(data.maxhp)
    maxes.maxsp = tonumber(data.maxsp)
    maxes.maxst = tonumber(data.maxst)
end, { name = "stats-max" })

rune.gmcp.on("Char.Status", function(data)
    status.level = data.level
    status.totallevel = data.totallevel
    rune.ui.refresh_bars()
end, { name = "stats-status" })

rune.gmcp.on("Char.Worth", function(data)
    worth = data or {}
    rune.ui.refresh_bars()
end, { name = "stats-worth" })

rune.gmcp.on("Char.Base", function(data)
    local name = data and data.name
    if name and name ~= rune.store.get("char_name") then
        rune.store.set("char_name", name)
        char_name = name
        rune.ui.refresh_bars()
    end
    on_login()
end, { name = "stats-name" })

-- Manual refresh, e.g. right after swapping gear.
rune.alias.regex("^resync (max)?stats$", function()
    request_all()
    rune.echo("[stats] requested stats")
end, { name = "stats-resync" })

-- Refresh maxes when equipment changes.
local gear_lines = {
    "You wear ",
    "You wield ",
    "You hold ",
    "You suspend ",
    "You perform a small ritual surrounding ",
    "You call upon ",
    "You stop using ",
}
for i, phrase in ipairs(gear_lines) do
    rune.trigger.starts(phrase, request_maxstats, {
        name = "stats-gear-" .. i,
        group = "stats-gear",
    })
end
