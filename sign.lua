-- sign.lua -- roadsign picker. Reading a roadsign prints a long block of
-- "  * gilvery is east." lines (in MM's client each is clickable and runs the
-- destination). Rune has no click actions, so instead we watch for a roadsign
-- inspection, hide the item-stat clutter, and pop a picker of its
-- destinations; choosing one runs `run <destination>` -- the same thing the
-- click does.

local function show_picker(title, dests)
    if #dests == 0 then return end
    table.sort(dests, function(a, b) return a.name < b.name end)
    local items = {}
    for _, d in ipairs(dests) do
        items[#items + 1] = { text = d.name, desc = d.dir, value = d.name }
    end
    rune.ui.picker.show({
        title = "Sign: " .. title,
        items = items,
        on_select = function(name) rune.send("run " .. name) end,
    })
end

local active = false       -- inside a roadsign block
local collecting = false   -- have we reached the "* dest is dir." entries yet
local gag_budget = 0       -- description lines left we may hide (safety cap)
local dests, title

rune.hooks.on("output", function(line)
    local clean = line:clean()

    -- Start of a roadsign listing. Hide the header; begin a bounded run of
    -- description lines (which can wrap) until the first entry shows up.
    if clean:find("is type roadsign", 1, true) then
        active, collecting, gag_budget = true, false, 8
        dests = {}
        title = clean:match("Item '(.-)' is type roadsign") or "sign"
        return false
    end

    if active and not collecting then
        if clean:match("^%* %S+ is %w+%.%s*$") then
            collecting = true
        elseif gag_budget > 0 then
            gag_budget = gag_budget - 1
            return false
        else
            active = false          -- not the shape we expected; let it be
            return nil
        end
    end

    if collecting then
        local name, dir = clean:match("^%* (%S+) is (%w+)%.%s*$")
        if name then
            dests[#dests + 1] = { name = name, dir = dir }
            return nil              -- keep the entry line visible
        end

        -- First non-entry line ends the block: open the picker a moment later,
        -- off the hook, rather than popping a modal mid-line.
        active, collecting = false, false
        local snapshot, snap_title = dests, title
        rune.timer.after(0.1, function()
            show_picker(snap_title, snapshot)
        end)
    end
end, { name = "sign-capture", priority = 50 })
