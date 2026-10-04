-- panes.lua -- hide/show every pane at once, for a clean full-width output
-- (handy when selecting/copying text with the terminal's mouse, which otherwise
-- also grabs whatever is in the side panes on the same rows).

local PANES = { "comms", "quests" }

local function any_visible()
    for _, name in ipairs(PANES) do
        if not rune.pane.is_hidden(name) then return true end
    end
    return false
end

local function hide_all()
    for _, name in ipairs(PANES) do
        rune.pane.hide(name)
    end
end

local function show_all()
    for _, name in ipairs(PANES) do
        rune.pane.show(name)
    end
end

rune.command.add("panes", function(args)
    local mode = (args or ""):match("^%s*(%S+)")
    if mode == "hide" then
        hide_all()
        rune.echo("[panes] hidden")
    elseif mode == "show" then
        show_all()
        rune.echo("[panes] shown")
    elseif any_visible() then
        hide_all()
        rune.echo("[panes] hidden")
    else
        show_all()
        rune.echo("[panes] shown")
    end
end, "Hide/show all panes (/panes [hide|show|toggle])")
