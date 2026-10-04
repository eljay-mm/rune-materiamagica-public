-- enemy.lua -- rewrite a creature's wound line into an inline health bar.
--
-- MM's GMCP Char.Status reports enemy="_empty" and enemypct=-1 even in
-- combat, so the wound-description line is the source:
--   "Jambalaya Jake has some very significant wounds and scratches."
-- becomes (in place):
--   "Jambalaya Jake: ██████████░░░░░░░░░░ 52%"
-- There is no target pane; the line itself is the indicator.

local style = rune.style

local WOUND_PCT = {
    ["is in perfect health"] = 100,
    ["is in good health"] = 100,
    ["has several minor scratches"] = 95,
    ["has several minor wounds and bruises"] = 82,
    ["has some significant wounds"] = 67,
    ["has some very significant wounds and scratches"] = 52,
    ["looks pretty beaten up"] = 40,
    ["is in terrible condition"] = 30,
    ["is vomiting blood"] = 20,
    ["screams in agony"] = 12,
    ["pales visibly as death nears"] = 7,
    ["is barely clinging to life"] = 2,
}

local PRONOUNS = { it = true, them = true, him = true, her = true }

local function normalize_target(name)
    if not name then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or PRONOUNS[name:lower()] then return nil end
    return name
end

-- Bright magenta, since rune.style has no bright variants.
local function bright_magenta(s)
    return "\27[95m" .. tostring(s) .. "\27[0m"
end

-- Pure yellow (RGB 255,255,0); SGR 33 reads as orange in many themes.
local function yellow(s)
    return "\27[38;5;226m" .. tostring(s) .. "\27[0m"
end

local function inline_bar(name, pct)
    local w = 20
    local filled = math.max(1, math.floor(w * pct / 100 + 0.5))
    local color = style.red
    if pct >= 50 then color = style.green
    elseif pct >= 25 then color = yellow end
    return bright_magenta(name .. ":") .. " " ..
        color(string.rep("▰", filled)) ..
        style.gray(string.rep("▱", w - filled)) ..
        string.format(" %d%%", pct)
end

local wound_alt = table.concat({
    "is in perfect health", "is in good health",
    "has several minor scratches", "has several minor wounds and bruises",
    "has some significant wounds",
    "has some very significant wounds and scratches",
    "looks pretty beaten up", "is in terrible condition",
    "is vomiting blood", "screams in agony",
    "pales visibly as death nears", "is barely clinging to life",
}, "|")

rune.trigger.regex("^(.+) (" .. wound_alt .. ")\\.$", function(m)
    local name = normalize_target(m[1])
    if not name then return nil end
    return inline_bar(name, WOUND_PCT[m[2]])  -- replace the line with a bar
end, { name = "enemy-wound" })
