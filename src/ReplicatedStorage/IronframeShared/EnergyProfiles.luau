-- Tactical energy allocation profiles (M09). Pure data + a small switching state machine, no engine dependencies.
--
-- A profile NEVER creates energy, changes weapon damage/cadence, or alters the installed reactor/capacitor/cooling. It only
-- chooses (a) the order in which competing continuous requests are served each substep and (b) how much capacitor charge
-- each DISCRETIONARY subsystem must leave untouched (a reserve floor, as a fraction of capacitor capacity).
--
-- Mandatory baseline operation (reactor idle + basic propulsion) is never configurable: Energy.SetPolicy ignores any
-- priority/floor a profile supplies for it. Everything else (shield, weapons, sprint) is discretionary.
--
-- Adding a profile = adding one table to Profiles.Definitions (+ its id to Profiles.Order once it can be selected). The
-- allocation layer and the controller only read these fields; they do not know profile ids.
local Profiles = {}

Profiles.Default = "BALANCED"
Profiles.Transition = 0.5 -- seconds between accepting a switch and the new policy taking effect
Profiles.MinInterval = 2.0 -- seconds between two accepted switch requests

-- Selectable today, in HUD / cycling order.
Profiles.Order = { "MOBILITY", "BALANCED", "WEAPONS" }

-- priority: lower number is served first; equal numbers SHARE the supply in proportion to demand (no callback-order bias).
-- reserve:  fraction of capacitor capacity that subsystem may not draw below (discretionary keys only).
Profiles.Definitions = {
    MOBILITY = {
        name = "MOBILITY", tag = "MOB", focus = "PROPULSION",
        summary = "Sprint first. Weapons need a healthy capacitor.",
        priority = { shield = 4, weapons = 5, sprint = 3 },
        reserve = { sprint = 0.00, weapons = 0.40, shield = 0.00 },
    },
    BALANCED = {
        name = "BALANCED", tag = "BAL", focus = "SHARED",
        summary = "Sprint and weapons share supply. Each protects the other's last reserve.",
        priority = { shield = 3, weapons = 4, sprint = 4 },
        reserve = { sprint = 0.30, weapons = 0.20, shield = 0.00 },
    },
    WEAPONS = {
        name = "WEAPONS", tag = "WPN", focus = "WEAPONS",
        summary = "Weapons first. Sprint runs on reactor surplus and the top of the capacitor.",
        priority = { shield = 3, weapons = 4, sprint = 5 },
        reserve = { sprint = 0.55, weapons = 0.00, shield = 0.00 },
    },
}

-- Design placeholders for later milestones. They are NOT selectable and carry no gameplay effect; `requires` records the
-- intended gate (hardware or unlock) so future entries move into Definitions + Order without touching controller code.
Profiles.Planned = {
    BULWARK = { name = "BULWARK", role = "defensive shielding", requires = "shield hardware upgrade" },
    OVERDRIVE = { name = "OVERDRIVE", role = "aggressive propulsion", requires = "reinforced capacitor / drive unlock" },
    SIEGE = { name = "SIEGE", role = "stationary firepower", requires = "heavy weapon unlock" },
    PHANTOM = { name = "PHANTOM", role = "low-signature movement", requires = "sensor-baffle hardware" },
    COUNTERSTRIKE = { name = "COUNTERSTRIKE", role = "timed shield counterplay", requires = "shield unlock" },
    ["EMERGENCY RESERVE"] = { name = "EMERGENCY RESERVE", role = "survival and recovery", requires = "unlock" },
}

function Profiles.Get(id: any): any?
    if type(id) ~= "string" then return nil end
    return Profiles.Definitions[id]
end

-- A request is valid only for a known, implemented, selectable id. Planned profiles are rejected with a distinct reason.
function Profiles.Validate(id: any): (boolean, string?)
    if type(id) ~= "string" or #id > 32 then return false, "INVALID PROFILE" end
    if not Profiles.Definitions[id] then
        return false, if Profiles.Planned[id] then "PROFILE LOCKED" else "INVALID PROFILE"
    end
    if not table.find(Profiles.Order, id) then return false, "INVALID PROFILE" end
    return true, nil
end

function Profiles.Next(id: string): string
    local index = table.find(Profiles.Order, id) or 1
    return Profiles.Order[index % #Profiles.Order + 1]
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Switching state. All times are caller-supplied simulation seconds, so the machine is deterministic and testable.
-- ---------------------------------------------------------------------------------------------------------------------
function Profiles.New(startId: string?)
    local id = startId or Profiles.Default
    assert(Profiles.Definitions[id], "unknown start profile " .. tostring(id))
    return { active = id, pending = nil, pendingAt = 0, lastRequestAt = -math.huge, serial = 0, reason = "READY", changedAt = -math.huge }
end

function Profiles.Policy(state): any
    return Profiles.Definitions[state.active]
end

-- Returns ok, reason. A rejected request changes nothing (it neither resets the interval nor disturbs a pending switch).
function Profiles.Request(state, id: any, now: number)
    local valid, reason = Profiles.Validate(id)
    if not valid then state.reason = reason :: string; return false, reason end
    if state.pending then state.reason = "SWITCH IN PROGRESS"; return false, state.reason end
    if id == state.active then state.reason = "ALREADY ACTIVE"; return false, state.reason end
    if now - state.lastRequestAt < Profiles.MinInterval then
        state.reason = "SWITCH COOLDOWN"
        return false, state.reason
    end
    state.pending, state.pendingAt, state.lastRequestAt = id, now + Profiles.Transition, now
    state.reason = "SWITCHING"
    return true, nil
end

-- Completes a pending switch once its delay has elapsed. Returns true on the call that applies it.
function Profiles.Update(state, now: number): boolean
    if state.pending and now >= state.pendingAt then
        state.active, state.pending = state.pending, nil
        state.serial += 1
        state.changedAt = now
        state.reason = "ACTIVE"
        return true
    end
    return false
end

-- Ejection / dock cancels an in-flight switch without altering the active policy.
function Profiles.Cancel(state)
    if state.pending then state.pending = nil; state.reason = "CANCELLED" end
end

function Profiles.Remaining(state, now: number): number
    return if state.pending then math.max(0, state.pendingAt - now) else 0
end

return Profiles
