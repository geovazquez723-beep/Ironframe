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
    -- Visual/drive failures cannot prevent either cleanup or the guaranteed recovery schedule.
    local function safely(callback)
        local ok, err = pcall(callback)
        if not ok and warn then warn("[IF-EJECTION] hook failed; pilot remains safe: " .. tostring(err)) end
    end
    safely(hooks.onPilotSafe)

    delayFn(Ejection.DISABLE_DELAY, function()
        if hooks.isStale() then
            return
        end
        assert(session.pilotSafe == true, "pilot must be safe before mech disable")
        session.machineState = "MECH_DISABLED"
        safely(hooks.onMechDisabled)
    end)
    delayFn(Ejection.REBUILD_DELAY, function()
        safely(hooks.onCleanup)
        if hooks.isStale() then
            return
        end
        session.pilotSafe = true
        safely(hooks.onRebuild)
    end)
end

return Ejection
