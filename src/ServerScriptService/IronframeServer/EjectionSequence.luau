-- Safe-ejection state machine. INVARIANT: pilotSafe is set (and the pilot made untargetable)
-- before ANY hook that can touch the mech runs. Hooks only receive the session afterwards.

local Ejection = {}

Ejection.DISABLE_DELAY = 1.0
Ejection.REBUILD_DELAY = 4.0

-- Pilots are never targetable, in any state.
function Ejection.IsPilotTargetable(_session)
    return false
end

-- hooks: onPilotSafe(), onMechDisabled(), onCleanup(), onRebuild(), isStale() -> boolean
-- delayFn(seconds, fn) defaults to task.delay; tests inject a synchronous scheduler.
function Ejection.Run(session, hooks, delayFn)
    delayFn = delayFn or task.delay

    session.pilotSafe = true
    session.pilotTargetable = false
    session.machineState = "PILOT_EVACUATED"
    hooks.onPilotSafe()

    delayFn(Ejection.DISABLE_DELAY, function()
        if hooks.isStale() then
            return
        end
        assert(session.pilotSafe == true, "pilot must be safe before mech disable")
        session.machineState = "MECH_DISABLED"
        hooks.onMechDisabled()
    end)
    delayFn(Ejection.REBUILD_DELAY, function()
        hooks.onCleanup()
        if hooks.isStale() then
            return
        end
        session.pilotSafe = true
        hooks.onRebuild()
    end)
end

return Ejection
