-- mapper_walk.lua -- step-by-step speedwalk engine.
--
-- Sends one direction at a time and waits for the matching Room.Info before
-- the next step, so a walk can be aborted (mapper stop) and won't desync.

local M = {}

local STEP_TIMEOUT = 5
local active = false
local steps = {}
local index = 1
local timeout_handle
local destination
local mode = "path"       -- "path" (expects room ids) or "dirs" (raw directions)

local function cancel_timeout()
    if timeout_handle then
        timeout_handle:remove()
        timeout_handle = nil
    end
end

local function send_step()
    if not active then return end
    local step = steps[index]
    if not step then
        M.stop()
        return
    end
    rune.send(step.dir)
    cancel_timeout()
    local dir = step.dir
    timeout_handle = rune.timer.after(STEP_TIMEOUT, function()
        timeout_handle = nil
        rune.echo("[mapper] walk stalled on '" .. dir .. "' (no room change); stopped.")
        M.stop()
    end)
end

-- path: array of { dir, uid } from graph.find_paths.
function M.start(path, dest)
    if not path or #path == 0 then return false end
    steps = path
    index = 1
    destination = dest
    mode = "path"
    active = true
    send_step()
    return true
end

-- Walk a raw list of directions (e.g. from a "sense" line) with no expected
-- room ids: advance on each Room.Info.
function M.start_dirs(dirs, label)
    if not dirs or #dirs == 0 then return false end
    local path = {}
    for i, d in ipairs(dirs) do path[i] = { dir = d } end
    steps = path
    index = 1
    destination = label
    mode = "dirs"
    active = true
    send_step()
    return true
end

-- Called on every Room.Info with the new room id.
function M.on_room(uid)
    if not active then return end
    uid = tostring(uid)
    local step = steps[index]
    if not step then return end

    if mode == "path" and uid ~= step.uid then
        -- Landed somewhere we didn't expect: abort rather than guess.
        rune.echo("[mapper] walk interrupted at " .. uid ..
            " (expected " .. step.uid .. "); stopped.")
        M.stop()
        return
    end

    index = index + 1
    if index > #steps then
        rune.echo("[mapper] arrived at " .. tostring(destination or "?") .. ".")
        M.stop()
        return
    end
    cancel_timeout()
    send_step()
end

function M.stop()
    active = false
    steps = {}
    index = 1
    cancel_timeout()
end

function M.is_active()
    return active
end

function M.get_destination()
    return destination
end

function M.remaining_count()
    if not active then return 0 end
    return math.max(0, #steps - index + 1)
end

return M
