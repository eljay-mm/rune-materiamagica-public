-- helpstyle.lua -- shared styling for help text.
--
-- Palette: blue commands/sections on the default white text.
-- Each rune.style.* helper appends a reset, so keep the attribute outside
-- the color (bold(blue(...))) and style fragments separately.

local style = rune.style
local M = {}

-- rune.style has no bright variants, so emit SGR codes directly.
local function brightblue(s)
    return "\27[1;94m" .. tostring(s) .. "\27[0m"
end

local function brightwhite(s)
    return "\27[1;97m" .. tostring(s) .. "\27[0m"
end

function M.title(s)
    return brightwhite(s)
end

function M.section(s)
    return brightwhite(s)
end

function M.cmd(s)
    return brightblue(s)
end

function M.foot(s)
    return style.dim(s)
end

-- "  <command><pad> <description>" with the command in the command color.
function M.line(cmd, desc, width)
    width = width or 30
    local left = string.format("  %-" .. width .. "s ", cmd)
    return M.cmd(left) .. (desc or "")
end

return M
