-- Deployment state machine (M07). Pure data and rules, no Roblox side effects, so the transitions are unit-testable.
--
--   STOWED ──deploy──▶ DEPLOYING ──startup done──▶ ACTIVE ──return──▶ DOCKING ──docked──▶ STOWED
--      ▲                   │                          │                  │
--      └───rebuild─── EJECTED ◀───────eject (any deployed state)─────────┘
--
-- STOWED   showroom: inspection camera, loadout editing, no drive controller
-- DEPLOYING reactor starting, doors opening, input locked, mech stationary
-- ACTIVE   drive enabled
-- DOCKING  autopilot (inside the hangar) or recall (anywhere else) back onto the pad; input ignored
-- EJECTED  the pilot is out; input permanently locked until the rebuilt mech arrives STOWED

local Deployment = {}

Deployment.STATES = { "STOWED", "DEPLOYING", "ACTIVE", "DOCKING", "EJECTED" }
Deployment.STARTUP_TIME = 3.0
Deployment.RECALL_FADE = 1.3
Deployment.DOCK_TIMEOUT = 50

local ALLOWED: { [string]: { [string]: boolean } } = {
    STOWED = { DEPLOYING = true, EJECTED = true },
    DEPLOYING = { ACTIVE = true, EJECTED = true, STOWED = true },
    ACTIVE = { DOCKING = true, EJECTED = true },
    DOCKING = { STOWED = true, EJECTED = true },
    EJECTED = { STOWED = true },
}

function Deployment.CanTransition(from: string, to: string): boolean
    local row = ALLOWED[from]
    return row ~= nil and row[to] == true
end

function Deployment.IsDeployed(state: string?): boolean
    return state == "DEPLOYING" or state == "ACTIVE" or state == "DOCKING"
end

-- True while the pilot can steer.
function Deployment.AcceptsInput(state: string?): boolean
    return state == "ACTIVE"
end

-- Loadout and preset changes are a showroom activity.
function Deployment.AllowsLoadoutChange(state: string?): boolean
    return state == nil or state == "STOWED"
end

-- Returns ok, reason. `compiled` is the LoadoutCompiler result for the session's current preset.
function Deployment.ValidateDeploy(session: any, compiled: any): (boolean, string?)
    if not session then
        return false, "no pilot session"
    end
    if (session.deployment or "STOWED") ~= "STOWED" then
        return false, "already deployed"
    end
    if session.machineState ~= "OPERATIONAL" then
        return false, "mech not operational"
    end
    if not session.mech then
        return false, "no mech in bay"
    end
    if session.pilotSafe ~= true then
        return false, "pilot safety not confirmed"
    end
    if not compiled or compiled.valid ~= true then
        return false, "loadout invalid"
    end
    if not (session.loadout and session.loadout.systems and session.loadout.systems.reactor) then
        return false, "no reactor installed"
    end
    return true, nil
end

-- Moves the session to `to` if the transition is legal. Returns whether it happened.
function Deployment.Transition(session: any, to: string): boolean
    local from = session.deployment or "STOWED"
    if from == to then
        return false
    end
    if not Deployment.CanTransition(from, to) then
        return false
    end
    session.deployment = to
    return true
end

-- Reactor state follows deployment: cold in the showroom is still "STANDBY" (the cockpit boot owns its own display state).
function Deployment.ReactorFor(state: string?): string
    if state == "DEPLOYING" then
        return "STARTING"
    elseif state == "ACTIVE" or state == "DOCKING" then
        return "ONLINE"
    elseif state == "EJECTED" then
        return "SHUTDOWN"
    end
    return "STANDBY"
end

return Deployment
