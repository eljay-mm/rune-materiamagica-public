-- quests.lua -- quest pane (GMCP only).
--
-- Viewing a quest in-game (`quest status <vnum>`) selects it -> detail view.
-- With nothing selected (e.g. it just expired) the pane lists the quests
-- you're on. Expired quests are dropped by their GMCP timer; completed or
-- abandoned ones are dropped by reconciling against full char.quests
-- snapshots.

rune.pane.create("quests")
rune.gmcp.subscribe("Quest")

local style = rune.style
local quests = {}      -- numeric vnum -> quest table
local selected = tonumber(rune.store.get("quest_vnum"))  -- currently shown vnum
local title = nil      -- last pane title we set

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truthy(v)
    return v == true or v == 1 or v == "1" or v == "true"
end

local function clean_goal(s)
    if not s then return "" end
    s = s:gsub("[\r\n]+", " ")
    s = s:gsub("^%s*%*?Phase%s*%d+:%s*%*?", "")
    return trim(s:gsub("%s+", " "))
end

local function is_hidden(text)
    return text:match("%(Hidden until") ~= nil
end

local function phase_line(num, text, done, current)
    local line = string.format("%s %s: %s", done and "[x]" or "[ ]", num, text)
    if done then return style.green(line) end
    if is_hidden(text) then return style.gray(line) end
    if current then return style.bold(style.yellow(line)) end
    return line
end

local function format_remaining(secs)
    secs = math.max(0, math.floor(secs))
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if d > 0 then
        return string.format("%dd %02dh %02dm %02ds", d, h, m, s)
    elseif h > 0 then
        return string.format("%02dh %02dm %02ds", h, m, s)
    elseif m > 0 then
        return string.format("%02dm %02ds", m, s)
    end
    return string.format("%02ds", s)
end

-- Replace the whole pane. replace() alone doesn't blank cells beyond a now
-- shorter line, so clear first -- but only when the content actually shrinks
-- (detail <-> list <-> empty, or a line getting shorter). Per-second timer
-- ticks keep the same size, so they never clear (no flicker).
local function visible_len(s)
    return #(s:gsub("\27%[[%d;]*m", ""))
end

local last_lines, last_len = 0, 0

local function render_block(out)
    local text = table.concat(out, "\n")
    local len = visible_len(text)
    if #out ~= last_lines or len < last_len then
        rune.pane.clear("quests")
    end
    last_lines, last_len = #out, len
    rune.pane.replace("quests", text)
end

-- Effective expiry (epoch); untimed quests sort last.
local function expiry(q)
    local t = tonumber(q.quest_info and q.quest_info.timer)
    if t and t > 0 then return t end
    return math.huge
end

local function is_expired(q)
    local t = tonumber(q.quest_info and q.quest_info.timer)
    return t and t > 0 and os.time() >= t or false
end

local function quest_progress(q)
    local goals = q.goals or {}
    local done = 0
    for i = 1, #goals do
        if truthy(goals[i].phase_complete) then done = done + 1 end
    end
    return done, #goals
end

local function set_title(text)
    if text == title then return end
    title = text
    rune.store.set("quest_title", text)
    if rune_build_layout then
        rune_build_layout(text)
    end
end

local function clear_selection()
    selected = nil
    rune.store.set("quest_vnum", "")
end

local function render_detail(vnum, q)
    local goals = q.goals or {}
    local total, done, current = #goals, 0, nil
    for i = 1, total do
        if truthy(goals[i].phase_complete) then done = done + 1
        elseif not current then current = i end
    end

    local out = { string.format("%d/%d phases", done, total) }
    for i = 1, total do
        local g = goals[i]
        out[#out + 1] = phase_line(g.phase_number or i,
            clean_goal(g.goal_string), truthy(g.phase_complete), current == i)
    end
    local t = tonumber(q.quest_info and q.quest_info.timer)
    if t and t > 0 then
        local left = t - os.time()
        if left > 0 then
            out[#out + 1] = style.yellow("Time: " .. format_remaining(left))
        else
            out[#out + 1] = style.red("Time: expired")
        end
    end

    render_block(out)
end

local function render_list()
    local items = {}
    for vnum, q in pairs(quests) do
        items[#items + 1] = { vnum = vnum, q = q, t = expiry(q) }
    end
    table.sort(items, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        local an = (a.q.quest_info and a.q.quest_info.name) or ""
        local bn = (b.q.quest_info and b.q.quest_info.name) or ""
        if an ~= bn then return an < bn end
        return a.vnum < b.vnum
    end)

    local out = {}
    for _, it in ipairs(items) do
        local qi = it.q.quest_info or {}
        local done, total = quest_progress(it.q)
        out[#out + 1] = string.format("#%d %s", it.vnum, qi.name or "?")
        local sub = string.format("   %d/%d phases", done, total)
        local t = tonumber(qi.timer)
        if t and t > 0 then
            local left = t - os.time()
            sub = sub .. "   " ..
                (left > 0 and ("Time: " .. format_remaining(left)) or "expired")
        end
        out[#out + 1] = style.gray(sub)
    end
    render_block(out)
end

local function render()
    if selected then
        local q = quests[selected]
        if not q then return end
        local name = (q.quest_info and q.quest_info.name) or "?"
        set_title("Quest #" .. selected .. " (" .. name .. ")")
        render_detail(selected, q)
        return
    end

    local n = 0
    for _ in pairs(quests) do n = n + 1 end
    if n > 0 then
        set_title("Quests (" .. n .. ")")
        render_list()
    else
        set_title("Quests")
        render_block({
            style.gray("No active quests."),
            style.gray("Ask a questmaster for one."),
        })
    end
end

-- Remove every quest whose GMCP timer has run out. Returns whether any went.
local function sweep_expired()
    local changed = false
    for vnum, q in pairs(quests) do
        if is_expired(q) then
            quests[vnum] = nil
            changed = true
            if vnum == selected then clear_selection() end
        end
    end
    return changed
end

-- Merge a (possibly partial) quest payload into quests[v].
local function merge_quest(v, src)
    local dst = quests[v]
    if not dst then
        dst = { quest_info = { vnum = v }, goals = {} }
        quests[v] = dst
    end
    if type(src.quest_info) == "table" then
        for k, val in pairs(src.quest_info) do dst.quest_info[k] = val end
    end
    if type(src.goals) == "table" then
        local index = {}
        for i, g in ipairs(dst.goals) do
            if g.phase_number then index[g.phase_number] = i end
        end
        for _, g in ipairs(src.goals) do
            local pn = g.phase_number
            if pn and index[pn] then
                for k, val in pairs(g) do dst.goals[index[pn]][k] = val end
            else
                dst.goals[#dst.goals + 1] = g
                if pn then index[pn] = #dst.goals end
            end
        end
    end
    for k, val in pairs(src) do
        if k ~= "goals" and k ~= "quest_info" then dst[k] = val end
    end
end

-- Reconcile against a full snapshot: the snapshot is the authoritative set
-- of quests we're on. Drop anything missing, then merge the snapshot over it.
local function reconcile(data)
    local fresh = {}
    for _, q in pairs(data) do
        if type(q) == "table" and q.quest_info and q.quest_info.vnum then
            fresh[tonumber(q.quest_info.vnum)] = q
        end
    end
    for vnum in pairs(quests) do
        if not fresh[vnum] then
            quests[vnum] = nil
            if vnum == selected then clear_selection() end
        end
    end
    for vnum, q in pairs(fresh) do
        merge_quest(vnum, q)
    end
end

-- Ingest GMCP. vnum can come from the packet name (char.quests.q1199) or
-- from the payload (single quest).
local function ingest(pkg, data)
    if type(data) ~= "table" then return end

    local from_pkg = tonumber(tostring(pkg):match("[qQ](%d+)$"))
    if from_pkg then
        merge_quest(from_pkg, data)
        return
    end

    if data.quest_info and data.quest_info.vnum then
        merge_quest(tonumber(data.quest_info.vnum), data)
        return
    end

    -- Full snapshot. An empty one legitimately means "no quests on".
    local count = 0
    local any = false
    for _, q in pairs(data) do
        count = count + 1
        if type(q) == "table" and q.quest_info and q.quest_info.vnum then
            any = true
        end
    end
    if count == 0 or any then
        reconcile(data)
    end
end

-- Ask MM for all quest data.
local function request_quests()
    if rune.gmcp.is_enabled() then
        rune.gmcp.send("char.quests", { [""] = "" })
    end
end

-- Use the number from "...quest #1199..." to query that quest's GMCP entry.
local function refresh_quest(vnum)
    if rune.gmcp.is_enabled() then
        rune.gmcp.send("char.quests.q" .. vnum, { [""] = "" })
    end
end

-- Select the quest being viewed, watch for progress, and reconcile on
-- completion/expiry/abandon lines.
rune.hooks.on("output", function(line)
    local text = line:clean()

    local done_vnum = text:match("completed a part of quest #(%d+)")
    if done_vnum then
        refresh_quest(tonumber(done_vnum))
        return nil
    end

    if text:match("completed your quest")
        or text:match("Congratulations on the completion of thy quest")
        or text:match("You have run out of time for your quest,")
        or text:match("You are no longer on the quest,")
        or text:match("You have abandoned quest #") then
        request_quests()
    end

    local vnum, name = text:match("^This quest %[(%d+)%] is called '(.+)',")
    if vnum then
        selected = tonumber(vnum)
        rune.store.set("quest_vnum", selected)
        render()
    end
    return nil
end, { name = "quests-select", priority = 50 })

-- Tick: drop expired quests and keep the display current.
local last_sig
rune.timer.every(1, function()
    local changed = sweep_expired()
    local sig
    if selected then
        local q = quests[selected]
        local t = q and tonumber(q.quest_info and q.quest_info.timer)
        sig = (t and t > 0) and math.max(0, t - os.time()) or -1
    else
        local parts = {}
        for vnum, q in pairs(quests) do
            local t = tonumber(q.quest_info and q.quest_info.timer)
            parts[#parts + 1] = vnum .. ":" ..
                tostring((t and t > 0) and math.max(0, t - os.time()) or -1)
        end
        table.sort(parts)
        sig = table.concat(parts, ",")
    end
    if changed or sig ~= last_sig then
        last_sig = sig
        render()
    end
end, { name = "quests-tick" })

for _, pkg in ipairs({ "Char.Quests", "Char.Quest", "Quest" }) do
    rune.gmcp.on(pkg, function(data)
        ingest(pkg, data)
        render()
    end, { name = "quests-gmcp-" .. pkg:gsub("%W", "") })
end

-- Catch per-quest packets and any other quest-named packet.
rune.hooks.on("gmcp", function(pkg, data)
    local p = tostring(pkg):lower()
    if p:find("quest", 1, true) then
        ingest(pkg, data)
        render()
    end
end, { name = "quests-gmcp-any", priority = 50 })

-- Diagnostic, off by default: `/group quests-debug on` to watch GMCP.
rune.hooks.on("gmcp", function(pkg, data, raw)
    if tostring(pkg):lower():find("quest", 1, true) then
        rune.echo("[gmcp] " .. tostring(pkg) .. " " .. tostring(raw))
    end
end, { name = "quests-spy", group = "quests-debug" })
rune.group.disable("quests-debug")

rune.hooks.on("gmcp_enabled", request_quests,
    { name = "quests-request", priority = 200 })
rune.hooks.on("reloaded", request_quests, { name = "quests-reload" })
rune.trigger.regex("Welcome( back)? to Materia Magica", request_quests,
    { name = "quests-welcome" })
rune.trigger.regex("^You are player \\[", request_quests,
    { name = "quests-welcome-fresh" })

rune.alias.regex("^quests (show|hide|toggle|clear|refresh|info)$", function(m)
    local cmd = m[1]
    if cmd == "clear" then
        if selected then quests[selected] = nil end
        clear_selection()
        rune.pane.clear("quests")
        rune.echo("[quests] cleared")
    elseif cmd == "show" then
        rune.pane.show("quests")
    elseif cmd == "hide" then
        rune.pane.hide("quests")
    elseif cmd == "refresh" then
        request_quests()
        rune.echo("[quests] requested")
    elseif cmd == "info" then
        local n = 0
        for _ in pairs(quests) do n = n + 1 end
        rune.echo("[quests] gmcp=" .. tostring(rune.gmcp.is_enabled())
            .. " gmcp_quests=" .. n
            .. " selected=" .. tostring(selected)
            .. " goals=" .. tostring(selected and quests[selected]
                and #(quests[selected].goals or {}) or 0))
    else
        local on = rune.pane.toggle("quests")
        rune.echo("[quests] " .. (on and "shown" or "hidden"))
    end
end, { name = "quests-toggle" })
