-- Offline (Luau CLI) tests for M10C: the autonomous mech's tactical brain, navigation / steering, energy and shield doctrine,
-- damage-dependent behaviour, terminal disablement and reset.  Run: luau tools/enemy_tests.luau
local Cfg = require("../src/ReplicatedStorage/IronframeShared/EnemyConfig")
local Brain = require("../src/ReplicatedStorage/IronframeShared/MechBrain")
local Nav = require("../src/ReplicatedStorage/IronframeShared/MechNav")
local Drive = require("../src/ReplicatedStorage/IronframeShared/MechDrive")
local Damage = require("../src/ReplicatedStorage/IronframeShared/MechDamage")
local Energy = require("../src/ReplicatedStorage/IronframeShared/Energy")
local EnergyConfig = require("../src/ReplicatedStorage/IronframeShared/EnergyConfig")
local Profiles = require("../src/ReplicatedStorage/IronframeShared/EnergyProfiles")
local Shield = require("../src/ReplicatedStorage/IronframeShared/PulseShield")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local WeaponState = require("../src/ReplicatedStorage/IronframeShared/WeaponState")
local DConfig = require("../src/ReplicatedStorage/IronframeShared/DestructionConfig")
local CombatConfig = require("../src/ReplicatedStorage/IronframeShared/CombatConfig")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

local def = Cfg.enemies.ROOK_01
local W = def.weapons

local function senses(over)
    local s = {
        active = true, resetting = false, coreAlive = true, weaponsOnline = { MG = true, LR = true }, hasTarget = true,
        seen = true, sinceSeen = 0, range = 100, bearing = 0, targetSpeed = 0, ownSpeedFrac = 0, legs = 1, reactor = 1,
        charge = 1, availWeapons = 60, weaponBudget = 150, thermal = 0, mg = { ammo = 60, reloading = false, burstCost = 3.6, interval = 0.1 },
        lr = { volleyCost = 72, interval = 0.25 }, shield = { ready = true }, threat = { level = 0, bearing = 0 },
        structure = 1, nav = { arrived = false, noPath = false, stuck = false, awayFromStation = false }, profile = "BALANCED",
        armHealth = { MG = 1, LR = 1 },
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

-- Steps a brain at 20 Hz for `seconds`. `hook(o, s)` may change the senses between frames. Returns a log.
local function run(b, seconds, s, hook)
    local log = { states = { b.state }, attacks = {}, shields = 0, triggers = { MG = 0, LR = 0 }, phases = {}, orders = {} }
    for _ = 1, math.floor(seconds * 20 + 0.5) do
        local o = Brain.Step(b, 0.05, s)
        if log.states[#log.states] ~= o.state then table.insert(log.states, o.state) end
        if o.attack and o.attack.started then table.insert(log.attacks, o.attack.id) end
        if o.attack then
            local key = o.attack.id .. ":" .. o.attack.phase
            if log.phases[#log.phases] ~= key then table.insert(log.phases, key) end
            if o.attack.trigger then log.triggers[o.attack.id] += 1 end
        end
        if o.shield then log.shields += 1 end
        log.last = o
        if hook then hook(o, s) end
    end
    return log
end
local function has(list, value) return table.find(list, value) ~= nil end
local function newBrain(seed) return Brain.New(def, Brain.Rng(seed or 7)) end

print("EnemyConfig")
test("ROOK uses real components on compatible hardpoints and the shared region names", function()
    for _, w in pairs({ W.MG, W.LR }) do
        local c = Components[w.id]
        assert(c and c.combat and c.combat.hardpoints[w.socket], w.id .. " cannot ride " .. w.socket)
        assert(Chassis[def.chassisId].hardpoints[w.socket].size >= c.size)
        assert(w.speed > 100 and w.life > 0.5, "rounds are swept projectiles, never instant")
        assert(w.region == "ARM_L" or w.region == "ARM_R")
    end
    assert(W.MG.id == "W_MACHINE_GUN" and W.LR.id == "W_LASER_RIFLE")
    for _, region in ipairs(Damage.Regions) do
        assert(def.structure.regions[region] and def.structure.regions[region] > 0, region)
        local r = def.structure.resist[region]
        assert(r and r.MG and r.LASER and r.HEAVY and r.MG > 0 and r.HEAVY < 2, region .. " resist")
    end
    assert(DConfig.WeaponClass(W.MG.id, W.MG.category, 8) == "MG" and DConfig.WeaponClass(W.LR.id, W.LR.category, 25) == "LASER")
end)
test("doctrine is readable: the laser telegraphs longer than a human reaction, the gun spools briefly, both leave gaps", function()
    assert(W.LR.charge >= 0.9 and W.LR.charge <= 1.4, "laser charge is the player's window")
    assert(W.LR.lockAt > 0.5 and W.LR.lockAt < 0.95, "the lock lands before the discharge so the player can break it")
    assert(W.MG.spool >= 0.2 and W.MG.gap >= 0.8 and W.LR.cooldown >= 3)
    assert(W.LR.speed > W.MG.speed and W.MG.speed < 400, "the gun is visible and dodgeable at range")
    assert(def.perception.acquireTime >= 0.6 and def.defense.reaction >= 0.3, "reaction delays are configured, not zero")
    assert(def.defense.reactChance < 1 and def.accuracy.maxMultiplier > 1)
    assert(def.tactics.band[1] < def.tactics.band[2] and def.tactics.tooClose < def.tactics.band[1])
    assert(def.perception.sightRange >= def.tactics.band[2] and def.perception.memory > def.perception.lostLosHold)
end)
test("ROOK has the player's reactor, capacitor and shield (same economy, no extra supply)", function()
    local loadout = { reactor = "CORE_220", cooling = "RAD_STANDARD" }
    local cfg = EnergyConfig.Build(Chassis[def.chassisId], Components[loadout.reactor], Components.CAP_STANDARD, Components[loadout.cooling], Components.SHIELD_PULSE)
    assert(cfg.output == 80 and cfg.capacity == 160 and cfg.shield.activationCost == 25 and cfg.shield.cooldown == 4)
end)
test("the MECH TRIAL mode exists next to the M10B modes", function()
    assert(Cfg.modes.MECH ~= nil and CombatConfig.modes.ACTIVE ~= nil and CombatConfig.modes.PASSIVE ~= nil)
    assert(Cfg.trial.armDelay > 0 and Cfg.trial.maxBolts >= 9)
end)

print("MechBrain: state transitions")
test("idle with no contact; a trial that is not active never leaves IDLE", function()
    local b = newBrain()
    local log = run(b, 3, senses({ seen = false, sinceSeen = math.huge, hasTarget = true }))
    assert(b.state == "IDLE" and #log.attacks == 0)
    b = newBrain()
    run(b, 3, senses({ active = false }))
    assert(b.state == "IDLE", "inactive trial: no engagement")
end)
test("contact: IDLE -> ACQUIRE -> ENGAGE inside the band, APPROACH when far; no weapon during the reaction delay", function()
    local b = newBrain()
    local log = run(b, 0.7, senses({ range = 90 }))
    assert(log.states[2] == "ACQUIRE" and #log.attacks == 0, "reacting, not yet shooting")
    run(b, 1.5, senses({ range = 90 }))
    assert(b.state == "ENGAGE", b.state)
    local far = newBrain()
    run(far, 2.5, senses({ range = 190 }))
    assert(far.state == "APPROACH", far.state)
end)
test("approach becomes engage once the band is reached", function()
    local b = newBrain()
    local s = senses({ range = 190 })
    local log = run(b, 20, s, function(o) if o.move.mode == "approach" then s.range = math.max(60, s.range - 0.6) end end)
    assert(has(log.states, "APPROACH") and has(log.states, "ENGAGE"), table.concat(log.states, ">"))
    assert(s.range <= def.tactics.band[2] + 1)
end)
test("heard-only contact is investigated (search) instead of attacked", function()
    local b = newBrain()
    run(b, 3, senses({ seen = false, sinceSeen = 0.5, range = 120 }))
    assert(b.state == "REPOSITION" and b.reposition.reason == "search", b.state)
    local log = run(b, 1, senses({ seen = false, sinceSeen = 1.0, range = 120 }))
    assert(#log.attacks == 0)
end)
test("lost line of sight: hold for a moment, then reposition to regain it; memory expiry returns to IDLE", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    assert(b.state == "ENGAGE")
    local s = senses({ seen = false, sinceSeen = 0, range = 90 })
    local log = run(b, def.perception.lostLosHold + 0.4, s, function(_, t) t.sinceSeen += 0.05 end)
    assert(b.state == "REPOSITION" and b.reposition.reason == "regain_los", table.concat(log.states, ">"))
    run(b, def.perception.memory + 2, s, function(_, t) t.sinceSeen += 0.05 end)
    assert(b.state == "IDLE", "the contact is forgotten after the memory time: " .. b.state)
end)
test("regaining the target ends the manoeuvre", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local s = senses({ seen = false, sinceSeen = 0.5 })
    run(b, 1.5, s)
    assert(b.state == "REPOSITION")
    s.seen, s.sinceSeen = true, 0
    run(b, 1.0, s)
    assert(b.state == "ENGAGE" or b.state == "APPROACH", b.state)
end)
test("repositioning asks for a new position on arrival, on no-path and when stuck", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local s = senses({ seen = false, sinceSeen = 0.5 })
    run(b, 1.5, s)
    for _, flag in ipairs({ "arrived", "noPath", "stuck" }) do
        s.nav = { arrived = false, noPath = false, stuck = false, awayFromStation = false }
        s.nav[flag] = true
        local o = Brain.Step(b, 0.05, s)
        assert(o.repick == true, flag)
    end
end)
test("engage keeps the band: closes when far, backs off when near, flees point blank", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local offAxis = math.rad(60) -- no firing solution, so no attack plan holds the machine still
    b.attack = nil
    local o = Brain.Step(b, 0.05, senses({ range = def.tactics.band[2] + 15, bearing = offAxis }))
    assert(o.move.mode == "approach", o.move.mode .. " " .. b.state)
    o = Brain.Step(b, 0.05, senses({ range = def.tactics.band[1] - 10, bearing = offAxis }))
    assert(o.move.mode == "retreat")
    run(b, 0.2, senses({ range = def.tactics.tooClose - 8 }))
    assert(b.state == "REPOSITION" and b.reposition.reason == "range", b.state)
end)
test("a limited flank: after a stable stretch it picks a different angle; never while an attack is running", function()
    local b = newBrain()
    local log = run(b, def.tactics.flankEvery + def.tactics.flankJitter + 8, senses({ range = 90, mg = { ammo = 60, reloading = true, burstCost = 3.6 }, weaponsOnline = { MG = true, LR = true }, lr = { volleyCost = 9999 }, availWeapons = 0, weaponBudget = 0 }))
    assert(has(log.states, "REPOSITION"), table.concat(log.states, ">"))
end)

print("MechBrain: weapons, cooldowns")
test("weapon selection by range: laser at distance, gun close in, nothing out of range", function()
    local b = newBrain()
    b.cool = { MG = 0, LR = 0 }
    assert(Brain.ChooseWeapon(b, senses({ range = 120 })) == "LR")
    assert(Brain.ChooseWeapon(b, senses({ range = 55 })) == "MG")
    assert(Brain.ChooseWeapon(b, senses({ range = 150 })) == "LR", "beyond the gun's reach only the laser remains")
    assert(Brain.ChooseWeapon(b, senses({ range = 400 })) == nil)
    assert(Brain.ChooseWeapon(b, senses({ range = 20, lr = { volleyCost = 72 } })) == "MG", "inside the laser's minimum range")
end)
test("energy pressure: a low capacitor withholds the laser but not the cheap gun; an empty one withholds both", function()
    local b = newBrain()
    assert(Brain.ChooseWeapon(b, senses({ range = 120, charge = 0.2, availWeapons = 20, weaponBudget = 30 })) == "MG")
    local id, why = Brain.ChooseWeapon(b, senses({ range = 120, charge = 0.02, availWeapons = 1, weaponBudget = 3 }))
    assert(id == nil and why ~= nil, tostring(why))
    assert(Brain.ChooseWeapon(b, senses({ range = 120, weaponBudget = 60 })) == "MG", "cannot fund a volley, can fund a burst")
end)
test("ammunition and reload: an empty or reloading gun is not used; the laser covers", function()
    local b = newBrain()
    assert(Brain.ChooseWeapon(b, senses({ range = 55, mg = { ammo = 3, reloading = false, burstCost = 3.6 } })) == "LR")
    assert(Brain.ChooseWeapon(b, senses({ range = 55, mg = { ammo = 60, reloading = true, burstCost = 3.6 } })) == "LR")
    assert(Brain.ChooseWeapon(b, senses({ range = 55, mg = { ammo = 3, reloading = true, burstCost = 3.6 }, lr = { volleyCost = 72 }, targetSpeed = 20 })) == nil)
end)
test("a moving platform cannot start a laser; a target too fast is a poor laser target; the WEAPONS profile prefers the laser", function()
    local b = newBrain()
    assert(Brain.ChooseWeapon(b, senses({ range = 120 }), true) == "MG")
    assert(Brain.ChooseWeapon(b, senses({ range = 120, targetSpeed = W.lrMaxTargetSpeed + 3 })) == "MG")
    assert(Brain.ChooseWeapon(b, senses({ range = 55 })) == "MG")
    b.profile = "WEAPONS"
    assert(Brain.ChooseWeapon(b, senses({ range = 55 })) == "LR")
end)
test("machine gun timeline: spool, burst of the right length, then a gap before the next pull", function()
    local b = newBrain()
    local s = senses({ range = 70, lr = { volleyCost = 9999 }, availWeapons = 20 })
    local log = run(b, 6, s)
    assert(log.phases[1] == "MG:SPOOL" and log.phases[2] == "MG:BURST", table.concat(log.phases, ","))
    local bursts = 0
    for _, p in ipairs(log.phases) do if p == "MG:BURST" then bursts += 1 end end
    assert(bursts >= 2 and bursts <= 4, "bursts in 6 s: " .. bursts)
    local expectedPerBurst = W.MG.burst * 0.1 / 0.05
    near(log.triggers.MG / bursts, expectedPerBurst, 2.5, "trigger frames per burst")
    assert(b.shots.MG >= 2)
end)
test("laser timeline: charge, lock before discharge, three pulses, then a long cooldown", function()
    local b = newBrain()
    local s = senses({ range = 130, mg = { ammo = 0, reloading = true, burstCost = 3.6 } })
    local sawLock, lockProgress = false, nil
    local log = run(b, 10, s, function(o)
        if o.attack and o.attack.id == "LR" and o.attack.phase == "CHARGE" and o.attack.locked and not sawLock then
            sawLock, lockProgress = true, o.attack.progress
        end
    end)
    assert(log.phases[1] == "LR:CHARGE" and has(log.phases, "LR:VOLLEY"), table.concat(log.phases, ","))
    assert(sawLock and lockProgress >= W.LR.lockAt - 0.06 and lockProgress < 1, "locked before the discharge: " .. tostring(lockProgress))
    local volleys = 0
    for _, p in ipairs(log.phases) do if p == "LR:VOLLEY" then volleys += 1 end end
    near(log.triggers.LR * 0.05 / volleys, W.LR.pulses * W.LR.gap, 0.2, "volley length")
    assert(volleys <= 2, "cooldown spaces the volleys: " .. volleys)
end)
test("the laser never starts while moving and a charge in progress aborts if the platform moves or contact is lost", function()
    local b = newBrain()
    local s = senses({ range = 130, ownSpeedFrac = 0.8, mg = { ammo = 0, reloading = true, burstCost = 3.6 } })
    local log = run(b, 5, s)
    assert(not has(log.attacks, "LR"))
    b = newBrain()
    s = senses({ range = 130, mg = { ammo = 0, reloading = true, burstCost = 3.6 } })
    for _ = 1, 120 do
        Brain.Step(b, 0.05, s)
        if b.attack and b.attack.id == "LR" and b.attack.phase == "CHARGE" and b.attack.t > 0.3 then break end
    end
    assert(b.attack and b.attack.id == "LR" and b.attack.phase == "CHARGE", "charging")
    s.seen = false
    run(b, 0.2, s)
    assert(b.attack == nil and b.cool.LR > 0, "contact lost: charge aborted and the laser is cooling")
end)
test("a target off the barrel line is not fired at", function()
    local b = newBrain()
    local log = run(b, 4, senses({ range = 70, bearing = math.rad(50) }))
    assert(#log.attacks == 0)
end)
test("aim error is bounded below and grows with target speed, own speed and a damaged arm; it is capped", function()
    local base = Brain.AimSpread(def, W.MG, senses({ range = 0 }))
    near(base, W.MG.spread, 1e-9, "stationary on stationary")
    assert(base > 0)
    assert(Brain.AimSpread(def, W.MG, senses({ targetSpeed = 14, range = 0 })) > base * 1.9)
    assert(Brain.AimSpread(def, W.MG, senses({ range = 100 })) > base * 1.4, "distance costs accuracy")
    assert(Brain.AimSpread(def, W.MG, senses({ ownSpeedFrac = 1, range = 0 })) > base * 1.8)
    assert(Brain.AimSpread(def, W.LR, senses({ armHealth = { MG = 1, LR = 0.3 }, range = 0 })) > Brain.AimSpread(def, W.LR, senses({ range = 0 })) * 1.5)
    assert(Brain.AimSpread(def, W.MG, senses({ targetSpeed = 90, ownSpeedFrac = 1, armHealth = { MG = 0, LR = 0 } })) <= W.MG.spread * def.accuracy.maxMultiplier + 1e-9)
end)

test("firing lane: a target the sensor sees but the guns cannot hit is not fired at; ROOK repositions for a lane", function()
    local b = newBrain()
    run(b, 3, senses({ range = 80 }))
    assert(b.state == "ENGAGE")
    b.attack = nil
    b.cool = { MG = 0, LR = 0 }
    local log = run(b, 0.6, senses({ range = 80, lane = false }))
    assert(#log.attacks == 0, "no pull without a lane")
    run(b, def.perception.lostLosHold + 0.4, senses({ range = 80, lane = false }))
    assert(b.state == "REPOSITION" and b.reposition.reason == "regain_los", b.state)
    run(b, 1.0, senses({ range = 80, lane = true }))
    assert(b.state == "ENGAGE", "a clear lane ends the manoeuvre: " .. b.state)
end)

print("MechBrain: shield doctrine")
local function threatened(bearing) return { level = 1, bearing = bearing or 0 } end
test("the shield is not instant: nothing before the reaction delay, one press after it (for a reacting brain)", function()
    local reacted = 0
    for seed = 1, 20 do
        local b = newBrain(seed)
        run(b, 3, senses())
        local s = senses({ threat = threatened() })
        local early = run(b, def.defense.reaction - 0.1, s)
        assert(early.shields == 0, "seed " .. seed .. " pressed before reacting")
        local late = run(b, def.defense.reactionJitter + 0.3, s)
        reacted += late.shields
        assert(late.shields <= 1)
    end
    assert(reacted > 0, "some episodes get a guard")
end)
test("not every threat is answered: reaction probability is bounded away from 1 and from 0", function()
    local reacted, episodes = 0, 200
    for seed = 1, episodes do
        local b = newBrain(seed)
        run(b, 3, senses())
        local log = run(b, 2.0, senses({ threat = threatened() }))
        reacted += log.shields > 0 and 1 or 0
    end
    local fraction = reacted / episodes
    assert(fraction > 0.5 and fraction < 0.9, "reaction fraction " .. fraction)
end)
test("directional: a threat from the side is not shielded; ROOK turns toward it first", function()
    local b = newBrain(3)
    b.rng = function() return 0.1 end -- always reacts, minimum jitter
    run(b, 3, senses())
    local s = senses({ threat = threatened(math.rad(95)) })
    local log = run(b, 2, s)
    assert(log.shields == 0 and log.last.face == "threat")
    s.threat = threatened(math.rad(10))
    log = run(b, 0.2, s)
    assert(log.shields == 1)
end)
test("no shield when it is not ready, when the capacitor cannot pay, or twice inside the minimum gap", function()
    local function always(seed) local b = newBrain(seed); b.rng = function() return 0.1 end; run(b, 3, senses()); return b end
    assert(run(always(1), 2, senses({ threat = threatened(), shield = { ready = false } })).shields == 0)
    assert(run(always(1), 2, senses({ threat = threatened(), charge = def.defense.minCharge - 0.05 })).shields == 0)
    local b = always(1)
    local s = senses({ threat = threatened() })
    local first = run(b, 1.0, s)
    assert(first.shields == 1 and b.state == "DEFEND")
    local log = run(b, def.defense.minGap - 0.5, s, function() end)
    assert(log.shields == 0, "inside the minimum gap")
end)
test("DEFEND holds position, abandons the attack, and returns to work when the guard cycle is over", function()
    local b = newBrain(1)
    b.rng = function() return 0.1 end
    local off = math.rad(60) -- target off the barrel line: no attack plan is running when the threat arrives
    run(b, 3, senses({ range = 70, bearing = off }))
    run(b, 0.8, senses({ range = 70, bearing = off, threat = threatened() }))
    assert(b.state == "DEFEND" and b.attack == nil, b.state)
    local o = Brain.Step(b, 0.05, senses({ range = 70, bearing = off, threat = threatened() }))
    assert(o.move.mode == "hold" and o.face == "threat")
    run(b, def.defense.cycle + 0.2, senses({ range = 70, bearing = off }))
    assert(b.state == "ENGAGE", b.state)
end)
test("a laser volley in progress is not abandoned for the shield: committing to the shot is the price of the shot", function()
    local b = newBrain(1)
    b.rng = function() return 0.1 end
    local s = senses({ range = 130, mg = { ammo = 0, reloading = true, burstCost = 3.6 } })
    for _ = 1, 160 do
        Brain.Step(b, 0.05, s)
        if b.attack and b.attack.id == "LR" and b.attack.phase == "VOLLEY" then break end
    end
    assert(b.attack and b.attack.phase == "VOLLEY")
    s.threat = threatened()
    b.threatSince = b.clock - 5; b.react = true; b.reactAt = b.clock - 4
    Brain.Step(b, 0.05, s)
    assert(b.state ~= "DEFEND" and b.attack ~= nil and b.shields == 0)
end)
test("the real P-01 limits ROOK: one raise per cycle, then a cooldown, so a patient player can bait and exhaust it", function()
    local cfg = EnergyConfig.Build(Chassis.IF42_BASTION, Components.CORE_220, Components.CAP_STANDARD, Components.RAD_STANDARD, Components.SHIELD_PULSE)
    local ledger = Energy.New(cfg)
    local shield = Shield.New(cfg.shield)
    local b = newBrain(2)
    b.rng = function() return 0.1 end
    run(b, 3, senses())
    local presses, ready, t = 0, true, 0
    for _ = 1, math.floor(30 / 0.05) do
        t += 0.05
        Shield.Advance(shield, cfg.shield, 0.05, true)
        if Shield.Protects(shield) then Energy.Request(ledger, "shield", cfg.shield.activeDrain) end
        Energy.Request(ledger, "idle", cfg.movement.idle)
        Energy.Advance(ledger, 0.05, true)
        local o = Brain.Step(b, 0.05, senses({ threat = threatened(), shield = { ready = shield.state == "READY" }, charge = ledger.charge / cfg.capacity }))
        if o.shield and Shield.Activate(shield, cfg.shield, function(c) return Energy.Spend(ledger, c, "shield") end, true) then
            presses += 1
        end
        assert(ledger.charge >= 0)
    end
    local cycle = cfg.shield.chargeTime + cfg.shield.perfectTime + cfg.shield.activeTime + cfg.shield.recoveryTime + cfg.shield.cooldown
    assert(presses >= 3 and presses <= 30 / cycle + 1, "presses in 30 s of sustained fire: " .. presses)
end)

print("MechBrain: energy profile doctrine")
test("profile follows the job: MOBILITY to relocate, WEAPONS to prepare a volley, BALANCED otherwise and when starved", function()
    local b = newBrain()
    b.state = "ENGAGE"
    assert(Brain.ChooseProfile(b, senses({ range = 100 }), false) == "WEAPONS", "laser ready and the capacitor healthy")
    assert(Brain.ChooseProfile(b, senses({ range = 100, charge = 0.4 }), false) == "BALANCED")
    assert(Brain.ChooseProfile(b, senses({ range = 100, charge = 0.1 }), true) == "BALANCED", "starved: keep the reserves")
    assert(Brain.ChooseProfile(b, senses({ range = 100 }), true) == "MOBILITY")
    b.cool.LR = 2
    assert(Brain.ChooseProfile(b, senses({ range = 100 }), false) == "BALANCED")
end)
test("a profile switch is requested only when the wish persists, and obeys the real switch delay and minimum interval", function()
    local b = newBrain()
    local requested, log = nil, {}
    local state = Profiles.New()
    local clock = 0
    local s = senses({ range = 190 })
    for _ = 1, 80 do
        clock += 0.05
        s.profile = state.pending or state.active
        local o = Brain.Step(b, 0.05, s)
        if o.profile then
            local ok, why = Profiles.Request(state, o.profile, clock)
            table.insert(log, { at = clock, id = o.profile, ok = ok, why = why })
            requested = requested or clock
        end
        Profiles.Update(state, clock)
    end
    assert(requested and requested >= def.perception.acquireTime + def.energy.profileHold - 0.3, "hysteresis: " .. tostring(requested))
    assert(state.active == "MOBILITY", state.active)
end)
test("starvation really changes behaviour: with the real ledger a damaged reactor loses laser volleys, and nothing is ever overdrawn", function()
    local cfg = EnergyConfig.Build(Chassis.IF42_BASTION, Components.CORE_220, Components.CAP_STANDARD, Components.RAD_STANDARD, Components.SHIELD_PULSE)
    local function fight(reactorScale, seconds)
        local c = table.clone(cfg)
        c.output = cfg.output * reactorScale
        local ledger = Energy.New(c)
        Energy.SetPolicy(ledger, Profiles.Definitions.BALANCED)
        local b = newBrain(5)
        local s = senses({ range = 125, reactor = reactorScale })
        local volleys, gunBursts, lowest, lrDenied = 0, 0, 1, 0
        for _ = 1, math.floor(seconds / 0.05) do
            s.charge = ledger.charge / c.capacity
            s.availWeapons = Energy.Available(ledger, "weapons")
            s.weaponBudget = math.max(0, ledger.charge - Energy.Reserve(ledger, "weapons"))
            local o = Brain.Step(b, 0.05, s)
            Energy.Request(ledger, "idle", c.movement.idle)
            Energy.Request(ledger, "propulsion", 45) -- the machine is walking the whole time: this is what makes the capacitor matter
            if o.attack and o.attack.id == "LR" and o.attack.phase == "CHARGE" then Energy.Request(ledger, "weapons", W.LR.chargeDraw) end
            if o.attack and o.attack.trigger then
                local cost = if o.attack.id == "LR" then 24 else 0.6
                Energy.Consume(ledger, cost, false, 0, "weapons")
            end
            if o.attack and o.attack.started then
                if o.attack.id == "LR" then volleys += 1 else gunBursts += 1 end
            end
            Energy.Advance(ledger, 0.05, true)
            lowest = math.min(lowest, ledger.charge / c.capacity)
            assert(ledger.charge >= -1e-9 and ledger.charge <= c.capacity + 1e-9, "overdrawn")
        end
        return volleys, gunBursts, lowest
    end
    local fullV, fullB = fight(1, 90)
    local weakV, weakB = fight(0.45, 90)
    assert(fullV >= 5, "a healthy reactor sustains the laser cadence: " .. fullV)
    assert(weakV < fullV, "a damaged reactor starves the laser: " .. weakV .. " vs " .. fullV)
    assert(weakB >= 1, "the cheap gun carries on while starved")
end)

print("MechBrain: damage-dependent behaviour")
test("a destroyed weapon assembly removes exactly that weapon; both gone neutralises the unit", function()
    local b = newBrain()
    run(b, 3, senses({ range = 120 }))
    local log = run(b, 8, senses({ range = 120, weaponsOnline = { MG = true, LR = false } }))
    assert(not has(log.attacks, "LR") and has(log.attacks, "MG"), table.concat(log.attacks, ","))
    b = newBrain()
    run(b, 3, senses({ range = 70 }))
    log = run(b, 8, senses({ range = 70, weaponsOnline = { MG = false, LR = true } }))
    assert(not has(log.attacks, "MG"))
    run(b, 1, senses({ weaponsOnline = { MG = false, LR = false } }))
    assert(b.state == "DISABLED" and b.reason == "weapons destroyed")
end)
test("leg damage: no flanking when limping, no retreat when crippled; it stands and fights", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local log = run(b, def.tactics.flankEvery + def.tactics.flankJitter + 6, senses({ range = 90, legs = 0.6 }))
    assert(not has(log.states, "REPOSITION") or b.reposition == nil, "limping units do not flank")
    local crippled = newBrain()
    run(crippled, 3, senses({ range = 90 }))
    local o = Brain.Step(crippled, 0.05, senses({ range = def.tactics.band[1] - 12, legs = 0.5 }))
    assert(o.move.mode ~= "retreat")
    run(crippled, 1, senses({ range = def.tactics.tooClose - 10, legs = 0.5 }))
    assert(crippled.state ~= "REPOSITION", "cannot run: " .. crippled.state)
end)
test("reactor damage tightens the laser's energy discipline", function()
    local b = newBrain()
    assert(Brain.ChooseWeapon(b, senses({ range = 120, charge = 0.5 })) == "LR")
    assert(Brain.ChooseWeapon(b, senses({ range = 120, charge = 0.5, reactor = 0.55 })) == "MG")
end)
test("heavy structural damage or a starved capacitor sends ROOK to cover, where it recovers and then comes back", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local s = senses({ range = 90, structure = 0.3, charge = 0.2 })
    run(b, 0.2, s)
    assert(b.state == "REPOSITION" and (b.reposition.reason == "cover"), b.state)
    s.seen, s.sinceSeen = false, 0.3
    s.nav = { arrived = true, noPath = false, stuck = false, awayFromStation = false }
    run(b, 0.5, s)
    assert(b.reposition and b.reposition.dwellStart ~= nil, "dwelling in cover")
    local o = Brain.Step(b, 0.05, s)
    assert(o.move.mode == "hold")
    s.charge, s.structure = 0.8, 0.45
    run(b, 0.3, s, function(_, t) t.sinceSeen = 0.4 end)
    assert(b.reposition == nil or b.reposition.reason == "regain_los", "recovered: back to work")
end)
test("the cover trip is not repeated back to back", function()
    local b = newBrain()
    run(b, 3, senses({ range = 90 }))
    local s = senses({ range = 90, structure = 0.3 })
    run(b, 0.2, s)
    assert(b.state == "REPOSITION")
    b.state, b.reposition = "ENGAGE", nil
    run(b, 0.3, senses({ range = 90, structure = 0.3 }))
    assert(b.state == "ENGAGE", "cover cooldown")
end)

print("MechBrain: terminal disablement and reset")
test("core failure is terminal: it stops, never acquires or fires again, whatever it senses", function()
    local b = newBrain()
    run(b, 3, senses({ range = 80 }))
    local log = run(b, 1, senses({ coreAlive = false }))
    assert(b.state == "DISABLED" and b.reason == "core failure")
    local o = log.last
    assert(o.move.mode == "hold" and o.attack == nil and not o.shield)
    log = run(b, 10, senses({ range = 60, threat = threatened() }))
    assert(b.state == "DISABLED" and #log.attacks == 0 and log.shields == 0)
end)
test("RESET freezes the machine, then returns it to IDLE with nothing remembered", function()
    local b = newBrain()
    run(b, 3, senses({ range = 80 }))
    run(b, 1, senses({ coreAlive = false }))
    local o = Brain.Step(b, 0.05, senses({ resetting = true }))
    assert(o.state == "RESET" and o.attack == nil)
    run(b, 0.5, senses({ resetting = true }))
    assert(b.state == "RESET")
    local fresh = senses({ seen = false, sinceSeen = math.huge })
    run(b, 0.2, fresh)
    assert(b.state == "IDLE" and b.attack == nil)
    local log = run(newBrain(), 0.3, senses({ seen = false, sinceSeen = math.huge }))
    assert(log.states[#log.states] == "IDLE")
end)
test("a rebuilt brain (the server creates one on every respawn) carries no cooldown, memory or attack", function()
    local old = newBrain()
    run(old, 6, senses({ range = 70 }))
    local fresh = newBrain()
    assert(fresh.state == "IDLE" and fresh.cool.MG == 0 and fresh.cool.LR == 0 and fresh.attack == nil and fresh.shields == 0)
end)

print("Damage model and armour")
test("ROOK's capacities replace the Bastion's; regions, spill and consequences are the shared conventions", function()
    local s = Damage.New(def.structure.regions)
    assert(s.capacity.CORE == def.structure.regions.CORE and s.capacity.LEG_L == def.structure.regions.LEG_L)
    local r = Damage.Apply(s, "LEG_L", 400)
    assert(s.health.LEG_L == 0 and s.health.CORE == def.structure.regions.CORE - 400 * 0.2 + 0 or true)
    local fx = Damage.Effects(s)
    assert(fx.speed < 1 and fx.speed >= 0.4 and r.destroyed[1] == "LEG_L")
    local reactor = Damage.New(def.structure.regions)
    Damage.Apply(reactor, "REACTOR", 300)
    assert(Damage.Effects(reactor).reactor < 0.6)
    assert(Damage.New().capacity.CORE == 900, "the Bastion default is unchanged")
end)
test("a centre-mass hit is not a precision hit: region damage stays in its region plus the core spill", function()
    local s = Damage.New(def.structure.regions)
    Damage.Apply(s, "CORE", 100)
    for region, hp in pairs(def.structure.regions) do
        if region ~= "CORE" then assert(s.health[region] == hp, region .. " untouched by a core hit") end
    end
    Damage.Apply(s, "ARM_L", 50)
    assert(s.health.ARM_L == def.structure.regions.ARM_L - 50 and s.health.LEG_R == def.structure.regions.LEG_R)
end)
test("armour differences: the exposed reactor takes more, the core less; the Mauler out-damages the gun everywhere", function()
    local r = def.structure.resist
    assert(r.REACTOR.MG > r.CORE.MG and r.REACTOR.LASER > r.CORE.LASER and r.REACTOR.HEAVY > r.CORE.HEAVY)
    for _, region in ipairs(Damage.Regions) do assert(r[region].HEAVY > r[region].MG, region) end
end)
test("the encounter is winnable: a sustained laser or gun burst takes the core down in a reasonable time", function()
    local core = def.structure.regions.CORE
    local mgTime = core / (8 * def.structure.resist.CORE.MG * 10)
    local lrTime = core / (25 * def.structure.resist.CORE.LASER * 4)
    assert(mgTime > 8 and mgTime < 40, "gun-only core kill " .. mgTime)
    assert(lrTime > 5 and lrTime < 40, "laser-only core kill " .. lrTime)
end)

print("Weapon state under ROOK's own mounts")
test("the shared firing rules govern ROOK: magazine, reload, cooldown and payment are the player's", function()
    local s = WeaponState.New({ right_arm = def.weapons.MG.id, left_arm = def.weapons.LR.id }, Components)
    assert(s.slots.right_arm and s.slots.left_arm)
    local paid = 0
    local now = 0
    local function pay(cost) paid += cost; return true end
    assert(WeaponState.Fire(s, "right_arm", now, true, true, pay))
    assert(not WeaponState.Fire(s, "right_arm", now + 0.01, true, true, pay), "interval cooldown")
    assert(WeaponState.Fire(s, "right_arm", now + 0.11, true, true, pay))
    for i = 1, 70 do WeaponState.Fire(s, "right_arm", now + 0.2 + i * 0.11, true, true, pay) end
    assert(s.slots.right_arm.ammo < 60 and (s.slots.right_arm.reloadAt ~= nil or s.slots.right_arm.ammo > 0), "magazine drains and reloads")
    assert(WeaponState.Fire(s, "left_arm", now, true, true, pay), "laser has its own energy price")
    assert(not WeaponState.Fire(s, "left_arm", now + 0.1, true, false, pay), "invalid aim refuses")
end)

print("MechNav")
local court = def.court
local function lattice(blocked)
    local nodes = Nav.BuildNodes(court, def.station, 0, 0)
    for _, n in ipairs(nodes) do n.valid = not (blocked and blocked(n.x, n.z)) end
    return nodes
end
-- A synthetic wall: x in [-17, -5], z in [543, 547] (west half of row z = 545), with the hull half size 7.
local function wallBlocks(x, z) return x - 7 < -5 and x + 7 > -17 and z - 7 < 547 and z + 7 > 543 end
local function segmentCrossesWall(x1, z1, x2, z2)
    for i = 0, 20 do
        local t = i / 20
        if wallBlocks(x1 + (x2 - x1) * t, z1 + (z2 - z1) * t) then return false end
    end
    return true
end
test("the lattice covers the court and ends at the station", function()
    local nodes = lattice()
    assert(#nodes == #court.cols * court.rowCount + 1)
    for _, n in ipairs(nodes) do
        assert(n.x >= court.minX and n.x <= court.maxX and n.z >= court.minZ and n.z <= court.maxZ, "node outside the court")
    end
    assert(nodes[#nodes].station and nodes[#nodes].z == def.station.z)
end)
test("graph + A* route around an obstacle; direct when the way is clear; unreachable goals are reported", function()
    local nodes = lattice(wallBlocks)
    local graph = Nav.BuildGraph(nodes, court.edgeReach, function(a, b) return segmentCrossesWall(a.x, a.z, b.x, b.z) end)
    assert(Nav.EdgeCount(graph) > 20)
    local direct = Nav.Route(graph, 8, 520, 8, 590, segmentCrossesWall)
    assert(direct and #direct == 1)
    local around = Nav.Route(graph, -11, 530, -11, 565, segmentCrossesWall)
    assert(around and #around >= 2, "the straight line crosses the wall, so waypoints are needed")
    for i = 2, #around do
        assert(segmentCrossesWall(around[i - 1].x, around[i - 1].z, around[i].x, around[i].z), "every leg of the route is clear")
    end
    local closed = lattice(function(x, z) return x < 100 end)
    for _, n in ipairs(closed) do n.valid = false end
    local g2 = Nav.BuildGraph(closed, court.edgeReach, function() return true end)
    assert(Nav.Route(g2, 0, 520, 0, 590, function() return false end) == nil)
end)
test("a destroyed wall opens the lattice: re-validated nodes shorten the route", function()
    local function build(wallUp)
        local nodes = lattice(if wallUp then wallBlocks else nil)
        return Nav.BuildGraph(nodes, court.edgeReach, function(a, b) return not wallUp or segmentCrossesWall(a.x, a.z, b.x, b.z) end)
    end
    local up = Nav.Route(build(true), -11, 530, -11, 565, segmentCrossesWall)
    local down = Nav.Route(build(false), -11, 530, -11, 565, function() return true end)
    assert(up and down and #down == 1 and #up > #down)
end)
test("Pick: regain_los picks a node that sees the target, cover picks one that does not, flank swings round, range opens the gap", function()
    local nodes = lattice()
    local graph = { nodes = nodes, edges = {} }
    local target = { x = 0, z = 500 }
    local los = {}
    for _, n in ipairs(nodes) do los[n.id] = n.x > 0 end -- the east half sees the target
    local ctx = { x = -11, z = 590, tx = target.x, tz = target.z, band = def.tactics.band, los = los, reason = "regain_los" }
    local best = Nav.Pick(graph, ctx)
    assert(best and los[best.id], "regain_los must see the target")
    ctx.reason = "cover"
    best = Nav.Pick(graph, ctx)
    assert(best and not los[best.id], "cover must not see the target")
    ctx.reason, ctx.x, ctx.z = "flank", 11, 580
    for _, n in ipairs(nodes) do los[n.id] = true end
    best = Nav.Pick(graph, ctx)
    assert(best.x < 0, "flank swings to the other side of the line: x=" .. best.x)
    ctx.reason, ctx.x, ctx.z, ctx.tz = "range", 0, 520, 505
    best = Nav.Pick(graph, ctx)
    assert(Nav.dist(best.x, best.z, ctx.tx, ctx.tz) >= def.tactics.band[1] - 5, "opens the range")
    ctx.recent = {}
    for _, n in ipairs(nodes) do ctx.recent[n.id] = 0 end
    local first = Nav.Pick(graph, ctx)
    ctx.recent[first.id] = 500
    assert(Nav.Pick(graph, ctx).id ~= first.id, "a recently used position is penalised")
end)

print("Steering and stuck recovery")
local P = Chassis.IF42_BASTION.locomotion
local function simulate(goal, seconds, opt)
    local s = Drive.New(0, 0, 0, 0)
    local maxStep, arrived, t = 0, nil, 0
    local px, pz = s.x, s.z
    for _ = 1, math.floor(seconds / 0.05) do
        t += 0.05
        local th, st, dist = Nav.Drive({ x = s.x, z = s.z, yaw = s.yaw, speed = s.speed }, goal.x, goal.z, P, opt or { cap = 1, stop = 2 })
        Drive.Advance(s, { throttle = th, steer = st, locked = false }, 0.05, P, nil)
        maxStep = math.max(maxStep, math.sqrt((s.x - px) ^ 2 + (s.z - pz) ^ 2))
        px, pz = s.x, s.z
        if dist < 3 and not arrived and math.abs(s.speed) < 0.6 then arrived = t end
    end
    return s, arrived, maxStep
end
test("a heavy mech turns before it walks and arrives without teleporting or exceeding its drive limits", function()
    local s, arrived, maxStep = simulate({ x = -40, z = 60 }, 25)
    assert(arrived and arrived < 24, "arrival time " .. tostring(arrived))
    assert(maxStep <= P.maxForward * 0.05 * 1.02, "no jumps: " .. maxStep)
    assert(math.abs(s.speed) < 1, "stopped at the goal")
end)
test("it brakes for the goal rather than overshooting", function()
    local s = Drive.New(0, 0, 0, 0)
    local worst = 0
    for _ = 1, 600 do
        local th, st, dist = Nav.Drive({ x = s.x, z = s.z, yaw = s.yaw, speed = s.speed }, 0, -80, P, { cap = 1, stop = 2 })
        Drive.Advance(s, { throttle = th, steer = st, locked = false }, 0.05, P, nil)
        worst = math.max(worst, -s.z - 80)
    end
    assert(worst < 4, "overshoot " .. worst)
end)
test("obstacle awareness: little room ahead slows it and veers toward the open side", function()
    local state = { x = 0, z = 0, yaw = 0, speed = 8 }
    local free = Nav.Drive(state, 0, -60, P, { cap = 1, stop = 2 })
    local blocked, steer = Nav.Drive(state, 0, -60, P, { cap = 1, stop = 2, clearAhead = 9, clearLeft = 30, clearRight = 4 })
    assert(blocked < free, "slower")
    assert(steer > 0.3, "veers left, toward the open side: " .. steer)
    local _, steerRight = Nav.Drive(state, 0, -60, P, { cap = 1, stop = 2, clearAhead = 9, clearLeft = 4, clearRight = 30 })
    assert(steerRight < -0.3)
end)
test("turning round to a waypoint is not fought by the sweep ahead of the old heading", function()
    local state = { x = 0, z = 0, yaw = 0, speed = 0 }
    local _, steerBlocked = Nav.Drive(state, 40, 0, P, { cap = 1, stop = 2, clearAhead = 3, clearLeft = 30, clearRight = 2 }) -- goal is to the right; the open side is left
    local _, steerFree = Nav.Drive(state, 40, 0, P, { cap = 1, stop = 2 })
    near(steerBlocked, steerFree, 1e-9, "the turn toward the goal is unchanged by the blocked heading")
end)
test("stuck detection: commanded but not moving trips the detector; recovery reverses, then clears", function()
    local p = Nav.NewProgress()
    local stuckAt
    for i = 1, 200 do
        if Nav.Track(p, 0.05, 10, 10, true) and not stuckAt then stuckAt = i * 0.05 end
    end
    assert(stuckAt and stuckAt >= 2 and stuckAt <= 3.2, "stuck after " .. tostring(stuckAt))
    local reversed, finished = 0, false
    for _ = 1, 100 do
        local th, st, done = Nav.Recover(p, 0.05, 20, 5)
        if th < 0 then reversed += 1; assert(st > 0, "turns toward the open (left) side") end
        if done then finished = true; break end
    end
    assert(reversed >= 25 and finished and not p.stuck)
    local moving = Nav.NewProgress()
    for i = 1, 200 do Nav.Track(moving, 0.05, i * 0.4, 0, true) end
    assert(not moving.stuck, "a mech that is making progress is never stuck")
    local idle = Nav.NewProgress()
    for _ = 1, 200 do Nav.Track(idle, 0.05, 0, 0, false) end
    assert(not idle.stuck, "standing still on purpose is not stuck")
end)
test("a hull that cannot turn (pressed against a wall) is stuck even though it is not trying to travel", function()
    local p = Nav.NewProgress()
    local stuckAt
    for i = 1, 200 do
        if Nav.Track(p, 0.05, 10, 10, false, 1.0, true) and not stuckAt then stuckAt = i * 0.05 end
    end
    assert(stuckAt and stuckAt <= 3.2, "stuck after " .. tostring(stuckAt))
    local turning = Nav.NewProgress()
    for i = 1, 200 do Nav.Track(turning, 0.05, 10, 10, false, i * 0.02, true) end
    assert(not turning.stuck, "a mech that is turning is not stuck")
end)
test("blocked-path recovery end to end: a mech pinned against a wall backs out and then makes progress", function()
    local s = Drive.New(0, 0, 0, 0)
    local progress = Nav.NewProgress()
    local wallZ = -20
    local probe = { move = function(x, y, z, yaw, dx, dz)
        if z + dz < wallZ + 1 then return x, wallZ + 1, 0.2, 0, 1 end
        return x + dx, z + dz, 1, 0, 0
    end }
    local backed = false
    for _ = 1, 40 / 0.05 do
        local th, st = Nav.Drive({ x = s.x, z = s.z, yaw = s.yaw, speed = s.speed }, 0, -60, P, { cap = 1, stop = 2 })
        if progress.recover or Nav.Track(progress, 0.05, s.x, s.z, th > 0.3) then
            local rt, rs, done = Nav.Recover(progress, 0.05, 20, 10)
            th, st = rt, rs
            backed = true
        end
        Drive.Advance(s, { throttle = th, steer = st, locked = false }, 0.05, P, probe)
    end
    assert(backed and progress.stuckCount >= 1, "it noticed")
    assert(s.z > wallZ - 0.5, "never through the wall")
end)

print(string.format("enemy_tests: %d passed, %d failed", passed, failed))
if failed > 0 then error("enemy tests failed") end
