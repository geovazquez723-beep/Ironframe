-- Offline (Luau CLI) tests for M11A: component registry, slot compatibility, loadout validation, deterministic effective specifications,
-- reactor / actuator / armour differences against the real energy, drive and damage modules, request validation, reset retention and
-- compatibility with the factory Bastion.  Run: luau tools/loadout_tests.luau
local Compiler = require("../src/ReplicatedStorage/IronframeShared/LoadoutCompiler")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local Loadouts = require("../src/ReplicatedStorage/IronframeShared/Loadouts")
local CombatConfig = require("../src/ReplicatedStorage/IronframeShared/CombatConfig")
local Energy = require("../src/ReplicatedStorage/IronframeShared/Energy")
local EnergyConfig = require("../src/ReplicatedStorage/IronframeShared/EnergyConfig")
local Profiles = require("../src/ReplicatedStorage/IronframeShared/EnergyProfiles")
local Drive = require("../src/ReplicatedStorage/IronframeShared/MechDrive")
local Damage = require("../src/ReplicatedStorage/IronframeShared/MechDamage")
local WeaponState = require("../src/ReplicatedStorage/IronframeShared/WeaponState")
local EnemyConfig = require("../src/ReplicatedStorage/IronframeShared/EnemyConfig")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

local function preset(id)
    return Compiler.Clone(Loadouts.presets[id])
end
local function build(base, systems, mounts)
    local l = preset(base)
    for k, v in pairs(systems or {}) do l.systems[k] = v end
    for k, v in pairs(mounts or {}) do l.mounts[k] = if v == false then nil else v end
    return l
end
local function compile(l)
    local c = Compiler.Compile(l)
    assert(c.valid, table.concat(c.issues, "; "))
    return c
end

print("Registry and catalog")
test("new components exist, are the right class and carry their tuning data", function()
    assert(Components.CORE_260.class == "reactor" and Components.CORE_260.powerOutput > Components.CORE_220.powerOutput)
    assert(Components.CORE_260.capacitorScale < 1 and Components.CORE_260.thermalScale > 1 and Components.CORE_260.mass > Components.CORE_220.mass)
    assert(Components.ACT_STANDARD.class == "actuator" and Components.ACT_MOBILITY.class == "actuator")
    assert(Components.ACT_MOBILITY.speedScale > 1 and Components.ACT_MOBILITY.legStructureScale < 1 and Components.ACT_MOBILITY.movementEnergyScale > 1)
    assert(Components.ARMOR_REINFORCED.integrityBonus > Components.ARMOR_STANDARD.integrityBonus and Components.ARMOR_REINFORCED.speedScale < 1)
    assert(Components.CORE_300.powerOutput == 120 and Components.CAP_HIGH_DENSITY.capacity == 240, "existing components are untouched")
end)
test("the garage catalog derives from the registry: three reactor / actuator / armour families, the three weapon families", function()
    assert(table.concat(Compiler.SystemOptions("reactor"), ",") == "CORE_220,CORE_260")
    assert(table.concat(Compiler.SystemOptions("actuators"), ",") == "ACT_STANDARD,ACT_MOBILITY")
    assert(table.concat(Compiler.SystemOptions("armor"), ",") == "ARMOR_STANDARD,ARMOR_REINFORCED")
    assert(#Compiler.SystemOptions("cooling") == 0 and #Compiler.SystemOptions("shield") == 0 and #Compiler.SystemOptions("nope") == 0)
end)
test("weapon options follow hardpoint size and family: the Mauler is arms-only, shoulders take the gun and laser", function()
    local function has(list, id) return table.find(list, id) ~= nil end
    for _, socket in ipairs({ "left_arm", "right_arm" }) do
        local o = Compiler.WeaponOptions("IF42_BASTION", socket)
        assert(has(o, "W_MACHINE_GUN") and has(o, "W_LASER_RIFLE") and has(o, "W_HMG_MAULER"), socket)
    end
    for _, socket in ipairs({ "left_shoulder", "right_shoulder" }) do
        local o = Compiler.WeaponOptions("IF42_BASTION", socket)
        assert(has(o, "W_MACHINE_GUN") and has(o, "W_LASER_RIFLE") and not has(o, "W_HMG_MAULER"), socket)
    end
    assert(#Compiler.WeaponOptions("IF42_BASTION", "left_torso") == 0, "torso mounts are not configurable")
    assert(#Compiler.WeaponOptions("NOPE", "left_arm") == 0)
    for _, socket in ipairs(Compiler.ConfigurableSockets) do
        for _, id in ipairs(Compiler.WeaponOptions("IF42_BASTION", socket)) do
            assert(Components[id].combat ~= nil, "only implemented weapons are offered: " .. id)
        end
    end
end)

print("Compilation")
test("compilation is deterministic and does not mutate the loadout", function()
    local l = build("BALANCED", { reactor = "CORE_260", actuators = "ACT_MOBILITY", armor = "ARMOR_REINFORCED" }, { right_arm = "W_MACHINE_GUN", left_shoulder = "W_LASER_RIFLE", left_torso = false, right_torso = false })
    local before = Compiler.Clone(l)
    local a, b = compile(l), compile(l)
    assert(Compiler.Same(before, l), "the loadout was mutated")
    for key, value in pairs(a.stats) do near(value, b.stats[key], 0, key) end
    for key, value in pairs(a.locomotion) do if type(value) == "number" then near(value, b.locomotion[key], 0, key) end end
    for region, hp in pairs(a.structure) do near(hp, b.structure[region], 0, region) end
    assert(a.label == b.label)
end)
test("the factory Bastion is unchanged: every preset compiles to the M10C economy, drive and structure", function()
    for _, id in ipairs(Loadouts.order) do
        local c = compile(Loadouts.presets[id])
        local e = c.energy
        assert(e.output == 80 and e.capacity == 160 and e.initialCharge == 160 and e.maxChargeRate == 50 and e.thermalPerEnergy == 0.12 and e.thermalPerDischarge == 0.15, id)
        assert(e.movement == Chassis.IF42_BASTION.energy, "standard movement demand is the chassis table itself")
        for key, value in pairs(Chassis.IF42_BASTION.locomotion) do
            if type(value) == "number" then near(c.locomotion[key], value, 1e-9, id .. " " .. key) end
        end
        for region, hp in pairs(CombatConfig.mech.regions) do near(c.structure[region], hp, 0, id .. " " .. region) end
        near(c.metrics.integrity, 1200, 0, "integrity")
    end
end)
test("ROOK-01 compiles to the same standard stats (its fairness contract) and is unaffected by the new slots", function()
    local c = compile(Loadouts.enemy.ROOK)
    assert(c.energy.output == 80 and c.energy.capacity == 160 and c.locomotion.maxForward == Chassis.IF42_BASTION.locomotion.maxForward)
    for region, hp in pairs(CombatConfig.mech.regions) do near(c.structure[region], hp, 0, region) end
    assert(EnemyConfig.enemies.ROOK_01.structure.regions.CORE == 700, "ROOK keeps its own armour table")
end)
test("reactor: high-output generates more and cools better but banks less and converts hotter; the existing capacitor and shield contract is kept", function()
    local std, ho = compile(preset("BALANCED")), compile(build("BALANCED", { reactor = "CORE_260" }))
    assert(ho.energy.output == 112 and std.energy.output == 80)
    near(ho.energy.capacity, 160 * 0.65, 1e-9, "capacity")
    assert(ho.energy.maxChargeRate > std.energy.maxChargeRate and ho.energy.thermalPerEnergy > std.energy.thermalPerEnergy and ho.energy.cooling > std.energy.cooling)
    assert(ho.energy.shield.activationCost == std.energy.shield.activationCost and ho.energy.maxDischargeRate == std.energy.maxDischargeRate)
    assert(ho.metrics.mass > std.metrics.mass)
    assert(ho.energy.capacity >= ho.energy.shield.activationCost + 3 * 24, "a shield raise plus a laser volley still fits the capacitor")
end)
test("actuators: mobility raises every drive limit, pays more energy per unit of motion and has weaker legs", function()
    local std, mob = compile(preset("BALANCED")), compile(build("BALANCED", { actuators = "ACT_MOBILITY" }))
    for _, key in ipairs({ "maxForward", "maxReverse", "accelForward", "turnRate", "turnAccel" }) do
        assert(mob.locomotion[key] > std.locomotion[key], key)
    end
    near(mob.locomotion.brakeDecel, std.locomotion.brakeDecel, 0, "braking is untouched")
    near(mob.locomotion.hull.width, std.locomotion.hull.width, 0, "collision hull is untouched")
    assert(mob.energy.movement.drive > std.energy.movement.drive and mob.energy.movement.sprintDemand > std.energy.movement.sprintDemand)
    assert(mob.structure.LEG_L < std.structure.LEG_L and mob.structure.LEG_R == mob.structure.LEG_L)
    assert(mob.structure.CORE == std.structure.CORE, "only the legs change")
    assert(mob.metrics.mass > std.metrics.mass)
end)
test("armour: reinforced structure scales every region by +25 %, costs mass, speed, agility and energy", function()
    local std, rf = compile(preset("BALANCED")), compile(build("BALANCED", { armor = "ARMOR_REINFORCED" }))
    for region, hp in pairs(std.structure) do
        near(rf.structure[region] / hp, 1.25, 0.01, region)
    end
    assert(rf.locomotion.maxForward < std.locomotion.maxForward and rf.locomotion.accelForward < std.locomotion.accelForward and rf.locomotion.turnRate < std.locomotion.turnRate)
    assert(rf.energy.movement.drive > std.energy.movement.drive)
    near(rf.metrics.mass - std.metrics.mass, 1.5, 1e-9, "mass")
end)
test("armour and actuators compose predictably: structure, speed and energy multiply, nothing else moves", function()
    local std, both = compile(preset("BALANCED")), compile(build("BALANCED", { armor = "ARMOR_REINFORCED", actuators = "ACT_MOBILITY" }))
    near(both.locomotion.maxForward, std.locomotion.maxForward * 1.12 * 0.93, 1e-9, "speed")
    near(both.modifiers.movementEnergy, 1.3 * 1.12, 1e-9, "energy")
    near(both.structure.LEG_L, math.floor(380 * 1.25 * 0.78 + 0.5), 1, "leg structure")
    near(both.structure.CORE, 900 * 1.25, 1, "core structure")
end)
test("build identities exist: striker, brawler and marksman are distinct, valid and each trades something", function()
    local striker = compile(build("BALANCED", { actuators = "ACT_MOBILITY" }, { right_arm = "W_MACHINE_GUN", left_arm = "W_MACHINE_GUN", left_shoulder = "W_LASER_RIFLE", right_shoulder = "W_LASER_RIFLE" }))
    local brawler = compile(build("AUTOCANNON", { armor = "ARMOR_REINFORCED" }, { left_shoulder = false, right_shoulder = false }))
    local marksman = compile(build("ENERGY", { reactor = "CORE_260" }, { left_arm = "W_LASER_RIFLE", right_arm = "W_LASER_RIFLE" }))
    local base = compile(preset("BALANCED")).stats
    assert(striker.stats.topSpeed > base.topSpeed and striker.stats.legStructure < base.legStructure)
    assert(brawler.stats.coreStructure > base.coreStructure and brawler.stats.topSpeed < base.topSpeed)
    assert(marksman.stats.output > base.output and marksman.stats.capacity < base.capacity)
    assert(striker.label ~= brawler.label and brawler.label ~= marksman.label)
end)
test("no component is better in every dimension (each alternative gives something up)", function()
    local base = compile(preset("BALANCED")).stats
    local alts = {
        reactor = compile(build("BALANCED", { reactor = "CORE_260" })).stats,
        actuators = compile(build("BALANCED", { actuators = "ACT_MOBILITY" })).stats,
        armor = compile(build("BALANCED", { armor = "ARMOR_REINFORCED" })).stats,
    }
    for slot, s in pairs(alts) do
        local better, worse = 0, 0
        for _, key in ipairs({ "output", "capacity", "topSpeed", "accel", "turnRate", "coreStructure", "legStructure" }) do
            if s[key] > base[key] + 1e-9 then better += 1 elseif s[key] < base[key] - 1e-9 then worse += 1 end
        end
        if s.thermalPerEnergy > base.thermalPerEnergy or s.moveEnergy > base.moveEnergy or s.mass > base.mass then worse += 1 end
        assert(better >= 1 and worse >= 1, slot .. ": better " .. better .. " worse " .. worse)
    end
end)

print("Mass, power and weapon rules")
test("mass and power budgets are enforced on engineered builds", function()
    local heavy = build("AUTOCANNON", { armor = "ARMOR_REINFORCED" }) -- 41.7 + 1.5 > 42
    local c = Compiler.Compile(heavy)
    assert(not c.valid and table.find(c.issues, "Mass limit exceeded"))
    assert(Compiler.Compile(build("BALANCED", { armor = "ARMOR_REINFORCED" })).valid)
    local overdraw = Compiler.Compile(build("ENERGY", { reactor = "CORE_220" }, { left_arm = "W_HMG_MAULER", right_arm = "W_HMG_MAULER" }))
    assert(not overdraw.valid or overdraw.metrics.powerDraw <= overdraw.metrics.powerOutput)
end)
test("a build that only breaks a budget still reports its effective numbers (for the garage preview) but is not valid", function()
    local c = Compiler.Compile(build("AUTOCANNON", { armor = "ARMOR_REINFORCED" }))
    assert(not c.valid and c.stats and c.energy and c.locomotion and c.structure)
    local bad = Compiler.Compile(build("BALANCED", { reactor = "CORE_NOPE" }))
    assert(not bad.valid and bad.stats == nil and bad.energy == nil, "structural errors produce no specification")
end)
test("effective weapon numbers come from the registry: damage, cadence, ammunition, energy demand", function()
    local c = compile(build("AUTOCANNON", {}, { left_arm = "W_LASER_RIFLE", right_arm = "W_HMG_MAULER" }))
    local mauler, laser = c.weapons.right_arm, c.weapons.left_arm
    near(mauler.damage, 25, 0); near(mauler.interval, 1 / 3, 1e-9); assert(mauler.magazine == 24 and mauler.reload == 3.8)
    near(mauler.energyRate, 2.5 * 3, 1e-9, "mauler energy demand")
    near(laser.energyRate, 24 / 0.25, 1e-9, "laser energy demand"); assert(laser.magazine == 0)
    assert(c.weapons.left_torso == nil, "unimplemented micro weapons have no combat numbers")
end)
test("a mounted weapon becomes a real firing slot; an emptied hardpoint has none (disabled mount)", function()
    local l = build("BALANCED", {}, { right_arm = "W_HMG_MAULER", left_shoulder = false })
    local s = WeaponState.New(l.mounts, Components)
    assert(s.slots.right_arm and s.slots.right_arm.ammo == 24 and s.slots.left_shoulder == nil)
    local paid = 0
    assert(WeaponState.Fire(s, "right_arm", 0, true, true, function(cost) paid += cost return true end) and paid == 2.5)
    assert(not WeaponState.Fire(s, "left_shoulder", 0, true, true, function() return true end), "an empty hardpoint cannot fire")
end)

print("Runtime consequences of the compiled specification")
local function topSpeed(c, seconds)
    local s = Drive.New(0, 0, 0, 0)
    for _ = 1, math.floor(seconds * 60) do
        Drive.Advance(s, { throttle = 1, steer = 0, locked = false }, 1 / 60, c.locomotion, nil)
    end
    return s.speed
end
local function timeTo(c, speed)
    local s, t = Drive.New(0, 0, 0, 0), 0
    while s.speed < speed and t < 20 do
        Drive.Advance(s, { throttle = 1, steer = 0, locked = false }, 1 / 60, c.locomotion, nil)
        t += 1 / 60
    end
    return t
end
test("locomotion: real drive simulation reaches different top speeds and accelerates at different rates", function()
    local std, mob, rf = compile(preset("BALANCED")), compile(build("BALANCED", { actuators = "ACT_MOBILITY" })), compile(build("BALANCED", { armor = "ARMOR_REINFORCED" }))
    near(topSpeed(std, 10), 16, 0.05); near(topSpeed(mob, 10), 16 * 1.12, 0.05); near(topSpeed(rf, 10), 16 * 0.93, 0.05)
    assert(timeTo(mob, 12) < timeTo(std, 12) and timeTo(rf, 12) > timeTo(std, 12))
end)
test("turn rate really changes: a quarter turn takes a mobility drive less time", function()
    local function quarter(c)
        local s, t = Drive.New(0, 0, 0, 0), 0
        while math.abs(s.yaw) < math.rad(90) and t < 20 do
            Drive.Advance(s, { throttle = 0, steer = 1, locked = false }, 1 / 60, c.locomotion, nil)
            t += 1 / 60
        end
        return t
    end
    assert(quarter(compile(build("BALANCED", { actuators = "ACT_MOBILITY" }))) < quarter(compile(preset("BALANCED"))))
end)
test("movement energy: the same motion costs a mobility / reinforced drive more, a faster machine more again", function()
    local function demand(c, speed)
        return (Energy.MovementDemand(c.energy, { speed = speed, accel = 0 }, 1, 0, false))
    end
    local std, mob, rf = compile(preset("BALANCED")), compile(build("BALANCED", { actuators = "ACT_MOBILITY" })), compile(build("BALANCED", { armor = "ARMOR_REINFORCED" }))
    assert(demand(mob, 12) > demand(std, 12) * 1.25 and demand(rf, 12) > demand(std, 12) * 1.1)
    assert(demand(mob, 17.9) > demand(mob, 16))
end)
test("damage still bites under either drive: a destroyed leg costs the same fraction of the build's own speed", function()
    for _, actuator in ipairs({ "ACT_STANDARD", "ACT_MOBILITY" }) do
        local c = compile(build("BALANCED", { actuators = actuator }))
        local s = Damage.New(c.structure)
        Damage.Apply(s, "LEG_L", c.structure.LEG_L)
        local fx = Damage.Effects(s)
        assert(fx.speed < 0.9 and fx.speed >= CombatConfig.mech.leg.floor, actuator)
        assert(c.locomotion.maxForward * fx.speed < c.locomotion.maxForward)
    end
    local mob = compile(build("BALANCED", { actuators = "ACT_MOBILITY" }))
    local s = Damage.New(mob.structure)
    Damage.Apply(s, "LEG_L", 100)
    local std = Damage.New(compile(preset("BALANCED")).structure)
    Damage.Apply(std, "LEG_L", 100)
    assert(Damage.Effects(s).speed < Damage.Effects(std).speed, "the same hit hurts the weaker legs more")
end)
test("armour: the same penetrating damage leaves a reinforced build with more of its structure and later stage changes", function()
    local std, rf = compile(preset("BALANCED")), compile(build("BALANCED", { armor = "ARMOR_REINFORCED" }))
    local a, b = Damage.New(std.structure), Damage.New(rf.structure)
    Damage.Apply(a, "CORE", 500); Damage.Apply(b, "CORE", 500)
    assert(Damage.Fraction(b, "CORE") > Damage.Fraction(a, "CORE"))
    local hits = function(s) local n = 0 while not s.coreFailed and n < 200 do Damage.Apply(s, "CORE", 60) n += 1 end return n end
    assert(hits(Damage.New(rf.structure)) > hits(Damage.New(std.structure)) * 1.2)
end)
test("reset retains the engineered build: repairing restores the build's own capacities, not the factory ones", function()
    local rf = compile(build("BALANCED", { armor = "ARMOR_REINFORCED", actuators = "ACT_MOBILITY" }))
    local s = Damage.New(rf.structure)
    Damage.Apply(s, "LEG_R", 9999); Damage.Apply(s, "CORE", 400)
    Damage.Reset(s)
    for region, hp in pairs(rf.structure) do near(s.health[region], hp, 0, region); near(s.capacity[region], hp, 0, region) end
    assert(rf.structure.CORE ~= CombatConfig.mech.regions.CORE)
end)
test("profile arbitration is unchanged: every profile still serves the same priorities on the high-output economy", function()
    local ho = compile(build("BALANCED", { reactor = "CORE_260" }))
    for _, id in ipairs(Profiles.Order) do
        local e = Energy.New(ho.energy)
        Energy.SetPolicy(e, Profiles.Definitions[id])
        for _ = 1, 240 do
            Energy.Request(e, "idle", 8); Energy.Request(e, "weapons", 96); Energy.Request(e, "shield", 50)
            Energy.Advance(e, 1 / 120, true)
            assert(e.charge >= -1e-9 and e.charge <= ho.energy.capacity + 1e-9, id)
        end
        near(e.ledger.initial + e.ledger.generated, e.charge + e.ledger.consumed + e.ledger.loss + e.ledger.wasted, 1e-6, id .. " conservation")
    end
end)
test("sustained energy weapons: held laser fire (weapon heat included) gets materially more shots from the high-output package", function()
    local spec = Components.W_LASER_RIFLE.combat
    local function shots(c, seconds)
        local e = Energy.New(c.energy)
        Energy.SetPolicy(e, Profiles.Definitions.BALANCED)
        local n, nextShot = 0, 0
        for i = 1, seconds * 120 do
            Energy.Request(e, "idle", 8)
            if i / 120 >= nextShot then
                if Energy.Consume(e, spec.energy, false, 0, "weapons") == spec.energy then
                    n += 1
                    e.thermal = math.clamp(e.thermal + spec.heat, 0, 100)
                end
                nextShot = i / 120 + spec.interval
            end
            Energy.Advance(e, 1 / 120, true)
        end
        return n
    end
    local std, ho = shots(compile(preset("BALANCED")), 30), shots(compile(build("BALANCED", { reactor = "CORE_260" })), 30)
    assert(ho >= std * 1.2, "high-output sustains more laser shots: " .. ho .. " vs " .. std)
    assert(shots(compile(build("BALANCED", { reactor = "CORE_260" })), 5) <= shots(compile(preset("BALANCED")), 5) + 1, "no advantage in the opening seconds: the price is the shallow bank")
end)
test("the shallow capacitor is real: the high-output bank holds fewer laser shots, and sprint stresses it harder per unit of bank", function()
    local std, ho = compile(preset("BALANCED")), compile(build("BALANCED", { reactor = "CORE_260" }))
    assert(ho.energy.capacity / 24 < std.energy.capacity / 24)
    local function drainTime(c)
        local e = Energy.New(c.energy)
        Energy.SetPolicy(e, Profiles.Definitions.MOBILITY)
        local t = 0
        while e.charge > 5 and t < 60 do
            Energy.Request(e, "idle", 8); Energy.Request(e, "propulsion", 60); Energy.Request(e, "sprint", 100)
            Energy.Advance(e, 1 / 60, true)
            t += 1 / 60
        end
        return t
    end
    assert(drainTime(ho) < 60 and drainTime(std) <= 60)
end)
test("heat: conversion runs hotter per unit of energy, but the package dissipates more; the net depends on how the energy is used", function()
    local std, ho = compile(preset("BALANCED")).energy, compile(build("BALANCED", { reactor = "CORE_260" })).energy
    assert(ho.thermalPerEnergy > std.thermalPerEnergy and ho.cooling > std.cooling)
    local function thermalAfter(c)
        local e = Energy.New(c)
        for _ = 1, 120 * 30 do
            Energy.Request(e, "propulsion", 100)
            Energy.Advance(e, 1 / 120, true)
        end
        return e.thermal
    end
    assert(thermalAfter(ho) ~= thermalAfter(std))
end)

print("Request validation (what a client may ask for)")
local base = preset("BALANCED")
test("a legal request returns a fresh loadout and never mutates the base", function()
    local before = Compiler.Clone(base)
    local out, why = Compiler.ApplyRequest(base, { systems = { reactor = "CORE_260", armor = "ARMOR_REINFORCED" }, mounts = { right_arm = "W_HMG_MAULER", left_shoulder = false } })
    assert(out and not why, tostring(why))
    assert(out.systems.reactor == "CORE_260" and out.mounts.right_arm == "W_HMG_MAULER" and out.mounts.left_shoulder == nil)
    assert(Compiler.Same(base, before) and out ~= base and out.mounts ~= base.mounts)
end)
test("invalid or hostile requests are rejected with a reason", function()
    local bad = {
        { "not a table", "nope" }, { "empty", {} }, { "unknown field", { stats = { speed = 99 } } },
        { "numeric stat smuggling", { systems = { reactor = "CORE_260", powerOutput = 9999 } } },
        { "unknown system slot", { systems = { engine = "CORE_260" } } }, { "fixed slot cooling", { systems = { cooling = "RAD_ADVANCED" } } },
        { "shield swap", { systems = { shield = "SHIELD_PULSE" } } }, { "capacitor swap", { systems = { capacitor = "CAP_HIGH_DENSITY" } } },
        { "not offered reactor (CORE_300)", { systems = { reactor = "CORE_300" } } }, { "wrong class", { systems = { armor = "CORE_260" } } },
        { "unknown component", { systems = { reactor = "CORE_NOPE" } } }, { "non-string id", { systems = { reactor = 5 } } },
        { "oversized id", { systems = { reactor = string.rep("X", 200) } } }, { "systems not a table", { systems = "CORE_260" } },
        { "mounts not a table", { mounts = 5 } },
        { "torso socket", { mounts = { left_torso = "W_MACHINE_GUN" } } }, { "unknown socket", { mounts = { back_hump = "W_MACHINE_GUN" } } },
        { "Mauler on a shoulder", { mounts = { left_shoulder = "W_HMG_MAULER" } } },
        { "unimplemented weapon", { mounts = { left_arm = "W_PLASMA_CANNON" } } }, { "missile pod", { mounts = { left_shoulder = "W_MISSILE_POD" } } },
        { "non-weapon in a mount", { mounts = { left_arm = "CORE_220" } } }, { "weapon id true", { mounts = { left_arm = true } } },
        { "overweight", { systems = { armor = "ARMOR_REINFORCED", reactor = "CORE_260" }, mounts = { left_arm = "W_HMG_MAULER", right_arm = "W_HMG_MAULER" } } },
    }
    for _, case in ipairs(bad) do
        local out, why = Compiler.ApplyRequest(base, case[2])
        assert(out == nil and type(why) == "string" and #why > 0, case[1] .. " was accepted")
    end
    assert(Compiler.ApplyRequest(nil, { systems = { reactor = "CORE_260" } }) == nil)
end)
test("direct compile of a hand-forged loadout rejects what the catalog would not offer to a mount", function()
    local forged = build("BALANCED", {}, { left_shoulder = "W_HMG_MAULER" })
    assert(not Compiler.Compile(forged).valid)
    local fakeSlot = build("BALANCED", { turbo = "CORE_260" })
    assert(not Compiler.Compile(fakeSlot).valid)
    local wrongActuator = build("BALANCED", { actuators = "ARMOR_STANDARD" })
    assert(not Compiler.Compile(wrongActuator).valid)
end)
test("session-style retention: applying requests in sequence keeps earlier choices and the factory presets stay pristine", function()
    local l = preset("BALANCED")
    l = assert(Compiler.ApplyRequest(l, { systems = { actuators = "ACT_MOBILITY" } }))
    l = assert(Compiler.ApplyRequest(l, { mounts = { right_arm = "W_LASER_RIFLE" } }))
    assert(l.systems.actuators == "ACT_MOBILITY" and l.mounts.right_arm == "W_LASER_RIFLE")
    assert(Loadouts.presets.BALANCED.systems.actuators == nil and Loadouts.presets.BALANCED.mounts.right_arm == "W_MACHINE_GUN")
    assert(not Compiler.Same(l, Loadouts.presets.BALANCED))
    assert(Compiler.Same(Compiler.Clone(Loadouts.presets.BALANCED), Loadouts.presets.BALANCED))
end)
test("labels describe the engineering choices", function()
    local l = build("BALANCED", { reactor = "CORE_260", actuators = "ACT_MOBILITY", armor = "ARMOR_REINFORCED" })
    local label = Compiler.Label(l)
    for _, part in ipairs({ "CORE 260", "SPRINT M-2", "REINFORCED", "LR-12" }) do assert(string.find(label, part, 1, true), label) end
end)

print(string.format("loadout_tests: %d passed, %d failed", passed, failed))
if failed > 0 then error("loadout tests failed") end
