-- timers.lua -- simple scheduled commands.
--
-- Timers tied to a module's state/rendering live with that module (quests tick,
-- stats bootstrap, comms autosave, ...). This file is for plain
-- "send this command every N" timers.

-- Twiddle every five minutes.
rune.timer.every(300, function()
    if rune.state and rune.state.connected == false then return end
    rune.send("twiddle")
end, { name = "twiddle" })
