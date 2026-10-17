-- Deterministic tank combat state machine (M10B). Pure: numbers and booleans in, a small instruction table out; no Roblox types,
-- no randomness, no clock - the caller passes dt and the senses it measured. The server maps the instructions onto the real
-- tank (turret weld, hull drive, muzzle, shell); offline tests drive this module directly with synthetic senses.
--
--   IDLE ──target in range + LOS──▶ DETECT ──acquired──▶ TRACK ──turret on target──▶ AIM ──warning over──▶ FIRE ──▶ RELOAD
--     ▲                                │                    │ ▲                        │                         │
--     └──────────target lost───────────┴────────────────────┘ └──REPOSITION◀──cannot shoot (range / arc / LOS)    └──▶ TRACK / IDLE
--   DISABLED  turret or hull destroyed: sticky until a reset, never acquires or fires again
--   RESET     the district is being rebuilt: frozen until it finishes, then IDLE
--
-- Senses (all measured by the server this frame):
--   active      combat mode is ACTIVE TRAINING and the arming delay is over
--   alive       hull intact          canFire   turret intact          canMove   tracks + engine intact
--   resetting   district reset in progress
--   hasTarget   a valid, deployed, not-evacuated Bastion in the district exists
--   range       horizontal distance to it          los   clear line to any aim sample
--   inArc       the target lies inside the turret traverse limit
--   aimError    absolute yaw error between the barrel and the (lead-corrected) aim point, radians

local Brain = {}

Brain.States = { "IDLE", "DETECT", "TRACK", "AIM", "FIRE", "RELOAD", "REPOSITION", "DISABLED", "RESET" }

export type Archetype = { [string]: any }

function Brain.New(arch: Archetype)
    return {
        arch = arch, state = "IDLE", t = 0, shots = 0, losLost = 0, settle = 0, since = 0,
        lastReason = "", transitions = 0,
    }
end

local function go(b, state: string, reason: string)
    if b.state ~= state then
        b.state, b.t, b.losLost, b.settle = state, 0, 0, 0
        b.lastReason = reason
        b.transitions += 1
    end
end

-- Hard reset (respawn / explicit reset): back to IDLE with no memory.
function Brain.Reset(b)
    b.state, b.t, b.shots, b.losLost, b.settle, b.transitions, b.lastReason = "IDLE", 0, 0, 0, 0, 0, "reset"
end

local function canShoot(s): boolean
    return s.los and s.inArc and s.range <= s.fireRange
end

-- Advances the machine. Returns { state, fire, turret, move, warn, reload }:
--   fire    true on exactly the frame the cannon discharges
--   turret  "scan" (idle sweep) | "hold" | "track" (full rate) | "aim" (reduced rate, locked on)
--   move    "none" | "patrol" | "reposition" | "slow" | "pivot"
--   warn    0..1 progress of the pre-fire warning (AIM only)
function Brain.Step(b, dt: number, s)
    local a = b.arch
    s.fireRange = a.fireRange
    local out = { fire = false, turret = "hold", move = "none", warn = 0, reload = 0 }
    b.t += dt

    if s.resetting then
        go(b, "RESET", "district reset")
    elseif b.state == "RESET" then
        go(b, "IDLE", "reset complete")
    end
    if b.state ~= "RESET" and b.state ~= "DISABLED" and (not s.alive or not s.canFire) then
        go(b, "DISABLED", if not s.alive then "hull destroyed" else "turret destroyed")
    end

    local state = b.state
    if state == "RESET" or state == "DISABLED" then
        -- A turret-less but mobile tank may still follow its patrol; it never targets or fires.
        out.move = if state == "DISABLED" and s.alive and s.canMove and a.mobility == "ROUTE" then "patrol" else "none"
        out.state = b.state
        return out
    end

    -- Combat withdrawn (PASSIVE RANGE, arming delay, evacuated pilot, undeployed mech): everything in flight is abandoned.
    if not s.active or not s.hasTarget then
        go(b, "IDLE", if not s.active then "combat inactive" else "no target")
        out.turret = "scan"
        out.move = if s.canMove and a.mobility == "ROUTE" then "patrol" else "none"
        out.state = b.state
        return out
    end

    state = b.state
    local inRange = s.range <= a.detectRange
    if state == "IDLE" then
        out.turret = "scan"
        out.move = if s.canMove and a.mobility == "ROUTE" then "patrol" else "none"
        if inRange and s.los then
            go(b, "DETECT", "target acquired")
        end
    elseif state == "DETECT" then
        out.turret = "hold" -- the turret does not move until the crew has "reacted"
        if not inRange or s.range > a.loseRange then
            go(b, "IDLE", "out of range")
        elseif not s.los then
            b.losLost += dt
            if b.losLost > a.loseTime then
                go(b, "IDLE", "lost line of sight")
            end
        else
            b.losLost = 0
            if b.t >= a.detectTime then
                go(b, "TRACK", "acquisition complete")
            end
        end
    elseif state == "TRACK" or state == "REPOSITION" then
        out.turret = "track"
        if s.range > a.loseRange then
            go(b, "IDLE", "out of range")
        elseif not s.los then
            b.losLost += dt
            if b.losLost > a.loseTime then
                go(b, "IDLE", "lost line of sight")
            end
        else
            b.losLost = 0
        end
        if b.state == "TRACK" then
            out.move = if a.mobility == "ROUTE" and s.canMove then "slow" else "none"
            if canShoot(s) and s.aimError <= a.aimTolerance then
                b.settle += dt
                if b.settle >= a.settleTime then
                    go(b, "AIM", "turret on target")
                end
            else
                b.settle = 0
                -- Mobile tanks reposition when they cannot take the shot; fixed ones keep tracking (and are blind outside the arc).
                if (not canShoot(s)) and b.t > 0.6 and a.mobility ~= "FIXED" and s.canMove then
                    go(b, "REPOSITION", if not s.inArc then "target outside traverse" elseif not s.los then "no line of fire" else "out of range")
                end
            end
        elseif b.state == "REPOSITION" then
            out.move = if not s.canMove then "none" elseif a.mobility == "PIVOT" then "pivot" else "reposition"
            if not s.canMove then
                go(b, "TRACK", "immobilized") -- tracks or engine lost mid-manoeuvre: stand and fight
            elseif canShoot(s) then
                b.settle += dt
                if b.settle >= 0.3 then
                    go(b, "TRACK", "firing position reached")
                end
            else
                b.settle = 0
                if b.t > (a.repositionTime or 6) then
                    go(b, "TRACK", "reposition timeout")
                end
            end
        end
    elseif state == "AIM" then
        out.turret = "aim"
        out.move = "none" -- stops to aim
        out.warn = math.clamp(b.t / a.warnTime, 0, 1)
        if not s.los then
            b.losLost += dt
        else
            b.losLost = 0
        end
        if s.range > a.fireRange * 1.05 or not s.inArc or b.losLost > 0.35 then
            go(b, "TRACK", "firing solution lost")
        elseif b.t >= a.warnTime then
            go(b, "FIRE", "warning complete")
            out.fire = true
            b.shots += 1
        end
    elseif state == "FIRE" then
        out.turret = "hold"
        out.move = "none"
        if b.t >= a.fireTime then
            go(b, "RELOAD", "shot away")
        end
    elseif state == "RELOAD" then
        out.turret = "track"
        out.move = if a.mobility == "ROUTE" and s.canMove then "reposition" else "none"
        out.reload = math.clamp(b.t / a.reload, 0, 1)
        if b.t >= a.reload then
            go(b, "TRACK", "reloaded")
        end
    end
    if b.state == "AIM" or b.state == "FIRE" then
        out.move = "none" -- a tank stops to aim and to fire, including on the frame it enters those states
    end
    out.state = b.state
    return out
end

return Brain
