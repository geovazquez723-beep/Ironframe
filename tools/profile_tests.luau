-- M09 energy profile tests: pure, deterministic, run with the stock Luau CLI (no Roblox services).
local Energy = require("../src/ReplicatedStorage/IronframeShared/Energy")
local Profiles = require("../src/ReplicatedStorage/IronframeShared/EnergyProfiles")
local Shield = require("../src/ReplicatedStorage/IronframeShared/PulseShield")
local Config = require("../src/ReplicatedStorage/IronframeShared/EnergyConfig")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol) assert(math.abs(a - b) < (tol or 1e-6), tostring(a) .. " vs " .. tostring(b)) end
local function config()
    return Config.Build(Chassis.IF42_BASTION, Components.CORE_220, Components.CAP_STANDARD, Components.RAD_STANDARD, Components.SHIELD_PULSE)
end
local function balanceError(s)
    return s.ledger.initial + s.ledger.generated - (s.charge + s.ledger.consumed + s.ledger.loss + s.ledger.wasted)
end

-- A profile's ordering with its reserves removed, to isolate priority arbitration from reserve gating.
local function priorityOnly(id) return { priority = Profiles.Definitions[id].priority, reserve = {} } end

-- Mirrors EnergySystems.Step + Weapons.Step ordering: continuous requests -> Advance -> discrete weapon payments.
local WEAPONS = {
    laser = Components.W_LASER_RIFLE.combat, mg = Components.W_MACHINE_GUN.combat, mauler = Components.W_HMG_MAULER.combat,
}
local function sim(profileId, o)
    local c = config()
    local e = Energy.New(c, o.charge)
    if profileId then Energy.SetPolicy(e, Profiles.Definitions[profileId]) end
    local hz = 60
    local steps = math.floor(o.seconds * hz + 0.5)
    local next, shots = {}, {}
    for name in pairs(o.weapons or {}) do next[name], shots[name] = 0, 0 end
    local sprintSum, sprintSteps, minCharge, speedSum = 0, 0, math.huge, 0
    for i = 1, steps do
        local t = i / hz
        local drive = { speed = if o.moving then (if o.sprint then 16 * c.movement.sprintMultiplier else 16) else 0, accel = 0 }
        local propulsion, boost = 0, 0
        Energy.Request(e, "idle", c.movement.idle)
        if o.moving then
            propulsion, boost = Energy.MovementDemand(c, drive, 1, 0, o.sprint)
            Energy.Request(e, "propulsion", propulsion)
        end
        Energy.Request(e, "sprint", boost)
        if o.shieldSustain then Energy.Request(e, "shield", c.shield.activeDrain) end
        if o.extra then for key, rate in pairs(o.extra) do Energy.Request(e, key, rate) end end
        Energy.Advance(e, 1 / hz, true)
        if boost > 0 then
            local frac = math.clamp((e.delivered.sprint or 0) / boost, 0, 1)
            sprintSum += frac; sprintSteps += 1
        end
        local base, boostFrac = Energy.Performance(e, propulsion, boost)
        speedSum += base * (1 + boostFrac * (c.movement.sprintMultiplier - 1))
        for name in pairs(o.weapons or {}) do
            local spec = WEAPONS[name]
            if t >= next[name] then
                next[name] = t + spec.interval
                if Energy.Consume(e, spec.energy, false, 0, "weapons") == spec.energy then
                    shots[name] += 1
                    e.thermal = math.clamp(e.thermal + spec.heat, 0, c.thermalMaximum)
                end
            end
        end
        minCharge = math.min(minCharge, e.charge)
    end
    return { e = e, shots = shots, sprint = if sprintSteps > 0 then sprintSum / sprintSteps else 0, minCharge = minCharge,
        speed = speedSum / steps, balance = balanceError(e) }
end

-- ---------------------------------------------------------------------------------------------------------------
print("profile definitions and switching")
test("exactly MOBILITY, BALANCED and WEAPONS are selectable and defined by data", function()
    assert(#Profiles.Order == 3 and Profiles.Default == "BALANCED")
    for _, id in ipairs(Profiles.Order) do
        local d = assert(Profiles.Definitions[id], id)
        for _, key in ipairs({ "sprint", "weapons", "shield" }) do
            assert(d.priority[key] >= 3 and d.reserve[key] >= 0 and d.reserve[key] < 1, id .. "." .. key)
        end
    end
end)
test("invalid, locked and malformed profile ids are rejected without changing state", function()
    local s = Profiles.New()
    for _, bad in ipairs({ "", "NOPE", "mobility", 5, true, {}, string.rep("A", 100), "__index", "BALANCED\0" }) do
        local ok = Profiles.Request(s, bad, 10)
        assert(not ok, tostring(bad))
    end
    assert(s.active == "BALANCED" and s.pending == nil and s.lastRequestAt == -math.huge)
    local ok, reason = Profiles.Request(s, "OVERDRIVE", 10)
    assert(not ok and reason == "PROFILE LOCKED")
    for id in pairs(Profiles.Planned) do assert(not Profiles.Definitions[id] and not table.find(Profiles.Order, id), id) end
end)
test("switch has a 0.5s transition, keeps the old policy until it completes, then applies once", function()
    local s = Profiles.New()
    assert(Profiles.Request(s, "WEAPONS", 100))
    assert(s.pending == "WEAPONS" and Profiles.Policy(s) == Profiles.Definitions.BALANCED)
    assert(not Profiles.Update(s, 100.49) and s.active == "BALANCED")
    near(Profiles.Remaining(s, 100.25), 0.25)
    assert(Profiles.Update(s, 100.5) and s.active == "WEAPONS" and s.pending == nil and s.serial == 1)
    assert(not Profiles.Update(s, 101) and s.serial == 1)
end)
test("switch cooldown, same-profile and in-progress requests are rejected deterministically", function()
    local s = Profiles.New()
    assert(Profiles.Request(s, "MOBILITY", 0))
    local ok, why = Profiles.Request(s, "WEAPONS", 0.2); assert(not ok and why == "SWITCH IN PROGRESS")
    Profiles.Update(s, 0.5)
    ok, why = Profiles.Request(s, "WEAPONS", 1.0); assert(not ok and why == "SWITCH COOLDOWN")
    ok, why = Profiles.Request(s, "MOBILITY", 5.0); assert(not ok and why == "ALREADY ACTIVE")
    assert(Profiles.Request(s, "WEAPONS", Profiles.MinInterval + 0.001))
    assert(s.pending == "WEAPONS")
end)
test("cancelling (ejection / dock) drops the pending switch but keeps the active policy", function()
    local s = Profiles.New()
    Profiles.Request(s, "WEAPONS", 0); Profiles.Cancel(s)
    assert(s.pending == nil and s.active == "BALANCED"); assert(not Profiles.Update(s, 10) and s.active == "BALANCED")
    assert(Profiles.Next("MOBILITY") == "BALANCED" and Profiles.Next("WEAPONS") == "MOBILITY")
end)

print("arbitration")
test("mandatory baseline ignores profile priority and reserve: propulsion is always served first", function()
    local c = config(); local e = Energy.New(c, 0)
    Energy.SetPolicy(e, { priority = { idle = 99, propulsion = 99, sprint = 3 }, reserve = { idle = 1, propulsion = 1, sprint = 0 } })
    c.output = 50; Energy.Request(e, "sprint", 100); Energy.Request(e, "propulsion", 40); Energy.Request(e, "idle", 8)
    Energy.Advance(e, 1 / 60, true)
    near(e.delivered.idle, 8, 1e-6); near(e.delivered.propulsion, 40, 1e-6); near(e.delivered.sprint, 2, 1e-6)
end)
test("equal priority requests share supply in proportion to demand regardless of insertion order", function()
    local function run(order)
        local c = config(); c.output = 60; local e = Energy.New(c, 0)
        Energy.SetPolicy(e, priorityOnly("BALANCED"))
        for _, key in ipairs(order) do Energy.Request(e, key, if key == "sprint" then 100 else 20) end
        Energy.Advance(e, 1 / 60, true)
        return e.delivered
    end
    local a, b = run({ "sprint", "weapons" }), run({ "weapons", "sprint" })
    near(a.sprint, b.sprint); near(a.weapons, b.weapons)
    near(a.sprint / 100, a.weapons / 20, 1e-6) -- same fraction served
    near(a.sprint + a.weapons, 60, 1e-6)
end)
test("reserve floors hold back discretionary capacitor draw and never block mandatory draw", function()
    local c = config(); c.output = 0; local e = Energy.New(c, 80) -- 50% charge
    Energy.SetPolicy(e, Profiles.Definitions.WEAPONS) -- sprint reserve 55% = 88 > charge
    Energy.Request(e, "sprint", 100); Energy.Request(e, "propulsion", 30)
    Energy.Advance(e, 0.25, true)
    near(e.delivered.sprint or 0, 0, 1e-9); assert(e.delivered.propulsion > 29.9)
    assert(e.charge < 80 - 7 and e.charge > 0)
end)
test("discrete payments honour the paying subsystem's reserve; unnamed payments do not", function()
    local c = config(); local e = Energy.New(c, 70) -- 43.75%
    Energy.SetPolicy(e, Profiles.Definitions.MOBILITY) -- weapons reserve 40% = 64
    assert(not Energy.Spend(e, 24, "weapons") and e.charge == 70)
    assert(Energy.Spend(e, 5, "weapons")); near(e.charge, 65)
    assert(Energy.Spend(e, 25, "shield")) -- shield has no reserve in any profile
end)
test("no policy reproduces the M08 priority order exactly", function()
    local c = config(); c.output = 10; local e = Energy.New(c, 0)
    for _, key in ipairs({ "sprint", "weapons", "shield", "propulsion", "idle" }) do Energy.Request(e, key, 10) end
    Energy.Advance(e, 1 / 60, true)
    near(e.delivered.idle, 10); assert((e.delivered.sprint or 0) == 0 and (e.delivered.weapons or 0) == 0)
end)

print("comparative scenarios (identical hardware, charge and demand)")
local function summary(id, o) local r = sim(id, o); return r end
test("low demand: all three profiles behave identically", function()
    local o = { seconds = 6, moving = true, weapons = { mg = true, mauler = true } }
    local a, b, c = summary("MOBILITY", o), summary("BALANCED", o), summary("WEAPONS", o)
    for _, r in ipairs({ b, c }) do
        assert(r.shots.mg == a.shots.mg and r.shots.mauler == a.shots.mauler, "shot counts differ")
        near(r.e.charge, a.e.charge, 1e-6); near(r.speed, a.speed, 1e-9)
    end
    assert(a.shots.mg >= 55 and a.shots.mauler >= 16)
end)
test("sprint + laser: MOBILITY keeps sprint longest, WEAPONS fires most lasers, BALANCED sits between", function()
    local o = { seconds = 12, moving = true, sprint = true, weapons = { laser = true } }
    local m, b, w = summary("MOBILITY", o), summary("BALANCED", o), summary("WEAPONS", o)
    print(string.format("      sprint avg  MOB %.3f  BAL %.3f  WPN %.3f", m.sprint, b.sprint, w.sprint))
    print(string.format("      lasers      MOB %d  BAL %d  WPN %d   speed %.3f/%.3f/%.3f", m.shots.laser, b.shots.laser, w.shots.laser, m.speed, b.speed, w.speed))
    assert(m.sprint > b.sprint and b.sprint > w.sprint, "sprint ordering")
    assert(w.shots.laser > b.shots.laser and b.shots.laser > m.shots.laser, "laser ordering")
    assert(m.speed > w.speed)
end)
test("sprint + Mauler + MG-9: profiles change availability, not per-shot energy or cadence", function()
    local o = { seconds = 10, moving = true, sprint = true, weapons = { mauler = true, mg = true } }
    local m, b, w = summary("MOBILITY", o), summary("BALANCED", o), summary("WEAPONS", o)
    print(string.format("      mauler      MOB %d  BAL %d  WPN %d   mg %d/%d/%d", m.shots.mauler, b.shots.mauler, w.shots.mauler, m.shots.mg, b.shots.mg, w.shots.mg))
    assert(w.shots.mauler >= b.shots.mauler and b.shots.mauler >= m.shots.mauler)
    assert(w.shots.mg >= b.shots.mg and b.shots.mg >= m.shots.mg)
    assert(m.sprint >= b.sprint and b.sprint >= w.sprint)
    for _, r in ipairs({ m, b, w }) do assert(r.shots.mauler <= math.ceil(10 / WEAPONS.mauler.interval) + 1) end
end)
test("conservation: every profile balances its ledger and total deliverable energy never exceeds reactor + stored charge", function()
    local o = { seconds = 10, moving = true, sprint = true, weapons = { laser = true, mauler = true, mg = true } }
    for _, id in ipairs(Profiles.Order) do
        local r = sim(id, o)
        near(r.balance, 0, 1e-6)
        assert(r.e.ledger.consumed <= r.e.ledger.initial + r.e.ledger.generated + 1e-6, id)
        assert(r.e.charge >= -1e-9 and r.e.charge <= r.e.config.capacity + 1e-9, id)
    end
    -- Same installed reactor: no profile can generate more than nominal output (thermal strain may only reduce it).
    local nominal = config().output * 3
    for _, id in ipairs(Profiles.Order) do
        local generated = sim(id, { seconds = 3, moving = true, sprint = true }).e.ledger.generated
        assert(generated <= nominal + 1e-6 and generated > nominal * 0.95, id .. " " .. generated)
    end
end)
test("same-tick competing demands resolve identically whichever subsystem is evaluated first", function()
    local function run(charge, weaponsFirst)
        local c = config(); local e = Energy.New(c, charge); Energy.SetPolicy(e, Profiles.Definitions.BALANCED)
        local paid
        local function pay() paid = Energy.Spend(e, 24, "weapons") end
        if weaponsFirst then pay() end
        Energy.Request(e, "idle", 8); Energy.Request(e, "propulsion", 40); Energy.Request(e, "sprint", 100)
        Energy.Advance(e, 1 / 60, true)
        if not weaponsFirst then pay() end
        return paid
    end
    -- Balanced: sprint stops at 30% (48), weapons need 20% (32) left over. A shot needs 56 charge.
    for _, charge in ipairs({ 150, 100, 70 }) do assert(run(charge, true) and run(charge, false), "funded at " .. charge) end
    for _, charge in ipairs({ 55, 40, 20, 5 }) do assert(not run(charge, true) and not run(charge, false), "reserved at " .. charge) end
end)
test("capacitor depletion keeps minimum locomotion, then recovers when demand stops", function()
    local c = config(); local e = Energy.New(c, 0)
    for _, id in ipairs(Profiles.Order) do
        e = Energy.New(c, 0); Energy.SetPolicy(e, Profiles.Definitions[id])
        for _ = 1, 120 do
            Energy.Request(e, "idle", 8); local p, b = Energy.MovementDemand(c, { speed = 25, accel = 0 }, 1, 0, true)
            Energy.Request(e, "propulsion", p); Energy.Request(e, "sprint", b); Energy.Advance(e, 1 / 60, true)
        end
        local p = Energy.MovementDemand(c, { speed = 25, accel = 0 }, 1, 0, true)
        local base = Energy.Performance(e, p, 100)
        assert(base >= 0.65, id .. " fell below limp-mode locomotion")
        for _ = 1, 60 * 5 do Energy.Request(e, "idle", 8); Energy.Advance(e, 1 / 60, true) end
        assert(e.charge > 100, id .. " did not recover: " .. e.charge)
    end
end)

print("shield interaction")
test("shield activation and sustain are profile-independent in cost, timing and perfect-guard window", function()
    local results = {}
    for _, id in ipairs(Profiles.Order) do
        local c = config(); local e = Energy.New(c); Energy.SetPolicy(e, Profiles.Definitions[id])
        local s = Shield.New(c.shield)
        assert(Shield.Activate(s, c.shield, function(cost) return Energy.Spend(e, cost, "shield") end, true), id)
        near(e.charge, 135)
        local t = 0
        while t < c.shield.chargeTime + 0.05 do Shield.Advance(s, c.shield, 1 / 120, true); t += 1 / 120 end
        assert(s.state == "PERFECT_GUARD", id .. " " .. s.state)
        local r = Shield.Resolve(s, c.shield, { damage = 60, category = "laser", fromX = 0, fromZ = -1 }, 0, function(cost) return Energy.Consume(e, cost, true, nil, "shield") end)
        results[id] = r
        assert(r.timing == "PERFECT")
    end
    near(results.MOBILITY.prevented, results.WEAPONS.prevented); near(results.BALANCED.energy, results.MOBILITY.energy)
end)
test("shield activation stays energy-limited when the capacitor is empty, in every profile", function()
    for _, id in ipairs(Profiles.Order) do
        local c = config(); local e = Energy.New(c, 10); Energy.SetPolicy(e, Profiles.Definitions[id])
        local s = Shield.New(c.shield)
        assert(not Shield.Activate(s, c.shield, function(cost) return Energy.Spend(e, cost, "shield") end, true) and s.reason == "CAPACITOR LOW")
    end
end)
test("shield sustain outranks weapons in BALANCED/WEAPONS and sprint in BALANCED; MOBILITY serves sprint first", function()
    local function delivered(id)
        local c = config(); c.output = 60; local e = Energy.New(c, 0); Energy.SetPolicy(e, priorityOnly(id))
        Energy.Request(e, "shield", 50); Energy.Request(e, "sprint", 100); Energy.Request(e, "weapons", 100)
        Energy.Advance(e, 1 / 60, true)
        return e.delivered
    end
    local w, b, m = delivered("WEAPONS"), delivered("BALANCED"), delivered("MOBILITY")
    near(w.shield, 50); near(w.weapons, 10); assert((w.sprint or 0) < 1e-9)
    near(b.shield, 50); near(b.sprint + b.weapons, 10)
    near(m.sprint, 60); assert((m.shield or 0) < 1e-9)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("profile tests failed") end
