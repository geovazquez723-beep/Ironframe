-- Offline (Luau CLI) tests for the M10A destructible-environment rules. Run: luau tools/destruction_tests.luau
local Config = require("../src/ReplicatedStorage/IronframeShared/DestructionConfig")
local Unit = require("../src/ReplicatedStorage/IronframeShared/DestructibleState")
local Rules = require("../src/ReplicatedStorage/IronframeShared/ComponentRules")
local Batch = require("../src/ReplicatedStorage/IronframeShared/FxBatch")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

local WEAPONS = { MG = "W_MACHINE_GUN", LASER = "W_LASER_RIFLE", HEAVY = "W_HMG_MAULER" }
local CLASSES = { "MG", "LASER", "HEAVY" }

-- Seconds of continuous fire to destroy `hp` of `material` with a weapon class (raw registry numbers, no energy limit).
local function timeToDestroy(material, class)
    local spec = Components[WEAPONS[class]].combat
    local dps = spec.damage / spec.interval
    local m = Config.materials[material]
    return m.hp / (dps * m.resist[class])
end

print("DestructionConfig")
test("weapon balance numbers are untouched by M10A", function()
    local mg, lr, hmg = Components.W_MACHINE_GUN.combat, Components.W_LASER_RIFLE.combat, Components.W_HMG_MAULER.combat
    assert(mg.damage == 8 and mg.interval == 0.1 and mg.energy == 0.6 and mg.magazine == 60 and mg.category == "ballistic")
    assert(lr.damage == 25 and lr.interval == 0.25 and lr.energy == 24 and lr.category == "laser")
    assert(hmg.damage == 25 and math.abs(hmg.interval - 1 / 3) < 1e-9 and hmg.energy == 2.5 and hmg.magazine == 24 and hmg.reload == 3.8)
end)
test("every material has a positive health and a resistance for every weapon class", function()
    for id, m in pairs(Config.materials) do
        assert(m.hp > 0 and m.damagedAt > 0 and m.damagedAt < 1, id)
        for _, class in ipairs(CLASSES) do assert(m.resist[class] and m.resist[class] > 0, id .. " " .. class) end
        assert(Config.fx[m.fx], id .. " has no fx family " .. tostring(m.fx))
    end
end)
test("weapon ids map to classes; unknown weapons fall back by category and damage", function()
    assert(Config.WeaponClass("W_MACHINE_GUN") == "MG" and Config.WeaponClass("W_LASER_RIFLE") == "LASER" and Config.WeaponClass("W_HMG_MAULER") == "HEAVY")
    assert(Config.WeaponClass(nil, "laser", 10) == "LASER")
    assert(Config.WeaponClass("W_FUTURE", "ballistic", 8) == "MG")
    assert(Config.WeaponClass("W_FUTURE", "ballistic", 40) == "HEAVY")
    assert(Config.WeaponClass(nil, "plasma", 50) == nil, "weapons without a defined class do no structural damage")
end)
test("weapon identity: MG shreds light panels and machinery but is the worst against concrete, structure and heavy armor", function()
    assert(timeToDestroy("PANEL", "MG") < 2 and timeToDestroy("MACHINERY", "MG") < 2.5)
    for _, material in ipairs({ "CONCRETE", "STRUCTURE", "VEHICLE_HULL", "ARMOR" }) do
        assert(timeToDestroy(material, "MG") > timeToDestroy(material, "LASER"), material .. " MG should be slower than LASER")
        assert(timeToDestroy(material, "MG") > timeToDestroy(material, "HEAVY"), material .. " MG should be slower than HEAVY")
    end
    assert(timeToDestroy("CONCRETE", "MG") > 8 * timeToDestroy("PANEL", "MG"), "MG vs concrete must be a different experience than vs panels")
end)
test("weapon identity: Mauler is the cover-breaker, laser is the armor/machine concentrator", function()
    for _, material in ipairs({ "CONCRETE", "STRUCTURE" }) do
        assert(timeToDestroy(material, "HEAVY") < timeToDestroy(material, "LASER"), material)
    end
    assert(timeToDestroy("CONCRETE", "HEAVY") < 5, "Mauler brings a concrete module down in a few seconds")
    assert(timeToDestroy("ARMOR", "LASER") < timeToDestroy("ARMOR", "MG") / 2)
    assert(timeToDestroy("VEHICLE_TRACK", "HEAVY") < timeToDestroy("VEHICLE_TRACK", "MG"))
end)

print("DestructibleState")
test("staged damage INTACT -> DAMAGED -> DESTROYED with exact numbers", function()
    local u = Unit.New({ material = "CONCRETE", hp = 100, resist = { HEAVY = 1, MG = 1 } })
    assert(u.stage == "INTACT")
    local dealt, old, new = Unit.Hit(u, "HEAVY", 30)
    near(dealt, 30); assert(old == "INTACT" and new == "INTACT")
    dealt, old, new = Unit.Hit(u, "HEAVY", 10) -- 60 left, damagedAt .66 -> <= 66
    assert(old == "INTACT" and new == "DAMAGED", new)
    dealt, old, new = Unit.Hit(u, "HEAVY", 500)
    near(dealt, 60); assert(new == "DESTROYED" and u.health == 0, "no overkill beyond remaining health")
    dealt, old, new = Unit.Hit(u, "HEAVY", 50)
    assert(dealt == 0 and old == "DESTROYED" and new == "DESTROYED", "a destroyed unit takes nothing")
end)
test("resistance table is applied per class and per-object overrides replace material values", function()
    local u = Unit.New({ material = "ARMOR", hp = 1000 })
    near((Unit.Hit(u, "MG", 10)), 3.4)
    near((Unit.Hit(u, "LASER", 10)), 8.5)
    near((Unit.Hit(u, "HEAVY", 10)), 11.2)
    local override = Unit.New({ material = "ARMOR", hp = 1000, resist = { MG = 1 } })
    near((Unit.Hit(override, "MG", 10)), 10)
    near((Unit.Hit(override, "LASER", 10)), 8.5, 1e-6, "other classes keep the material value")
end)
test("invalid damage (NaN, zero, negative, inf-safe) never changes state", function()
    local u = Unit.New({ material = "PANEL" })
    for _, bad in ipairs({ 0, -5, 0 / 0 }) do
        local dealt = Unit.Hit(u, "MG", bad)
        assert(dealt == 0 and u.health == u.capacity and u.hits == 0)
    end
    local dealt = Unit.Hit(u, "MG", math.huge)
    near(dealt, u.capacity); assert(u.health == 0 and u.stage == "DESTROYED")
end)
test("splash scale and forced destruction", function()
    local u = Unit.New({ material = "CONCRETE", hp = 100, resist = { HEAVY = 1 } })
    near((Unit.Hit(u, "HEAVY", 20, 0.5)), 10)
    near(Unit.Destroy(u), 90); assert(u.stage == "DESTROYED")
end)
test("reset restores health and stage; 1000 cycles stay exact", function()
    local u = Unit.New({ material = "STRUCTURE", hp = 200 })
    for i = 1, 1000 do
        Unit.Hit(u, "HEAVY", 1e9)
        assert(u.stage == "DESTROYED")
        Unit.Reset(u)
        assert(u.health == 200 and u.stage == "INTACT" and u.hits == 0 and u.damageTaken == 0)
    end
    assert(u.resets == 1000)
end)
test("support graph: losing any support collapses the supported node, and nothing else", function()
    local nodes = {
        colA = { destroyed = false }, colB = { destroyed = false },
        beam = { destroyed = false, supports = { "colA", "colB" } },
        roof = { destroyed = false, supports = { "beam" } },
        lone = { destroyed = false, supports = { "missing" } },
    }
    assert(#Unit.Unsupported(nodes) == 0)
    nodes.colB.destroyed = true
    local list = Unit.Unsupported(nodes)
    assert(#list == 1 and list[1] == "beam")
    nodes.beam.destroyed = true
    list = Unit.Unsupported(nodes)
    assert(#list == 1 and list[1] == "roof", "cascades one level per resolution pass")
end)

print("ComponentRules")
local function tankUnits()
    return {
        HULL = Unit.New({ material = "VEHICLE_HULL" }), TURRET = Unit.New({ material = "VEHICLE_TURRET" }),
        TRACK_L = Unit.New({ material = "VEHICLE_TRACK" }), TRACK_R = Unit.New({ material = "VEHICLE_TRACK" }),
        ENGINE = Unit.New({ material = "VEHICLE_ENGINE" }),
    }
end
test("tank: fresh vehicle is operational and mobile", function()
    local s = Rules.Tank(tankUnits())
    assert(s.mobile and s.turretOperational and not s.destroyed and s.status == "OPERATIONAL")
end)
test("tank: either track disables movement but not the turret", function()
    for _, track in ipairs({ "TRACK_L", "TRACK_R" }) do
        local u = tankUnits(); Unit.Destroy(u[track])
        local s = Rules.Tank(u)
        assert(not s.mobile and s.turretOperational and not s.destroyed and s.status == "IMMOBILIZED", track)
    end
end)
test("tank: turret loss disables the turret only; hull loss disables everything", function()
    local u = tankUnits(); Unit.Destroy(u.TURRET)
    local s = Rules.Tank(u)
    assert(s.mobile and not s.turretOperational and s.status == "TURRET DISABLED")
    Unit.Destroy(u.HULL)
    s = Rules.Tank(u)
    assert(s.destroyed and not s.mobile and not s.turretOperational and s.status == "VEHICLE DESTROYED")
end)
test("tank: engine loss immobilizes", function()
    local u = tankUnits(); Unit.Destroy(u.ENGINE)
    assert(not Rules.Tank(u).mobile)
end)
test("training mech: component states and terminal chassis failure", function()
    local u = {
        CHASSIS = Unit.New({ material = "MECH_CHASSIS" }), ARM_MOUNT = Unit.New({ material = "MECH_ARM" }),
        SHOULDER_ARMOR = Unit.New({ material = "MECH_ARMOR" }), LEG_ASSEMBLY = Unit.New({ material = "MECH_LEG" }),
    }
    assert(Rules.Mech(u).status == "OPERATIONAL")
    Unit.Destroy(u.SHOULDER_ARMOR); assert(Rules.Mech(u).status == "ARMOR STRIPPED" and not Rules.Mech(u).disabled)
    Unit.Destroy(u.ARM_MOUNT); assert(Rules.Mech(u).weaponMountLost and Rules.Mech(u).status == "WEAPON MOUNT LOST")
    Unit.Destroy(u.LEG_ASSEMBLY); assert(Rules.Mech(u).legsLost and Rules.Mech(u).status == "MOBILITY DISABLED")
    Unit.Destroy(u.CHASSIS); assert(Rules.Mech(u).disabled and Rules.Mech(u).status == "TARGET DISABLED")
end)
test("status vocabulary never uses casualty language", function()
    local u = tankUnits(); Unit.Destroy(u.HULL)
    local words = { Rules.Tank(u).status, Rules.Mech({ CHASSIS = Unit.New({ material = "MECH_CHASSIS" }) }).status }
    for _, w in ipairs(words) do assert(not string.find(string.lower(w), "kill") and not string.find(string.lower(w), "dead")) end
end)

print("FxBatch")
test("hits are lossy per packet, important events are not, and packets respect the interval", function()
    local b = Batch.New(0.1, 3, 6)
    for i = 1, 10 do Batch.PushHit(b, { t = "h", i = i }) end
    Batch.Push(b, { t = "x", i = 1 }); Batch.Push(b, { t = "x", i = 2 })
    local packet = Batch.Flush(b, 0)
    assert(packet and #packet == 5 and packet[1].t == "x" and packet[2].t == "x", "important first, then 3 hits")
    assert(b.dropped == 7)
    assert(Batch.Flush(b, 0.05) == nil)
    assert(Batch.Flush(b, 0.2) == nil, "nothing pending")
end)
test("important overflow rolls into later packets in order", function()
    local b = Batch.New(0, 5, 4)
    for i = 1, 10 do Batch.Push(b, { t = "x", i = i }) end
    local seen = {}
    for step = 1, 4 do
        local packet = Batch.Flush(b, step)
        if packet then
            assert(#packet <= 4)
            for _, e in ipairs(packet) do table.insert(seen, e.i) end
        end
    end
    assert(#seen == 10)
    for i = 1, 10 do assert(seen[i] == i) end
end)

print(string.format("destruction: %d passed, %d failed", passed, failed))
if failed > 0 then error("destruction tests failed") end
