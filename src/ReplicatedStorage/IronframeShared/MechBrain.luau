-- Deterministic tactical brain for an autonomous mech (M10C). Pure: numbers and booleans in, an order table out. No Roblox types,
-- no clock, no randomness of its own (the caller injects an rng so tests are repeatable). The server (EnemyMech) measures the
-- senses, runs the orders through the REAL locomotion, weapon-state, energy and shield modules and reports back.
--
--   IDLE ──contact──▶ ACQUIRE ──reaction delay──▶ APPROACH ──in band──▶ ENGAGE ◀──────────────┐
--     ▲                  │                          │  ▲                  │ ▲                  │
--     │ memory expired   └──lost──▶ IDLE            │  └──── arrived ─────┤ │ back to work     │
--     └─────────────── REPOSITION ◀── lost LOS / flank / too close / cover / low energy ───────┘
--   DEFEND   shield raised (reaction-delayed, directional); returns to ENGAGE when the cycle is over
--   DISABLED sticky until a trial reset: core failure, or both weapon assemblies destroyed
--   RESET    the trial is being rebuilt; frozen
--
-- Senses (all measured by the server this frame; "estimate" = where ROOK believes the target is, which is stale or noisy when the
-- target is not in view):
--   active resetting coreAlive            weaponsOnline = { MG, LR }  (assembly alive)
--   seen   hasTarget  sinceSeen           range bearing targetSpeed (estimate)   bearing is relative to the chassis, + = to the right
--   lane   (optional, default true) the weapons' line to the target torso is clear: the head sensor may see a target that the arm guns cannot
--          hit (it peeks over a wall), and ROOK neither fires nor holds a position like that
--   ownSpeedFrac  legs  reactor           charge (capacitor fraction)  thermal 0..1
--   availWeapons (what ONE discrete payment may draw right now: the burst bucket)   weaponBudget (capacitor energy above the weapon reserve:
--   what a whole burst / volley may draw over its duration)
--   mg = { ammo, reloading, burstCost }   lr = { volleyCost }          shield = { ready }
--   threat = { level 0..1, bearing }      structure (0..1)             nav = { arrived, noPath, stuck, awayFromStation }
--
-- Orders:
--   state reason
--   move   { mode = hold|approach|retreat|reposition|station, cap }   face = hold|target|travel|threat
--   repick  true on the frame a new tactical position is needed          reposition = reason of the manoeuvre
--   attack  nil | { id = "MG"|"LR", phase, progress, trigger, locked }  trigger is true while rounds should be leaving
--   shield  true on the frame the shield is pressed                      profile  desired energy profile

local Brain = {}

Brain.States = { "IDLE", "ACQUIRE", "APPROACH", "ENGAGE", "REPOSITION", "DEFEND", "DISABLED", "RESET" }

-- Small deterministic generator (Park-Miller) so tests and the server get the same stream from the same seed.
function Brain.Rng(seed: number)
    local state = (seed % 2147483646) + 1
    return function(): number
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
end

function Brain.New(def, rng: (() -> number)?)
    return {
        def = def, rng = rng or Brain.Rng(1), state = "IDLE", t = 0, clock = 0, reason = "boot", transitions = 0,
        cool = { MG = 0, LR = 0 }, attack = nil, lost = 0, profile = def.startProfile or "BALANCED", wantProfile = nil, wantSince = 0,
        reposition = nil, flankAt = nil, coverAt = -100, dwell = nil, after = "ENGAGE",
        threatSince = nil, react = false, reactAt = 0, lastShield = -100, defendFor = 0, acquireFor = 0, seenFor = 0,
        shots = { MG = 0, LR = 0 }, shields = 0, aborted = 0,
    }
end

local function go(b, state: string, reason: string)
    if b.state ~= state then
        b.state, b.t, b.reason = state, 0, reason
        b.transitions += 1
        b.lost, b.seenFor = 0, 0
    end
end

local function clamp(v: number, lo: number, hi: number): number
    return if v < lo then lo elseif v > hi then hi else v
end

-- Aim error half-angle for a weapon (radians). Bounded below by the weapon's own spread, grows with a fast target, with ROOK's own
-- motion and with a damaged weapon assembly: ROOK never lands every shot.
function Brain.AimSpread(def, w, s): number
    local a = def.accuracy
    local m = (1 + a.targetSpeedGain * (s.targetSpeed or 0) / 14) * (1 + a.ownSpeedGain * (s.ownSpeedFrac or 0))
    if s.range and s.range < math.huge then
        m *= 1 + (a.rangeGain or 0) * s.range / 100
    end
    m *= 1 + a.damagedArmGain * (1 - (s.armHealth and s.armHealth[w.key] or 1))
    return w.spread * clamp(m, 1, a.maxMultiplier)
end

-- Weapon doctrine ---------------------------------------------------------------------------------------------------------------
local function mgUsable(b, s): (boolean, string?)
    local w = b.def.weapons
    if not s.weaponsOnline.MG then return false, "assembly offline" end
    if b.cool.MG > 0 then return false, "gap" end
    if s.mg.reloading then return false, "reloading" end
    if s.mg.ammo < w.minAmmoForBurst then return false, "magazine low" end
    if s.availWeapons < 0.6 or (s.weaponBudget or s.availWeapons) < s.mg.burstCost then return false, "energy" end
    if s.range > w.MG.maxRange then return false, "range" end
    return true, nil
end

local function lrUsable(b, s, moving: boolean): (boolean, string?)
    local w = b.def.weapons
    if not s.weaponsOnline.LR then return false, "assembly offline" end
    if b.cool.LR > 0 then return false, "cooldown" end
    if moving then return false, "unstable platform" end
    if s.range < w.LR.minRange or s.range > w.LR.maxRange then return false, "range" end
    if (s.targetSpeed or 0) > w.lrMaxTargetSpeed then return false, "target too fast" end
    -- Energy discipline: a depleted capacitor, a damaged reactor or a hot machine withholds the laser; the cheap gun carries on.
    local need = w.lowEnergy + (1 - (s.reactor or 1)) * 0.5
    if s.charge < need then return false, "capacitor low" end
    if s.availWeapons < 24 or (s.weaponBudget or s.availWeapons) < s.lr.volleyCost + w.LR.chargeDraw * w.LR.charge then return false, "energy" end
    if s.thermal >= 0.85 then return false, "overheated" end
    return true, nil
end

-- Which weapon would ROOK start now? Returns id or nil, plus the reason it declined.
function Brain.ChooseWeapon(b, s, moving: boolean?): (string?, string)
    local w = b.def.weapons
    local mgOk, mgWhy = mgUsable(b, s)
    local lrOk, lrWhy = lrUsable(b, s, moving == true)
    if moving then
        lrOk, lrWhy = false, "unstable platform"
    end
    local weaponsProfile = b.profile == "WEAPONS"
    if lrOk and (weaponsProfile or s.range >= w.lrPreferRange or not mgOk) then
        return "LR", "laser"
    end
    if mgOk then
        return "MG", "gun"
    end
    if lrOk then
        return "LR", "laser"
    end
    return nil, (mgWhy or "none") .. " / " .. (lrWhy or "none")
end

local function abortAttack(b, why: string, cooldown: number)
    local a = b.attack
    if a then
        b.cool[a.id] = math.max(b.cool[a.id], cooldown)
        b.attack = nil
        b.aborted += 1
        b.lastAbort = why
    end
end

local function finishAttack(b)
    local a = b.attack
    if a then
        local w = b.def.weapons[a.id]
        b.cool[a.id] = math.max(b.cool[a.id], if a.id == "LR" then w.cooldown else w.gap)
        b.shots[a.id] += 1
        b.attack = nil
    end
end

local function inFiringCone(b, s): boolean
    return math.abs(s.bearing) <= b.def.perception.fireCone
end

-- Runs the attack plan for this frame. `moving` is whether the chassis is travelling (an LR charge cannot start or continue then).
local function attackStep(b, s, o, dt: number, moving: boolean, may: boolean)
    local d = b.def
    local a = b.attack
    if a then
        a.t += dt
        local w = d.weapons[a.id]
        local why: string? = nil
        if not s.weaponsOnline[a.id] then
            why = "assembly offline"
        elseif not may then
            why = "interrupted"
        elseif a.phase ~= "VOLLEY" and a.phase ~= "BURST" and not s.sight then
            why = "contact lost"
        elseif a.id == "LR" and not a.locked and not inFiringCone(b, s) and math.abs(s.bearing) > d.perception.fireCone * 2 then
            why = "target off axis"
        elseif a.id == "LR" and a.phase == "CHARGE" and moving then
            why = "unstable platform"
        elseif a.phase == "CHARGE" and s.availWeapons <= 0 and s.charge < 0.05 then
            why = "energy starved"
        end
        if why then
            abortAttack(b, why, if a.id == "LR" then 1.6 else 0.6)
            return
        end
        if a.id == "MG" then
            local burstTime = w.burst * (s.mg.interval or 0.1)
            if a.phase == "SPOOL" and a.t >= w.spool then
                a.phase, a.t = "BURST", 0
            elseif a.phase == "BURST" and a.t >= burstTime then
                finishAttack(b)
                return
            end
            o.attack = { id = "MG", phase = a.phase, progress = clamp(a.t / (if a.phase == "SPOOL" then w.spool else burstTime), 0, 1), trigger = a.phase == "BURST", locked = false }
        else
            local volleyTime = w.pulses * (s.lr.interval or w.gap)
            if a.phase == "CHARGE" then
                if a.t >= w.charge * w.lockAt then
                    a.locked = true
                end
                if a.t >= w.charge then
                    a.phase, a.t = "VOLLEY", 0
                end
            elseif a.phase == "VOLLEY" and a.t >= volleyTime then
                finishAttack(b)
                return
            end
            o.attack = { id = "LR", phase = a.phase, progress = clamp(a.t / (if a.phase == "CHARGE" then w.charge else volleyTime), 0, 1), trigger = a.phase == "VOLLEY", locked = a.locked == true }
        end
        return
    end
    -- No plan running: start one when allowed.
    if not may or not s.sight or not inFiringCone(b, s) or b.seenFor < 0.25 then
        return
    end
    local id = Brain.ChooseWeapon(b, s, moving)
    if id then
        b.attack = { id = id, phase = if id == "MG" then "SPOOL" else "CHARGE", t = 0, locked = false }
        b.attackStarts = (b.attackStarts or 0) + 1
        local w = d.weapons[id]
        o.attack = { id = id, phase = b.attack.phase, progress = 0, trigger = false, locked = false, started = true, duration = if id == "MG" then w.spool else w.charge }
    end
end

-- Shield decision -------------------------------------------------------------------------------------------------------------------
-- Returns true on the frame the shield should be pressed. A threat is noticed, then (after a bounded, jittered reaction delay and
-- only with some probability) answered - and only if the attacker is in front, the shield is ready and the capacitor can pay.
local function shieldStep(b, s): (boolean, boolean)
    local d = b.def.defense
    local th = s.threat
    if not th or th.level <= 0 then
        b.threatSince, b.react = nil, false
        return false, false
    end
    if not b.threatSince then
        b.threatSince = b.clock
        b.reactAt = b.clock + d.reaction + b.rng() * d.reactionJitter
        b.react = b.rng() < d.reactChance
    end
    if not b.react or b.clock < b.reactAt then
        return false, false
    end
    if math.abs(th.bearing) > d.arc then
        return false, true -- it noticed, but it is facing the wrong way: turn first
    end
    if not s.shield.ready or s.charge < d.minCharge or b.clock - b.lastShield < d.minGap then
        return false, false
    end
    b.lastShield = b.clock
    b.shields += 1
    return true, false
end

-- Energy profile -----------------------------------------------------------------------------------------------------------------------
-- MOBILITY to relocate, WEAPONS to prepare / run a laser volley, BALANCED otherwise. The wish must persist (hysteresis); the
-- server still obeys the profile switch delay and minimum interval.
function Brain.ChooseProfile(b, s, mobile: boolean): string
    local e = b.def.energy
    local want = "BALANCED"
    if s.charge < e.lowCharge then
        want = "BALANCED" -- keep the shield and weapon reserves intact while starved
    elseif mobile then
        want = "MOBILITY"
    elseif (b.attack and b.attack.id == "LR") or (b.state == "ENGAGE" and s.seen and s.charge >= e.weaponsMinCharge and b.cool.LR <= 0 and s.weaponsOnline.LR) then
        want = "WEAPONS"
    end
    return want
end

local function profileStep(b, s, o, mobile: boolean)
    local want = Brain.ChooseProfile(b, s, mobile)
    if want ~= b.wantProfile then
        b.wantProfile, b.wantSince = want, b.clock
    end
    -- s.profile is the active-or-pending profile reported by the server; the server also refuses switches inside the cooldown.
    if want ~= b.profile and b.clock - b.wantSince >= b.def.energy.profileHold then
        o.profile = want
    end
end

-- Step ---------------------------------------------------------------------------------------------------------------------------
function Brain.Step(b, dt: number, s)
    local d = b.def
    local p, tac = d.perception, d.tactics
    b.clock += dt
    b.t += dt
    local o = { state = b.state, reason = b.reason, move = { mode = "hold", cap = 0 }, face = "hold", attack = nil, shield = false, profile = nil, repick = false, reposition = nil }
    for key, value in pairs(b.cool) do
        b.cool[key] = math.max(0, value - dt)
    end
    if s.profile then
        b.profile = s.profile
    end

    if s.resetting then
        go(b, "RESET", "trial reset")
    elseif b.state == "RESET" then
        go(b, "IDLE", "reset complete")
    end
    if b.state ~= "RESET" and b.state ~= "DISABLED" then
        if not s.coreAlive then
            go(b, "DISABLED", "core failure")
        elseif not (s.weaponsOnline.MG or s.weaponsOnline.LR) then
            go(b, "DISABLED", "weapons destroyed")
        end
    end
    if b.state == "RESET" or b.state == "DISABLED" then
        b.attack, b.reposition, b.dwell = nil, nil, nil
        o.state, o.reason = b.state, b.reason
        return o
    end
    if not s.active then
        go(b, "IDLE", "trial inactive")
        b.attack, b.reposition = nil, nil
        -- Standing down: walk back to the station pad, sensors and weapons off.
        if s.nav.awayFromStation then
            o.move, o.face = { mode = "station", cap = 0.55 }, "travel"
        end
        o.state, o.reason = b.state, b.reason
        return o
    end

    local aware = s.seen or s.sinceSeen < p.memory
    local sight = s.seen and s.lane ~= false -- seen AND able to shoot
    s.sight = sight
    b.seenFor = if sight then b.seenFor + dt else 0
    local moving = (s.ownSpeedFrac or 0) > tac.brakeNoFire
    local legs = s.legs or 1
    local state = b.state

    -- Shield: any combat state may answer a threat.
    local defendable = state == "ENGAGE" or state == "APPROACH" or state == "REPOSITION" or state == "ACQUIRE"
    local turnToThreat = false
    if state ~= "DEFEND" and defendable and not (b.attack and b.attack.id == "LR" and b.attack.phase ~= "CHARGE") then
        local press, turn = shieldStep(b, s)
        turnToThreat = turn
        if press then
            o.shield = true
            b.after = if state == "ACQUIRE" or state == "REPOSITION" then "ENGAGE" else state
            abortAttack(b, "shielding", 0.5)
            go(b, "DEFEND", "incoming fire")
            state = "DEFEND"
        end
    elseif state == "DEFEND" then
        shieldStep(b, s) -- keeps the threat bookkeeping current
    end

    if state == "IDLE" then
        b.attack = nil
        o.move = if s.nav.awayFromStation and not aware then { mode = "station", cap = 0.6 } else { mode = "hold", cap = 0 }
        o.face = if s.nav.awayFromStation and not aware then "travel" else "hold"
        if s.seen then
            go(b, "ACQUIRE", "contact")
            b.acquireFor = p.acquireTime * (0.85 + 0.3 * b.rng())
        elseif aware and s.sinceSeen < 3 then
            go(b, "ACQUIRE", "heard")
            b.acquireFor = p.acquireTime * (0.85 + 0.3 * b.rng())
        end
    elseif state == "ACQUIRE" then
        o.face = "target"
        if not aware and b.t > 2 then
            go(b, "IDLE", "contact lost")
        elseif b.t >= b.acquireFor then
            if not s.seen then
                go(b, "REPOSITION", "search")
                b.reposition = { reason = "search", since = b.clock }
                o.repick = true
            elseif s.range > tac.band[2] + 8 then
                go(b, "APPROACH", "acquired")
            else
                go(b, "ENGAGE", "acquired")
                b.flankAt = b.clock + tac.flankEvery + b.rng() * tac.flankJitter
            end
        end
    elseif state == "APPROACH" then
        o.face = "travel"
        o.move = { mode = "approach", cap = tac.approachCap }
        if s.seen then
            b.lost = 0
            if s.range <= tac.band[2] then
                go(b, "ENGAGE", "in range")
                b.flankAt = b.clock + tac.flankEvery + b.rng() * tac.flankJitter
            end
        else
            b.lost += dt
            if b.lost > p.lostLosHold then
                if aware then
                    go(b, "REPOSITION", "regain_los")
                    b.reposition = { reason = "regain_los", since = b.clock }
                    o.repick = true
                else
                    go(b, "IDLE", "contact lost")
                end
            end
        end
        attackStep(b, s, o, dt, moving, true)
    elseif state == "ENGAGE" then
        o.face = "target"
        if sight then
            b.lost = 0
        else
            b.lost += dt
        end
        local lowStructure = s.structure < tac.coverBelow
        local starved = s.charge < d.energy.lowCharge
        if not aware then
            go(b, "IDLE", "contact lost")
        elseif b.lost > p.lostLosHold then
            go(b, "REPOSITION", "regain_los")
            b.reposition = { reason = "regain_los", since = b.clock }
            o.repick = true
        elseif s.seen and s.range < tac.tooClose and legs >= 0.6 and not (b.attack and b.attack.phase ~= "SPOOL") then
            go(b, "REPOSITION", "range")
            b.reposition = { reason = "range", since = b.clock }
            o.repick = true
        elseif (lowStructure or starved) and b.clock - b.coverAt > 14 and not (b.attack and b.attack.id == "LR" and b.attack.phase ~= "CHARGE") then
            go(b, "REPOSITION", "cover")
            b.reposition = { reason = if lowStructure then "cover" else "recover_energy", since = b.clock }
            b.coverAt = b.clock
            o.repick = true
        elseif b.flankAt and b.clock >= b.flankAt and not b.attack and legs >= 0.75 and s.seen and b.seenFor > 1.0 then
            go(b, "REPOSITION", "flank")
            b.reposition = { reason = "flank", since = b.clock }
            o.repick = true
        else
            -- Hold the band. While a weapon is spooling / charging / firing the machine stands still: a stable firing solution.
            local steady = b.attack ~= nil
            if steady then
                o.move = { mode = "hold", cap = 0 }
            elseif s.range > tac.band[2] + 6 then
                o.move = { mode = "approach", cap = tac.approachCap * 0.6 }
                o.face = "travel"
            elseif s.range < tac.band[1] - 4 and legs >= 0.6 then
                o.move = { mode = "retreat", cap = tac.retreatCap }
            end
            if s.seen and s.range > tac.band[2] + 30 and not steady then
                go(b, "APPROACH", "target moved away")
            end
        end
        if b.state == "ENGAGE" then
            attackStep(b, s, o, dt, moving, true)
        end
    elseif state == "REPOSITION" then
        local r = b.reposition or { reason = "regain_los", since = b.clock }
        b.reposition = r
        o.reposition = r.reason
        o.face = "travel"
        o.move = { mode = "reposition", cap = if r.reason == "range" then tac.retreatCap + 0.3 else 1.0 }
        if r.reason == "search" and s.seen then
            r.reason = "regain_los"
        end
        local done: string? = nil
        if r.reason == "regain_los" or r.reason == "search" then
            if sight and b.seenFor >= 0.4 then
                done = if s.range > tac.band[2] + 8 then "APPROACH" else "ENGAGE"
            elseif not aware then
                go(b, "IDLE", "contact lost")
            elseif s.nav.arrived or s.nav.noPath or s.nav.stuck then
                o.repick = true
            end
        elseif r.reason == "flank" then
            if s.nav.arrived then
                done = "ENGAGE"
            elseif s.nav.noPath or s.nav.stuck then
                done = "ENGAGE"
            end
        elseif r.reason == "range" then
            if s.range >= tac.band[1] - 6 or s.nav.arrived then
                done = "ENGAGE"
            elseif s.nav.noPath or s.nav.stuck then
                done = "ENGAGE"
            end
        elseif r.reason == "cover" or r.reason == "recover_energy" then
            if not r.dwellStart and (s.nav.arrived or s.nav.noPath or s.nav.stuck) then
                r.dwellStart = b.clock
            end
            if r.dwellStart then
                o.move = { mode = "hold", cap = 0 }
                o.face = "target"
                local recovered = s.charge >= tac.coverRecoverTo and s.structure >= tac.coverBelow * 0.5
                if recovered or b.clock - r.dwellStart >= tac.coverDwell then
                    r.reason, r.since, r.dwellStart = "regain_los", b.clock, nil
                    o.repick = true
                end
            end
        end
        if b.clock - r.since > tac.repositionTimeout and r.reason ~= "cover" and r.reason ~= "recover_energy" then
            done = if s.seen then (if s.range > tac.band[2] + 8 then "APPROACH" else "ENGAGE") else nil
            if not done then
                r.since = b.clock
                o.repick = true
            end
        end
        if done and b.state == "REPOSITION" then
            go(b, done, "manoeuvre complete")
            b.reposition = nil
            if done == "ENGAGE" then
                b.flankAt = b.clock + tac.flankEvery + b.rng() * tac.flankJitter
            end
        end
        if b.state == "REPOSITION" then
            attackStep(b, s, o, dt, moving, true)
        end
    elseif state == "DEFEND" then
        b.attack = nil
        o.face = if s.threat and s.threat.level > 0 then "threat" else "target"
        o.move = { mode = "hold", cap = 0 }
        local cycle = b.def.defense.cycle or 1.15
        if b.t >= cycle then
            go(b, b.after or "ENGAGE", "guard complete")
            b.flankAt = b.clock + tac.flankEvery + b.rng() * tac.flankJitter
        end
    end

    if turnToThreat and b.state ~= "DEFEND" and not b.attack then
        o.face = "threat"
    end

    -- Energy profile follows what the machine is about to do.
    local travelling = b.state == "REPOSITION" and (b.reposition ~= nil and b.reposition.reason ~= "cover" or false)
    profileStep(b, s, o, travelling or (b.state == "APPROACH" and s.range > tac.band[2] + d.energy.mobilityRange))

    o.state, o.reason = b.state, b.reason
    return o
end

return Brain
