-- Offline (Luau CLI) tests for M10B: tank state machine, Bastion component damage, shell/aim maths and shield interplay.
-- Run: luau tools/combat_tests.luau
local Config = require("../src/ReplicatedStorage/IronframeShared/CombatConfig")
local Brain = require("../src/ReplicatedStorage/IronframeShared/TankBrain")
local Damage = require("../src/ReplicatedStorage/IronframeShared/MechDamage")
local M = require("../src/ReplicatedStorage/IronframeShared/CombatMath")
local Shield = require("../src/ReplicatedStorage/IronframeShared/PulseShield")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local DConfig = require("../src/ReplicatedStorage/IronframeShared/DestructionConfig")
local Unit = require("../src/ReplicatedStorage/IronframeShared/DestructibleState")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

-- Synthetic senses for a tank that sees the player at `range`.
local function senses(over)
    local s = { active = true, alive = true, canFire = true, canMove = true, resetting = false, hasTarget = true,
        range = 100, los = true, inArc = true, aimError = 0 }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end
-- Runs the brain for `seconds` at 20 Hz; returns the number of shots fired and records visited states in `trace`.
local function run(b, seconds, s, trace)
    local fired = 0
    for _ = 1, math.floor(seconds * 20 + 0.5) do
        local out = Brain.Step(b, 0.05, s)
        if out.fire then fired += 1 end
        if trace and trace[#trace] ~= out.state then table.insert(trace, out.state) end
    end
    return fired
end

print("CombatConfig")
test("three archetypes with the intended ordering of response, warning, reload, shell and armor", function()
    local s, p, h = Config.archetypes.SENTRY, Config.archetypes.PATROL, Config.archetypes.HEAVY
    assert(s and p and h)
    for _, a in pairs(Config.archetypes) do
        assert(a.warnTime >= 0.7 and a.warnTime <= 1.25, a.id .. " warning window must be about 0.7-1.2 s")
        assert(a.shell.speed > 80 and a.shell.life > 2 and a.shell.damage > 0 and a.shell.structure > 0)
        assert(a.detectRange >= a.fireRange and a.loseRange > a.detectRange)
    end
    assert(h.detectTime > s.detectTime and h.warnTime > s.warnTime and h.reload > s.reload, "heavy responds slower and reloads longer")
    assert(h.shell.damage > 2 * s.shell.damage and h.shell.radius > s.shell.radius and h.shell.speed < s.shell.speed, "heavy: bigger, slower, harder")
    assert(h.hp.HULL > 1 and h.hp.TURRET > 1, "heavy has stronger armor")
    assert(s.mobility == "FIXED" and p.mobility == "ROUTE" and h.mobility == "PIVOT")
    assert(p.shell.damage < s.shell.damage, "patrol shell is lighter than the sentry's")
end)
test("shells are slow enough to see and dodge: longest flight inside fire range is 1.2-2.4 s", function()
    for _, a in pairs(Config.archetypes) do
        local flight = a.fireRange / a.shell.speed
        assert(flight >= 1.2 and flight <= 2.4, string.format("%s flight %.2f", a.id, flight))
        assert(a.shell.life >= flight + 0.5, a.id .. " lifetime must cover the fire range")
    end
end)
test("tank shells use the HEAVY structural class (cover breaker)", function()
    assert(DConfig.WeaponClass(Config.shellWeaponId, "ballistic", 55) == "HEAVY")
end)
test("a sentry shell breaks a light panel in a couple of shots and concrete in a handful", function()
    local s = Config.archetypes.SENTRY.shell.structure
    local function shots(material)
        local m = DConfig.materials[material]
        return math.ceil(m.hp / (s * m.resist.HEAVY))
    end
    assert(shots("PANEL") <= 3, "panel " .. shots("PANEL"))
    assert(shots("CONCRETE") >= 3 and shots("CONCRETE") <= 7, "concrete " .. shots("CONCRETE"))
end)

print("TankBrain")
test("IDLE -> DETECT -> TRACK -> AIM -> FIRE -> RELOAD, in that order, with one shot", function()
    local a = Config.archetypes.SENTRY
    local b = Brain.New(a)
    local trace = { "IDLE" }
    local fired = run(b, a.detectTime + a.settleTime + a.warnTime + a.fireTime + 1.5, senses(), trace)
    assert(fired == 1, "shots " .. fired)
    local expected = { "IDLE", "DETECT", "TRACK", "AIM", "FIRE", "RELOAD" }
    for i, state in ipairs(expected) do assert(trace[i] == state, string.format("step %d: %s vs %s (%s)", i, tostring(trace[i]), state, table.concat(trace, ">"))) end
end)
test("the warning period is exactly warnTime: the shell leaves no earlier and no later than the telegraph says", function()
    for _, id in ipairs(Config.archetypeOrder) do
        local a = Config.archetypes[id]
        local b = Brain.New(a)
        local s = senses()
        local t, aimStart, fireAt = 0, nil, nil
        while t < 12 and not fireAt do
            local out = Brain.Step(b, 0.02, s)
            t += 0.02
            if b.state == "AIM" and not aimStart then aimStart = t end
            if out.fire then fireAt = t end
        end
        assert(fireAt and aimStart, id .. " never fired")
        near(fireAt - aimStart, a.warnTime, 0.05, id .. " warning")
    end
end)
test("reload spacing: consecutive shots are at least reload + warn apart", function()
    for _, id in ipairs(Config.archetypeOrder) do
        local a = Config.archetypes[id]
        local b = Brain.New(a)
        local s = senses({ canMove = false })
        local shots = {}
        local t = 0
        for _ = 1, math.floor(40 / 0.05) do
            local out = Brain.Step(b, 0.05, s)
            t += 0.05
            if out.fire then table.insert(shots, t) end
        end
        assert(#shots >= 2, id .. " fired " .. #shots)
        assert(shots[2] - shots[1] >= a.reload + a.warnTime, string.format("%s gap %.2f", id, shots[2] - shots[1]))
    end
end)
test("heavy is slower than sentry from first contact to first shot", function()
    local function firstShot(id)
        local b, t = Brain.New(Config.archetypes[id]), 0
        while t < 20 do
            if Brain.Step(b, 0.02, senses({ canMove = false })).fire then return t end
            t += 0.02
        end
        return 99
    end
    assert(firstShot("HEAVY") > firstShot("SENTRY") + 0.8)
end)
test("no shot without line of sight, outside range or outside the traverse arc", function()
    for _, over in ipairs({ { los = false }, { range = 400 }, { inArc = false }, { hasTarget = false }, { active = false } }) do
        local b = Brain.New(Config.archetypes.SENTRY)
        assert(run(b, 20, senses(over)) == 0, "fired with " .. tostring(next(over)))
    end
end)
test("a fixed sentry is blind outside its traverse arc but keeps tracking; it never repositions", function()
    local b = Brain.New(Config.archetypes.SENTRY)
    local trace = { "IDLE" }
    run(b, 15, senses({ inArc = false }), trace)
    assert(not table.find(trace, "REPOSITION") and not table.find(trace, "AIM"), table.concat(trace, ">"))
    assert(b.state == "TRACK")
end)
test("a firing solution that disappears during AIM aborts the shot back to TRACK", function()
    local a = Config.archetypes.SENTRY
    local b = Brain.New(a)
    run(b, a.detectTime + a.settleTime + 0.4, senses())
    assert(b.state == "AIM", b.state)
    local fired = run(b, 1.0, senses({ los = false }))
    assert(fired == 0 and b.state ~= "AIM" and b.state ~= "FIRE")
end)
test("a patrol tank that cannot get a shot repositions; the heavy pivots instead of driving", function()
    local p = Brain.New(Config.archetypes.PATROL)
    local out
    for _ = 1, 80 do out = Brain.Step(p, 0.05, senses({ range = 170 })) end
    -- out of fire range (150) but inside detection: cannot shoot -> reposition, and the move instruction is a drive
    assert(p.state == "REPOSITION" and out.move == "reposition", p.state .. " " .. tostring(out.move))
    local h = Brain.New(Config.archetypes.HEAVY)
    for _ = 1, 100 do out = Brain.Step(h, 0.05, senses({ inArc = false })) end
    assert(h.state == "REPOSITION" and out.move == "pivot", h.state .. " " .. tostring(out.move))
end)
test("destroyed tracks / engine prevent every kind of movement, including the heavy's hull pivot", function()
    local h = Brain.New(Config.archetypes.HEAVY)
    local out
    for _ = 1, 100 do out = Brain.Step(h, 0.05, senses({ inArc = false, canMove = false })) end
    assert(h.state == "TRACK" and out.move == "none", h.state .. " " .. tostring(out.move))
    local p = Brain.New(Config.archetypes.PATROL)
    for _ = 1, 60 do Brain.Step(p, 0.05, senses({ range = 170 })) end
    assert(p.state == "REPOSITION")
    out = Brain.Step(p, 0.05, senses({ range = 170, canMove = false }))
    assert(p.state == "TRACK" and out.move == "none", "a tank immobilized mid-manoeuvre stops and fights")
end)
test("stops to aim: a patrol tank does not move while AIM or FIRE, and slows while tracking", function()
    local a = Config.archetypes.PATROL
    local b = Brain.New(a)
    local s = senses()
    local sawSlow, moveInAim = false, false
    for _ = 1, 400 do
        local out = Brain.Step(b, 0.05, s)
        if b.state == "TRACK" and out.move == "slow" then sawSlow = true end
        if (b.state == "AIM" or b.state == "FIRE") and out.move ~= "none" then moveInAim = true end
    end
    assert(sawSlow and not moveInAim)
end)
test("passive mode / no valid target sends every state back to IDLE immediately", function()
    local a = Config.archetypes.SENTRY
    for _, stop in ipairs({ { active = false }, { hasTarget = false } }) do
        local b = Brain.New(a)
        run(b, a.detectTime + a.settleTime + 0.5, senses())
        assert(b.state == "AIM")
        local out = Brain.Step(b, 0.05, senses(stop))
        assert(b.state == "IDLE" and not out.fire)
    end
end)
test("DISABLED: destroyed turret or hull stops targeting and firing for good, until a reset", function()
    for _, over in ipairs({ { canFire = false }, { alive = false } }) do
        local b = Brain.New(Config.archetypes.PATROL)
        run(b, 2, senses())
        assert(b.state ~= "IDLE")
        local fired = run(b, 30, senses(over))
        assert(b.state == "DISABLED" and fired == 0)
        -- even if healthy senses came back, it stays disabled
        assert(run(b, 30, senses()) == 0 and b.state == "DISABLED")
        Brain.Reset(b)
        assert(b.state == "IDLE")
    end
end)
test("DISABLED hull = no movement; turret-only loss on a mobile patrol tank keeps it patrolling but never firing", function()
    local b = Brain.New(Config.archetypes.PATROL)
    local out = Brain.Step(b, 0.05, senses({ alive = false, canMove = false }))
    assert(out.move == "none")
    local c = Brain.New(Config.archetypes.PATROL)
    out = Brain.Step(c, 0.05, senses({ canFire = false }))
    assert(c.state == "DISABLED" and out.move == "patrol" and not out.fire)
end)
test("immobilized tanks (tracks / engine) keep firing as turrets but never move", function()
    local b = Brain.New(Config.archetypes.PATROL)
    local s = senses({ canMove = false })
    local fired, moved = 0, false
    for _ = 1, 600 do
        local out = Brain.Step(b, 0.05, s)
        if out.fire then fired += 1 end
        if out.move ~= "none" then moved = true end
    end
    assert(fired >= 3 and not moved, string.format("fired %d moved %s", fired, tostring(moved)))
end)
test("RESET freezes the machine, then returns to IDLE; nothing fires during the reset", function()
    local b = Brain.New(Config.archetypes.SENTRY)
    run(b, 5, senses())
    assert(run(b, 2, senses({ resetting = true })) == 0 and b.state == "RESET")
    Brain.Step(b, 0.05, senses({ active = false }))
    assert(b.state == "IDLE")
end)
test("lost line of sight for longer than loseTime ends the engagement", function()
    local a = Config.archetypes.SENTRY
    local b = Brain.New(a)
    run(b, a.detectTime + 0.1, senses())
    assert(b.state == "TRACK", b.state)
    run(b, a.loseTime + 1.0, senses({ los = false }))
    assert(b.state == "IDLE")
end)

print("MechDamage")
test("region map: legs low, arms at the sides, core in the middle, reactor behind", function()
    local w, h, d = 14, 15.5, 14.5
    assert(Damage.RegionAt(0, -5, -7, w, h, d) == "LEG_R" and Damage.RegionAt(-3, -6, -7, w, h, d) == "LEG_L")
    assert(Damage.RegionAt(0, 0, -7, w, h, d) == "CORE" and Damage.RegionAt(2, 3, -7, w, h, d) == "CORE")
    assert(Damage.RegionAt(-6.5, 1, -7, w, h, d) == "ARM_L" and Damage.RegionAt(6.5, 1, -7, w, h, d) == "ARM_R")
    assert(Damage.RegionAt(0, 2, 6, w, h, d) == "REACTOR" and Damage.RegionAt(3, 3, 7, w, h, d) == "REACTOR")
    assert(Damage.RegionAt(0, -6, 7, w, h, d) == "LEG_R", "low rear shots still hit the legs")
end)
test("damage spills onto the core and never touches anything outside the six regions", function()
    local s = Damage.New()
    local r = Damage.Apply(s, "ARM_L", 100)
    near(r.applied.ARM_L, 100, 1e-9)
    near(r.applied.CORE, 100 * Config.mech.spill, 1e-9)
    assert(s.health.ARM_L == 200 and s.health.ARM_R == 300)
    assert(Damage.Apply(s, "PILOT", 100).applied.PILOT == nil, "unknown regions are ignored (there is no pilot region)")
    assert(Damage.Apply(s, "CORE", -5).applied.CORE == nil and Damage.Apply(s, "CORE", 0 / 0).applied.CORE == nil)
end)
test("stages: OK -> DAMAGED -> CRITICAL -> FAILED and the change is reported once per crossing", function()
    local s = Damage.New()
    local seen = {}
    for _ = 1, 20 do
        local r = Damage.Apply(s, "REACTOR", 40)
        if r.stageChanged.REACTOR then table.insert(seen, r.stageChanged.REACTOR) end
    end
    assert(table.concat(seen, ",") == "DAMAGED,CRITICAL,FAILED", table.concat(seen, ","))
    assert(s.health.REACTOR == 0)
end)
test("weapon assembly loss disables exactly its sockets", function()
    local s = Damage.New()
    assert(next(Damage.Effects(s).sockets) == nil)
    Damage.Apply(s, "ARM_R", 300)
    local fx = Damage.Effects(s).sockets
    assert(fx.right_arm and fx.right_shoulder and not fx.left_arm and not fx.left_shoulder and not fx.left_torso and not fx.right_torso)
    assert(Damage.SocketRegion("right_arm") == "ARM_R" and Damage.SocketRegion("left_torso") == nil)
end)
test("leg damage cuts drive performance progressively with a floor; destroyed legs hurt more", function()
    local s = Damage.New()
    near(Damage.Effects(s).speed, 1, 1e-9)
    Damage.Apply(s, "LEG_L", 190)
    local half = Damage.Effects(s).speed
    assert(half < 1 and half > 0.85, "half-damaged leg: " .. half)
    Damage.Apply(s, "LEG_L", 190)
    local one = Damage.Effects(s).speed
    assert(one < half and one > 0.6, "one leg gone: " .. one)
    Damage.Apply(s, "LEG_R", 1000)
    local both = Damage.Effects(s)
    near(both.speed, Config.mech.leg.floor, 1e-9, "floor")
    assert(both.turn > both.speed and both.turn < 1)
end)
test("reactor damage scales output down to a floor; undamaged reactor is exactly 1", function()
    local s = Damage.New()
    near(Damage.Effects(s).reactor, 1, 1e-9)
    Damage.Apply(s, "REACTOR", 160)
    local half = Damage.Effects(s).reactor
    assert(half < 1 and half > 0.6)
    Damage.Apply(s, "REACTOR", 1000)
    near(Damage.Effects(s).reactor, Config.mech.reactor.floor, 1e-9)
end)
test("core failure is reported once and then the model is inert", function()
    local s = Damage.New()
    local failed = 0
    for _ = 1, 30 do
        if Damage.Apply(s, "CORE", 100).coreFailed then failed += 1 end
    end
    assert(failed == 1 and s.coreFailed and s.health.CORE == 0)
    local taken = s.taken
    Damage.Apply(s, "LEG_L", 100)
    assert(s.taken == taken, "no further damage after core failure")
end)
test("forgiving durability: one unshielded sentry shell is nowhere near core failure; reset restores everything", function()
    local s = Damage.New()
    Damage.Apply(s, "CORE", Config.archetypes.SENTRY.shell.damage)
    assert(Damage.Fraction(s, "CORE") > 0.9)
    local hitsToFail = math.ceil(Config.mech.regions.CORE / Config.archetypes.HEAVY.shell.damage)
    assert(hitsToFail >= 5, "core survives at least 5 unshielded heavy shells, got " .. hitsToFail)
    for _ = 1, 30 do Damage.Apply(s, "CORE", 100) end
    Damage.Reset(s)
    for _, region in ipairs(Damage.Regions) do near(Damage.Fraction(s, region), 1, 1e-9, region) end
    assert(not s.coreFailed and s.hits == 0)
end)
test("part classification follows the rig contract (legs, arms, sided shoulder gear, reactor)", function()
    assert(Damage.ClassifyPart("Thigh", "ThighL", "armor", -2) == "LEG_L" and Damage.ClassifyPart("Foot", "AnkleR", "armor", 2) == "LEG_R")
    assert(Damage.ClassifyPart("Forearm", "ElbowR", "armor", 0) == "ARM_R" and Damage.ClassifyPart("UpperArm", "ShoulderL", "armor", 0) == "ARM_L")
    assert(Damage.ClassifyPart("Weapon_left_arm_barrel", "ElbowL", "weapon", 0) == "ARM_L")
    assert(Damage.ClassifyPart("Weapon_right_shoulder_pod", "Torso", "weapon", 5) == "ARM_R")
    assert(Damage.ClassifyPart("Weapon_left_torso_x", "Torso", "weapon", -2) == "CORE", "torso mounts belong to the core")
    assert(Damage.ClassifyPart("Pauldron", "Torso", "armor", -5.3) == "ARM_L" and Damage.ClassifyPart("Pauldron", "Torso", "armor", 5.3) == "ARM_R")
    assert(Damage.ClassifyPart("ReactorHousing", "Torso", "reactor", 0) == "REACTOR" and Damage.ClassifyPart("ChestArmor", "Torso", "armor", 0) == "CORE")
end)

print("CombatMath")
test("lead: stationary targets are aimed at directly, moving ones partially anticipated", function()
    local ax, az, t = M.lead(0, 0, 0, -100, 0, 0, 100, 0.5)
    near(ax, 0, 1e-9) near(az, -100, 1e-9) near(t, 1, 1e-9)
    local bx = M.lead(0, 0, 0, -100, 10, 0, 100, 0.5) -- crossing at 10 st/s
    assert(bx > 4.5 and bx < 6.5, "half lead of about 10 studs of travel, got " .. bx)
    local full = M.lead(0, 0, 0, -100, 10, 0, 100, 1)
    assert(full > 9.5, "full lead " .. full)
    local none = M.lead(0, 0, 0, -100, 10, 0, 100, 0)
    near(none, 0, 1e-9)
end)
test("rayBox: hits front face with the right normal and time, misses, starts inside, respects maxT", function()
    local t, nx, ny, nz = M.rayBox(0, 0, -20, 0, 0, 1, 7, 8, 7, 100)
    near(t, 13, 1e-9) assert(nx == 0 and ny == 0 and nz == -1)
    assert(M.rayBox(20, 0, -20, 0, 0, 1, 7, 8, 7, 100) == nil, "passes beside the box")
    assert(M.rayBox(0, 0, -20, 0, 0, 1, 7, 8, 7, 10) == nil, "too short to reach")
    local inside = M.rayBox(0, 0, 0, 0, 0, 1, 7, 8, 7, 100)
    assert(inside == 0)
    local t2, ax = M.rayBox(-30, 0, 0, 1, 0, 0, 7, 8, 7, 100)
    near(t2, 23, 1e-9) assert(ax == -1)
    local t3 = M.rayBox(0, 30, 0, 0, -1, 0, 7, 8, 7, 100)
    near(t3, 22, 1e-9)
end)
test("rayBox inflated by the shell radius is a conservative swept sphere", function()
    assert(M.rayBox(8.5, 0, -20, 0, 0, 1, 7, 8, 7, 100) == nil)
    assert(M.rayBox(8.5, 0, -20, 0, 0, 1, 7 + 1.6, 8 + 1.6, 7 + 1.6, 100) ~= nil, "a heavy shell 8.5 off-axis clips the hull")
end)
test("closest approach: time to the target and miss distance for a crossing shell", function()
    local t, miss = M.closest(0, 0, -100, 0, 0, 100, 5, 0, 0)
    near(t, 1, 1e-9) near(miss, 5, 1e-9)
    local past = M.closest(0, 0, 10, 0, 0, 100, 0, 0, 0)
    assert(past < 0)
end)
test("relative bearing follows the drive convention", function()
    near(M.relativeBearing(0, 0, -1), 0, 1e-9)
    near(M.relativeBearing(0, 1, 0), 90, 1e-9)
    near(M.relativeBearing(0, -1, 0), -90, 1e-9)
    near(math.abs(M.relativeBearing(0, 0, 1)), 180, 1e-9)
    near(M.relativeBearing(math.pi / 2, -1, 0), 0, 1e-9)
end)
test("wrap keeps angles in (-pi, pi]", function()
    near(M.wrap(3 * math.pi / 2), -math.pi / 2, 1e-9) near(M.wrap(-3 * math.pi / 2), math.pi / 2, 1e-9)
end)

print("Shield against tank shells (existing M08A shield, unchanged)")
local cfg = Components.SHIELD_PULSE
local function fresh(on)
    local s = Shield.New(cfg)
    if on then
        assert(Shield.Activate(s, cfg, function() return true end, true))
        Shield.Advance(s, cfg, cfg.chargeTime + 0.001, true) -- now PERFECT_GUARD
    end
    return s
end
local function advance(s, seconds) -- Shield.Advance caps each call at 0.25 s, like the server's fixed substeps
    for _ = 1, math.ceil(seconds / 0.05) do Shield.Advance(s, cfg, 0.05, true) end
end
local function consume(budget) return function(c) local u = math.min(budget[1], c) budget[1] -= u return u end end
local function shell(id, fromX, fromZ)
    return { category = "ballistic", damage = Config.archetypes[id].shell.damage, fromX = fromX or 0, fromZ = fromZ or -1 }
end
test("perfect guard mitigates far more than ordinary guard, which mitigates far more than none", function()
    for _, id in ipairs(Config.archetypeOrder) do
        local none = Shield.Resolve(fresh(), cfg, shell(id), 0, consume({ 1000 }))
        local perfect = Shield.Resolve(fresh(true), cfg, shell(id), 0, consume({ 1000 }))
        local s2 = fresh(true)
        advance(s2, cfg.perfectTime + 0.01)
        assert(s2.state == "ACTIVE", s2.state)
        local guard = Shield.Resolve(s2, cfg, shell(id), 0, consume({ 1000 }))
        assert(none.timing == "UNGUARDED" and none.penetrating == none.damage)
        assert(perfect.timing == "PERFECT" and guard.timing == "GUARD")
        assert(perfect.prevented > guard.prevented and guard.prevented > 0, id)
        assert(perfect.prevented / perfect.damage >= 0.9 - 1e-9 or id == "HEAVY", id .. " perfect guard stops >= 90% of a light shell on-axis")
        assert(perfect.prevented / perfect.damage >= 0.75, id .. " perfect guard stops most of any shell on-axis")
        assert(guard.prevented / guard.damage >= 0.6 and guard.prevented / guard.damage <= 0.66, id .. " ordinary guard about 65%")
    end
end)
test("incorrect facing: a shell from behind or beside passes a raised shield (OFF_AXIS)", function()
    local s = fresh(true)
    local r = Shield.Resolve(s, cfg, shell("SENTRY", 0, 1), 0, consume({ 1000 }))
    assert(r.timing == "OFF_AXIS" and r.penetrating == r.damage and r.energy == 0)
    local side = Shield.Resolve(fresh(true), cfg, shell("SENTRY", 1, 0), 0, consume({ 1000 }))
    assert(side.timing == "OFF_AXIS")
    local edge = Shield.Resolve(fresh(true), cfg, shell("SENTRY", math.sin(math.rad(60)), -math.cos(math.rad(60))), 0, consume({ 1000 }))
    assert(edge.timing == "PERFECT" and edge.prevented > 0 and edge.prevented < Config.archetypes.SENTRY.shell.damage, "inside the 65 degree arc but weaker at the edge")
end)
test("missed guard window: before activation or after the active phase the shell is unmitigated", function()
    local s = fresh()
    assert(Shield.Resolve(s, cfg, shell("SENTRY"), 0, consume({ 1000 })).timing == "UNGUARDED")
    local on = fresh(true)
    advance(on, cfg.perfectTime + cfg.activeTime + 0.06)
    assert(on.state == "RECOVERY", on.state)
    assert(Shield.Resolve(on, cfg, shell("SENTRY"), 0, consume({ 1000 })).timing == "UNGUARDED")
end)
test("the perfect window is a real, human-sized target and the telegraph leaves time to hit it", function()
    assert(cfg.perfectTime >= 0.2 and cfg.perfectTime <= 0.3)
    for _, a in pairs(Config.archetypes) do
        local flightAtMax = a.fireRange / a.shell.speed
        assert(a.warnTime + flightAtMax > 2 * cfg.perfectTime + cfg.chargeTime, a.id .. ": time from first cue to impact comfortably exceeds the guard sequence")
    end
end)
test("capacitor depletion: with an empty capacitor the shield cannot be raised; a drained one mitigates little and drops", function()
    local s = Shield.New(cfg)
    assert(not Shield.Activate(s, cfg, function() return false end, true) and s.reason == "CAPACITOR LOW")
    local on = fresh(true)
    local r = Shield.Resolve(on, cfg, shell("HEAVY"), 0, consume({ 3 }))
    assert(r.prevented < r.damage * 0.3, "energy-starved perfect guard prevents little: " .. r.prevented)
    assert(on.state == "RECOVERY", "an under-funded absorb collapses the shield")
end)
test("heavy shell stresses shield integrity: a second heavy shell in one raise is only partly absorbed", function()
    local on = fresh(true)
    local budget = consume({ 1000 })
    local first = Shield.Resolve(on, cfg, shell("HEAVY"), 0, budget)
    assert(first.prevented > 100)
    assert(on.integrity <= cfg.integrity - first.prevented + 1e-6)
    if on.state ~= "RECOVERY" then
        local second = Shield.Resolve(on, cfg, shell("HEAVY"), 0, budget)
        assert(second.prevented <= cfg.integrity - first.prevented + 1e-6)
    end
end)
test("shield cooldown: after one raise the shield is unavailable for several seconds", function()
    local s = fresh(true)
    assert(Shield.Cooldown(s) > 4)
    assert(not Shield.Activate(s, cfg, function() return true end, true), "cannot re-raise while the cycle is running")
end)

print("Archetype armor via component units")
test("heavy components are tougher than stock; the sentry uses stock health", function()
    local base = DConfig.materials.VEHICLE_HULL.hp
    local heavy = Unit.New({ material = "VEHICLE_HULL", hp = base * Config.archetypes.HEAVY.hp.HULL })
    local stock = Unit.New({ material = "VEHICLE_HULL" })
    assert(heavy.capacity > stock.capacity and stock.capacity == base)
end)

print(string.format("\ncombat_tests: %d passed, %d failed", passed, failed))
if failed > 0 then error("combat tests failed") end
