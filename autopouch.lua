-- autopouch.lua -- auto-empty the pouch of plenitude and keep the ingredients
-- needed by the selected recipes.
--
-- Loop (on the pouch glow, or `autopouch now`):
--   open plenitude
--   take all plenitude
--   -> put the needed ingredients into the configured container
--   -> drop the leftover pouch item types (seed/resource/food/drink/wine)
--   close plenitude
-- The pouch then refills and glows again.
--
-- Recipes come from <config>/cook/recipes.json. `autopouch` alone shows help.

local H = require("helpstyle")
local style = rune.style

-- Recipes --------------------------------------------------------------------

local RECIPES_PATH = (rune.config_dir or ".") .. "/cook/recipes.json"

local recipes = {}          -- name -> { tool = ..., ingredients = { ... } }
local recipe_names = {}     -- sorted names

local function load_recipes()
    local f = io.open(RECIPES_PATH, "r")
    if not f then
        rune.echo("[autopouch] cannot read " .. RECIPES_PATH)
        return
    end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(rune.json.decode, text)
    if not ok or type(data) ~= "table" or type(data.recipes) ~= "table" then
        rune.echo("[autopouch] bad recipes JSON in " .. RECIPES_PATH)
        return
    end
    for _, r in ipairs(data.recipes) do
        local name = r.recipe
        if type(name) == "string" and name ~= "" then
            recipes[name] = {
                tool = r.tool,
                ingredients = type(r.ingredients) == "table" and r.ingredients or {},
            }
        end
    end
    for name in pairs(recipes) do recipe_names[#recipe_names + 1] = name end
    table.sort(recipe_names)
end

load_recipes()

-- Daily keep candidates: every recipe name and every ingredient name. The
-- daily quest accepts any finished product or ingredient, so the picker offers
-- this whole list.
local daily_items = {}      -- sorted candidate names
local daily_known = {}      -- name -> true

local function build_daily_items()
    local set = {}
    for _, name in ipairs(recipe_names) do set[name] = true end
    for _, r in pairs(recipes) do
        for _, ing in ipairs(r.ingredients) do set[ing] = true end
    end
    local list = {}
    for name in pairs(set) do list[#list + 1] = name end
    table.sort(list)
    for _, name in ipairs(list) do
        daily_items[#daily_items + 1] = name
        daily_known[name] = true
    end
end

build_daily_items()

-- Selection (persisted) ------------------------------------------------------

local selected = {}         -- name -> true

local function load_selection()
    local saved = rune.store.get("autopouch.recipes")
    if type(saved) == "table" then
        for _, name in ipairs(saved) do
            if recipes[name] then selected[name] = true end
        end
    end
end

local function save_selection()
    local out = {}
    for _, name in ipairs(recipe_names) do
        if selected[name] then out[#out + 1] = name end
    end
    rune.store.set("autopouch.recipes", out)
end

load_selection()

-- Daily: one extra item to keep beyond the selected recipes (persisted).
local daily                 -- selected item name, or nil

local function load_daily()
    local saved = rune.store.get("autopouch.daily")
    if daily_known[saved] then daily = saved end
end

local function save_daily()
    rune.store.set("autopouch.daily", daily)
end

load_daily()

-- Needed set: flat union of the selected recipes' ingredients, lowercased.
local needed = {}
local function rebuild_needed()
    needed = {}
    for name in pairs(selected) do
        local r = recipes[name]
        if r then
            for _, ing in ipairs(r.ingredients) do
                needed[ing:lower()] = true
            end
        end
    end
    if daily then needed[daily:lower()] = true end
end
rebuild_needed()

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Settings -------------------------------------------------------------------

local function enabled()
    return rune.store.get("autopouch.enabled") == true
end

local function container()
    local c = rune.store.get("autopouch.container")
    if type(c) == "string" and c ~= "" then return c end
    return nil
end

local function status()
    return string.format(
        "auto=%s  container=%s  recipes=%d  ingredients=%d  daily=%s",
        enabled() and "on" or "off", container() or "(unset)",
        count(selected), count(needed), daily or "none")
end

-- The loop -------------------------------------------------------------------

local busy = false
local collect = {}          -- lowercased -> { item = original, n = count }
local total = 0
local idle_timer, cap_timer

local function cancel_timers()
    if idle_timer then idle_timer:remove(); idle_timer = nil end
    if cap_timer then cap_timer:remove(); cap_timer = nil end
end

local finish

local function schedule_flush()
    if idle_timer then idle_timer:remove() end
    idle_timer = rune.timer.after(1.0, function() return finish() end,
        { name = "autopouch-idle" })
end

finish = function()
    if not busy then return end
    cancel_timers()
    busy = false

    local cont = container()
    local kept = 0
    local missing = false
    for _, e in pairs(collect) do
        if needed[e.item:lower()] then
            if cont then
                if e.item:find("'") then
                    rune.echo("[autopouch] skipped (quote in name): " .. e.item)
                else
                    rune.send("put all.'" .. e.item .. "' " .. cont)
                    kept = kept + 1
                end
            else
                missing = true
            end
        end
    end
    if missing then
        rune.echo("[autopouch] no container set; needed items not sorted "
            .. "(autopouch container <keyword>)")
    end

    -- Clear the leftovers so the pouch can replenish.
    rune.send("drop all.seed")
    rune.send("drop all.resource")
    rune.send("drop all.food")
    rune.send("drop all.drink")
    rune.send("drop all.wine")
    rune.send("close plenitude")

    rune.echo(style.green(string.format("[autopouch] done - kept %d of %d",
        kept, total)))
end

local function run_loop()
    if busy then
        rune.echo("[autopouch] already running")
        return
    end
    busy = true
    collect = {}
    total = 0
    rune.echo("[autopouch] open + take all plenitude")
    rune.send("open plenitude")
    rune.send("take all plenitude")
    -- Flush on the first take line's quiet gap (schedule_flush); if the pouch
    -- yields nothing, the cap below still finishes the loop.
    if cap_timer then cap_timer:remove() end
    cap_timer = rune.timer.after(4.0, function() return finish() end,
        { name = "autopouch-cap" })
end

-- Collect what the pouch gives up.
rune.trigger.regex(
    "^You take ((\\d+) of )?(.+) from a pouch of plenitude\\.$",
    function(m)
        if not busy then return end
        local n = tonumber(m[2]) or 1
        local item = m[3]
        local key = item:lower()
        local e = collect[key]
        if e then
            e.n = e.n + n
        else
            collect[key] = { item = item, n = n }
        end
        total = total + n
        schedule_flush()
    end, { name = "autopouch-take" })

-- The pouch glows when it is empty and closed, ready to refill.
rune.trigger.contains(
    "pouch of plenitude glows white as it accumulates possessions from the ether",
    function()
        if enabled() then run_loop() end
    end, { name = "autopouch-glow" })

-- Recipe picker --------------------------------------------------------------

local function open_picker()
    local items = {}
    for _, name in ipairs(recipe_names) do
        local r = recipes[name]
        items[#items + 1] = {
            text = (selected[name] and "[x] " or "[ ] ") .. name,
            desc = string.format("%s  (%d ingredients)",
                r.tool or "?", #r.ingredients),
            value = name,
        }
    end
    rune.ui.picker.show({
        title = "autopouch recipes",
        items = items,
        match_description = true,
        on_select = function(val)
            if selected[val] then selected[val] = nil else selected[val] = true end
            save_selection()
            rebuild_needed()
            open_picker()
        end,
    })
end

local function open_daily_picker()
    local items = {}
    for _, name in ipairs(daily_items) do
        items[#items + 1] = { text = name, value = name }
    end
    rune.ui.picker.show({
        title = "autopouch daily item" .. (daily and (" (now: " .. daily .. ")") or ""),
        items = items,
        on_select = function(val)
            daily = val
            save_daily()
            rebuild_needed()
            rune.echo("[autopouch] daily = " .. val)
        end,
    })
end

local function list_selected()
    local out = {}
    for _, name in ipairs(recipe_names) do
        if selected[name] then out[#out + 1] = name end
    end
    if #out == 0 then
        rune.echo("[autopouch] no recipes selected")
    else
        rune.echo("[autopouch] selected: " .. table.concat(out, ", "))
    end
end

local function list_needs()
    local out = {}
    for key in pairs(needed) do out[#out + 1] = key end
    table.sort(out)
    if #out == 0 then
        rune.echo("[autopouch] nothing needed")
    else
        rune.echo("[autopouch] keeping " .. #out .. ": " .. table.concat(out, ", "))
    end
end

local function help()
    rune.echo(H.title("autopouch - empty the pouch of plenitude, keep ingredients"))
    rune.echo(H.section("Run:"))
    rune.echo(H.line("autopouch now", "empty + sort the pouch right now"))
    rune.echo(H.line("autopouch on | off", "auto-run when the pouch glows"))
    rune.echo(H.section("Recipes:"))
    rune.echo(H.line("autopouch pick", "toggle recipes (checkbox picker)"))
    rune.echo(H.line("autopouch list", "show selected recipes"))
    rune.echo(H.line("autopouch needs", "show the ingredients kept"))
    rune.echo(H.line("autopouch add <recipe>", "select a recipe"))
    rune.echo(H.line("autopouch del <recipe>", "deselect a recipe"))
    rune.echo(H.line("autopouch clear", "clear the recipe selection"))
    rune.echo(H.section("Daily:"))
    rune.echo(H.line("autopouch daily", "pick one extra item to keep (picker)"))
    rune.echo(H.line("autopouch daily clear", "stop keeping it"))
    rune.echo(H.section("Sort:"))
    rune.echo(H.line("autopouch container <keyword>", "where kept ingredients go"))
    rune.echo("")
    rune.echo(H.foot(status()))
end

-- Aliases (typed bare, no leading slash) -------------------------------------

rune.alias.regex("^autopouch$", help, { name = "autopouch-help" })

rune.alias.regex("^autopouch +(now|on|off|pick|list|needs|clear|daily)$", function(m)
    local cmd = m[1]
    if cmd == "now" then
        run_loop()
    elseif cmd == "on" then
        rune.store.set("autopouch.enabled", true)
        rune.echo("[autopouch] auto on")
    elseif cmd == "off" then
        rune.store.set("autopouch.enabled", false)
        rune.echo("[autopouch] auto off")
    elseif cmd == "pick" then
        open_picker()
    elseif cmd == "list" then
        list_selected()
    elseif cmd == "needs" then
        list_needs()
    elseif cmd == "clear" then
        selected = {}
        save_selection()
        rebuild_needed()
        rune.echo("[autopouch] cleared")
    elseif cmd == "daily" then
        open_daily_picker()
    end
end, { name = "autopouch-sub" })

rune.alias.regex("^autopouch +daily +clear$", function()
    daily = nil
    save_daily()
    rebuild_needed()
    rune.echo("[autopouch] daily cleared")
end, { name = "autopouch-daily-clear" })

rune.alias.regex("^autopouch +(container|add|del) +(.+)$", function(m)
    local cmd, arg = m[1], m[2]
    if cmd == "container" then
        rune.store.set("autopouch.container", arg)
        rune.echo("[autopouch] container = " .. arg)
    elseif cmd == "add" then
        if recipes[arg] then
            selected[arg] = true
            save_selection()
            rebuild_needed()
            rune.echo("[autopouch] added " .. arg)
        else
            rune.echo("[autopouch] no such recipe: " .. arg)
        end
    elseif cmd == "del" then
        if selected[arg] then
            selected[arg] = nil
            save_selection()
            rebuild_needed()
            rune.echo("[autopouch] removed " .. arg)
        else
            rune.echo("[autopouch] not selected: " .. arg)
        end
    end
end, { name = "autopouch-arg" })
