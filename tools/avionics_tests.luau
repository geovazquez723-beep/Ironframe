-- Offline (Luau CLI) tests for M11C: cockpit packages, avionics registry and compatibility, build compilation, request validation, the radar
-- contact model (range, bearing, obstruction, ageing), thermal signatures, tracker / thermal / radar capability under power starvation and
-- sensor damage, the energy ledger with the avionics load, the zoom controller and camera lifecycle.  Run: luau tools/avionics_tests.luau
local Compiler = require("../src/ReplicatedStorage/IronframeShared/LoadoutCompiler")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local Loadouts = require("../src/ReplicatedStorage/IronframeShared/Loadouts")
local Layouts = require("../src/ReplicatedStorage/IronframeShared/CockpitLayouts")
local Avionics = require("../src/ReplicatedStorage/IronframeShared/Avionics")
local Sensors = require("../src/ReplicatedStorage/IronframeShared/SensorModel")
local Thermal = require("../src/ReplicatedStorage/IronframeShared/ThermalSignature")
local Contract = require("../src/ReplicatedStorage/IronframeShared/TargetContract")
local Zoom = require("../src/ReplicatedStorage/IronframeShared/ZoomControl")
local Energy = require("../src/ReplicatedStorage/IronframeShared/Energy")
local Profiles = require("../src/ReplicatedStorage/IronframeShared/EnergyProfiles")
local Warnings = require("../src/ReplicatedStorage/IronframeShared/CockpitWarnings")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

local function preset(id) return Compiler.Clone(Loadouts.presets[id]) end
local function compile(l)
    local c = Compiler.Compile(l)
    assert(c.valid, table.concat(c.issues, "; "))
    return c
end
local function with(base, cockpit, avionics, mounts)
    local l = preset(base)
    l.cockpit, l.avionics = cockpit, avionics
    for k, v in pairs(mounts or {}) do l.mounts[k] = if v == false then nil else v end
    return l
end
local FULL = { radar = "AV_RADAR_ENHANCED", optics = "AV_OPTICS_ZOOM", thermal = "AV_THERMAL", targeting = "AV_TRACKER" }
local NO_MISSILE = { left_shoulder = false }

print("Cockpit packages and the avionics registry")
test("the Bastion names a layout, two packages and its factory equipment; the layout and both palettes exist", function()
    local c = Chassis.IF42_BASTION.cockpit
    assert(c.layout == "BASTION_FRAME" and #c.packages == 2 and c.defaultPackage == "CKP_STANDARD" and c.defaultAvionics.radar == "AV_RADAR_BASIC")
    local frame = Layouts.Frame(c.layout)
    assert(frame and frame.eye and frame.mounts.auxLeft and frame.mounts.auxRight and frame.mounts.hood)
    for _, id in ipairs(c.packages) do
        local p = Components[id]
        assert(p.class == "cockpit" and table.find(p.layouts, c.layout) and Layouts.palettes[p.palette] ~= nil and type(p.bays) == "number")
    end
    assert(Layouts.Palette("RECON").name == "RECON" and Layouts.Palette("nonsense").name == "INDUSTRIAL")
end)
test("every avionics component names a slot, mass, power and sensor data; slots match the contract", function()
    local count = 0
    for id, c in pairs(Components) do
        if c.class == "avionics" then
            count += 1
            assert(table.find(Avionics.Slots, c.slot) and type(c.mass) == "number" and type(c.powerDraw) == "number" and type(c.sensor) == "table" and c.selectable, id)
            assert(Avionics.Short[id] ~= nil, id)
        end
    end
    assert(count == 5, "five modules, a small catalog")
    assert(Components.AV_RADAR_BASIC.mass == 0 and Components.AV_RADAR_BASIC.powerDraw == 0, "the integrated set rides on the idle bus")
end)
test("the catalog lists only the right modules for each slot and only the frame's packages", function()
    assert(table.concat(Compiler.AvionicsOptions("IF42_BASTION", "radar"), ",") == "AV_RADAR_BASIC,AV_RADAR_ENHANCED")
    assert(table.concat(Compiler.AvionicsOptions("IF42_BASTION", "optics"), ",") == "AV_OPTICS_ZOOM")
    assert(table.concat(Compiler.AvionicsOptions("IF42_BASTION", "thermal"), ",") == "AV_THERMAL")
    assert(table.concat(Compiler.AvionicsOptions("IF42_BASTION", "targeting"), ",") == "AV_TRACKER")
    assert(#Compiler.AvionicsOptions("IF42_BASTION", "bogus") == 0 and #Compiler.AvionicsOptions("NOPE", "radar") == 0)
    assert(table.concat(Compiler.CockpitOptions("IF42_BASTION"), ",") == "CKP_STANDARD,CKP_RECON")
end)

print("Build compilation")
test("factory presets are unchanged: still valid with the same mass and power, standard cockpit, integrated radar", function()
    local expect = { BALANCED = { 39.7, 29 }, ENERGY = { 41.6, 56 }, MISSILE = { 41, 22 }, AUTOCANNON = { 41.7, 30 } }
    for id, e in pairs(expect) do
        local c = compile(Loadouts.presets[id])
        near(c.metrics.mass, e[1], 1e-6, id .. " mass")
        near(c.metrics.powerDraw, e[2], 1e-6, id .. " power")
        assert(c.cockpit.id == "CKP_STANDARD" and c.avionics.installed.radar == "AV_RADAR_BASIC" and not c.avionics.optics and not c.avionics.thermal and not c.avionics.tracker)
        assert(c.label == Compiler.Label(Loadouts.presets[id]) and not string.find(c.label, "STANDARD"), "factory label unchanged")
    end
end)
test("the standard cockpit's integrated radar has the registry numbers; nothing is compiled that the registry does not hold", function()
    local c = compile(Loadouts.presets.BALANCED)
    local r = c.avionics.radar
    near(r.range, 240) near(r.interval, 0.6) near(r.identRange, 150) near(c.avionics.ratedPower, 0)
    assert(c.cockpit.bays == 2 and c.cockpit.baysUsed == 0 and c.stats.radarRange == 240 and c.stats.zoomMax == 1 and c.stats.thermalRange == 0)
end)
test("the recon retrofit adds mass and power, a third bay and the package's sensor bonuses", function()
    local std = compile(with("BALANCED", "CKP_STANDARD", { radar = "AV_RADAR_ENHANCED" }, NO_MISSILE))
    local rec = compile(with("BALANCED", "CKP_RECON", { radar = "AV_RADAR_ENHANCED" }, NO_MISSILE))
    near(rec.metrics.mass - std.metrics.mass, 1.1, 1e-6, "retrofit mass")
    near(rec.metrics.powerDraw - std.metrics.powerDraw, 2, 1e-6, "retrofit power")
    near(std.avionics.radar.range, 400) near(rec.avionics.radar.range, 460) near(std.avionics.radar.interval, 0.25) near(rec.avionics.radar.interval, 0.2)
    assert(rec.cockpit.bays == 3 and std.cockpit.bays == 2 and rec.cockpit.equipment[1] == "RECON_AUX_MONITORS" and #std.cockpit.equipment == 0)
    local full = compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE))
    near(full.avionics.thermal.range, 312) near(full.avionics.tracker.detail, 2) near(full.avionics.mass, 1.1 + 0.9 + 0.5 + 0.9 + 0.6, 1e-6)
    near(full.avionics.ratedPower, 2 + 5 + 1.5 + 8 + 4, 1e-6)
    local std3 = compile(with("BALANCED", "CKP_STANDARD", { radar = "AV_RADAR_ENHANCED", thermal = "AV_THERMAL", targeting = "AV_TRACKER" }, NO_MISSILE))
    assert(std3.avionics.tracker.detail == 1, "the standard cockpit's tracker reports status, not components")
end)
test("avionics mass and rated power enter the same budgets as every other component", function()
    local base = compile(Loadouts.presets.BALANCED)
    local c = compile(with("BALANCED", nil, { radar = "AV_RADAR_BASIC", optics = "AV_OPTICS_ZOOM" }))
    near(c.metrics.mass - base.metrics.mass, 0.5, 1e-6) near(c.metrics.powerDraw - base.metrics.powerDraw, 1.5, 1e-6)
    -- AUTOCANNON is 41.7 of 42 t: the lightest module does not fit until something is dropped
    local over = Compiler.Compile(with("AUTOCANNON", nil, { radar = "AV_RADAR_BASIC", optics = "AV_OPTICS_ZOOM" }))
    assert(not over.valid and over.issues[1] == "Mass limit exceeded" and over.stats.radarRange == 240, "over budget: invalid but the garage still gets the numbers")
    assert(Compiler.Compile(with("AUTOCANNON", nil, { radar = "AV_RADAR_BASIC", optics = "AV_OPTICS_ZOOM" }, { left_shoulder = false })).valid)
    -- the energy preset is 56 of 80 u/s: the whole suite plus the retrofit (20.5) still fits the power budget, only mass stops it
    local e = Compiler.Compile(with("ENERGY", "CKP_RECON", FULL))
    assert(not e.valid and e.issues[1] == "Mass limit exceeded")
end)
test("no package or module is universally better: every upgrade is paid for in mass, power or a bay", function()
    for _, id in ipairs({ "AV_RADAR_ENHANCED", "AV_OPTICS_ZOOM", "AV_THERMAL", "AV_TRACKER" }) do
        assert(Components[id].mass > 0 and Components[id].powerDraw > 0, id)
    end
    assert(Components.CKP_RECON.mass > Components.CKP_STANDARD.mass and Components.CKP_RECON.powerDraw > Components.CKP_STANDARD.powerDraw)
    assert(Components.CKP_RECON.bays > Components.CKP_STANDARD.bays)
end)

print("Compatibility and request validation")
test("bay limits are enforced by the compiler: three modules do not fit the standard interior", function()
    local c = Compiler.Compile(with("BALANCED", "CKP_STANDARD", FULL, NO_MISSILE))
    assert(not c.valid and table.find(c.issues, "Avionics bays exceeded"))
    assert(Compiler.Compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)).valid)
end)
test("a module in the wrong slot, an unknown module or slot and a non-module component are all rejected", function()
    for _, bad in ipairs({ { radar = "AV_THERMAL" }, { thermal = "AV_RADAR_ENHANCED" }, { radar = "NOPE" }, { gimbal = "AV_TRACKER" }, { radar = "W_LASER_RIFLE" }, { radar = 5 } }) do
        assert(not Compiler.Compile(with("BALANCED", nil, bad)).valid, "accepted " .. tostring(next(bad)))
    end
    assert(not Compiler.Compile(with("BALANCED", "CKP_FANCY", nil)).valid and not Compiler.Compile(with("BALANCED", "AV_THERMAL", nil)).valid)
end)
test("hostile requests change nothing: unknown fields, smuggled numbers, wrong types, other chassis equipment", function()
    local base = preset("BALANCED")
    local hostile = {
        { cockpit = "CKP_FANCY" }, { cockpit = 5 }, { cockpit = { "CKP_RECON" } }, { cockpit = string.rep("A", 80) }, { cockpit = "AV_THERMAL" },
        { avionics = "AV_THERMAL" }, { avionics = { thermal = "AV_RADAR_BASIC" } }, { avionics = { radar = "AV_THERMAL" } }, { avionics = { [1] = "AV_TRACKER" } },
        { avionics = { bogus = "AV_TRACKER" } }, { avionics = { radar = true } }, { avionics = { thermal = { range = 9999 } } },
        { radarRange = 9999 }, { avionics = { thermal = "AV_THERMAL" }, powerDraw = 0 }, { cockpit = "CKP_RECON", sensorBonus = { radarRange = 50 } },
        { avionics = {} }, {},
    }
    for i, request in ipairs(hostile) do
        local out = Compiler.ApplyRequest(base, request)
        assert(out == nil, "accepted hostile request " .. i)
    end
    assert(Compiler.ApplyRequest(base, "x") == nil and Compiler.ApplyRequest(base, 5) == nil)
    assert(base.cockpit == nil and base.avionics == nil, "the base loadout is never mutated")
end)
test("legal requests install modules and packages; a package swap that leaves too many modules is refused", function()
    local l = preset("BALANCED")
    l.mounts.left_shoulder = nil
    local a = assert(Compiler.ApplyRequest(l, { cockpit = "CKP_RECON" }))
    assert(a.cockpit == "CKP_RECON" and a.avionics.radar == "AV_RADAR_BASIC")
    local b = assert(Compiler.ApplyRequest(a, { avionics = { thermal = "AV_THERMAL", targeting = "AV_TRACKER", optics = "AV_OPTICS_ZOOM", radar = "AV_RADAR_ENHANCED" } }))
    assert(Compiler.Compile(b).valid)
    local back, why = Compiler.ApplyRequest(b, { cockpit = "CKP_STANDARD" })
    assert(back == nil and why == "AVIONICS BAYS EXCEEDED", tostring(why))
    local trimmed = assert(Compiler.ApplyRequest(b, { avionics = { optics = false } }))
    assert(trimmed.avionics.optics == nil and Compiler.ApplyRequest(trimmed, { cockpit = "CKP_STANDARD" }) ~= nil)
    local none = assert(Compiler.ApplyRequest(l, { avionics = { radar = false } }))
    assert(Compiler.Compile(none).valid and Compiler.Compile(none).avionics.radar == nil, "the radar can be removed; the contract allows an empty slot")
end)
test("weapon, reactor and armour requests keep the cockpit and avionics; presets and the base are never edited", function()
    local l = preset("BALANCED")
    l.mounts.left_shoulder = nil
    local a = assert(Compiler.ApplyRequest(l, { cockpit = "CKP_RECON", avionics = { thermal = "AV_THERMAL" } }))
    local b = assert(Compiler.ApplyRequest(a, { systems = { reactor = "CORE_260" }, mounts = { right_arm = "W_LASER_RIFLE" } }))
    assert(b.cockpit == "CKP_RECON" and b.avionics.thermal == "AV_THERMAL" and b.avionics.radar == "AV_RADAR_BASIC" and b.systems.reactor == "CORE_260")
    assert(Loadouts.presets.BALANCED.cockpit == nil and Loadouts.presets.BALANCED.avionics == nil)
    local c = Compiler.Clone(b)
    c.avionics.thermal = nil
    assert(b.avionics.thermal == "AV_THERMAL", "clone is deep")
end)
test("Same compares cockpit equipment and treats a missing map as the factory equipment", function()
    local a, b = preset("BALANCED"), preset("BALANCED")
    assert(Compiler.Same(a, b))
    b.cockpit, b.avionics = "CKP_STANDARD", { radar = "AV_RADAR_BASIC" }
    assert(Compiler.Same(a, b), "explicit factory equipment equals the implicit one")
    b.avionics.optics = "AV_OPTICS_ZOOM"
    assert(not Compiler.Same(a, b))
    b.avionics.optics = nil
    b.cockpit = "CKP_RECON"
    assert(not Compiler.Same(a, b))
end)
test("labels name non-factory cockpit equipment and leave factory labels alone", function()
    local l = with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)
    local label = Compiler.Label(l)
    assert(string.find(label, "| RECON RS-9 OP-2 TI-3 TC-1", 1, true), label)
    assert(string.find(Compiler.Label(with("BALANCED", nil, { radar = "AV_RADAR_BASIC", thermal = "AV_THERMAL" })), "STANDARD RS-4 TI-3", 1, true))
    assert(not string.find(Compiler.Label(preset("BALANCED")), "|%s*[A-Z]+%s+RS"))
end)

print("Radar contact model")
local function actor(id, x, z, extra)
    local a = { id = id, kind = "VEHICLE", label = id, arch = "SENTRY", x = x, y = 0, z = z, yaw = 0, speed = 0, operational = true, disabled = false, destroyed = false }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local OBS = { x = 0, y = 0, z = 0, yaw = 0 }
local function radarOf(loadout, factor, health)
    return Avionics.Capability(compile(loadout).avionics, factor, health).radar
end
local BASIC = radarOf(preset("BALANCED"))
local ENH = radarOf(with("BALANCED", nil, { radar = "AV_RADAR_ENHANCED" }, NO_MISSILE))
local clear = function() return 0 end

test("contact validation accepts the shared target contract and rejects malformed actors", function()
    assert(Contract.Validate(actor("T-01", 1, 2)))
    assert(not Contract.Validate({}) and not Contract.Validate(actor("", 1, 2)) and not Contract.Validate(actor("T", 0 / 0, 2)))
    local bad = actor("T-09", 1, 2); bad.kind = "BLIMP"
    assert(not Contract.Validate(bad))
    assert(Contract.Band(1) == "NOMINAL" and Contract.Band(0.5) == "DAMAGED" and Contract.Band(0.2) == "CRITICAL" and Contract.Band(0) == "OFFLINE" and Contract.Band(0.9, true) == "OFFLINE")
end)
test("detection range: inside is a contact, outside is nothing; bearing is clockwise from north and distance is exact to the resolution", function()
    local t = Sensors.New()
    Sensors.Scan(t, BASIC, OBS, { actor("N", 0, -100), actor("E", 100, 0), actor("S", 0, 100), actor("W", -100, 0), actor("far", 0, -300) }, 10, clear)
    local list = Sensors.List(t, 10)
    assert(#list == 4, "the 300 st machine is beyond the 240 st set: " .. #list)
    local by = {}
    for _, c in ipairs(list) do by[c.name or c.key] = c end
    near(by.N.bearing, 0) near(by.E.bearing, 90) near(by.S.bearing, 180) near(by.W.bearing, 270)
    near(by.N.distance, 100)
    local t2 = Sensors.New()
    Sensors.Scan(t2, ENH, OBS, { actor("far", 0, -390) }, 10, clear)
    assert(#Sensors.List(t2, 5) == 1, "the wide-area set reaches 390 st")
end)
test("resolution: the coarse set snaps range to 5 st and bearing to 3 deg, the fine set does not", function()
    local a = actor("T", 37.3, -81.2)
    local t = Sensors.New()
    Sensors.Scan(t, BASIC, OBS, { a }, 1, clear)
    local c = Sensors.List(t, 1)[1]
    assert(c.distance % 5 == 0 and c.bearing % 3 == 0, string.format("%f %f", c.distance, c.bearing))
    local t2 = Sensors.New()
    Sensors.Scan(t2, ENH, OBS, { a }, 1, clear)
    local f = Sensors.List(t2, 1)[1]
    near(f.distance, math.floor(math.sqrt(37.3 ^ 2 + 81.2 ^ 2) + 0.5), 1e-6) assert(f.bearing % 1 == 0)
    assert(c.heading == nil and f.heading ~= nil, "only the enhanced set reports heading")
end)
test("bearing and distance follow the actors: a moved actor and a rotated observer give the geometry back", function()
    local t = Sensors.New()
    local a = actor("T", 60, -80)
    Sensors.Scan(t, ENH, OBS, { a }, 1, clear)
    local first = table.clone(Sensors.List(t, 1)[1])
    a.x, a.z = -60, -80
    Sensors.Scan(t, ENH, OBS, { a }, 1.3, clear)
    local second = Sensors.List(t, 1)[1]
    near(first.bearing, 37) near(second.bearing, 323) near(first.key, second.key, 0, "same contact")
    -- bearings are absolute: the display subtracts the mech's own heading, which Wrap handles around north
    near(Sensors.Wrap(first.bearing - 330), 67, 1e-6) near(Sensors.Wrap(second.bearing - 30), -67, 1e-6) near(Sensors.Wrap(10 - 350), 20, 1e-6)
    local b, d = Sensors.Polar(10, 5, 10, 10, 5, -10)
    near(b, 0) near(d, 20)
    b, d = Sensors.Polar(0, 0, 0, -3, 0, 0)
    near(b, 270)
end)
test("obstruction: a machine behind one structure is hidden at a range where an exposed one is seen", function()
    local t = Sensors.New()
    local list = { actor("behind", 0, -200), actor("open", 0, 140) }
    local blockers = function(a) return if a.id == "behind" then 1 else 0 end
    Sensors.Scan(t, BASIC, OBS, list, 1, blockers)
    local seen = Sensors.List(t, 5)
    assert(#seen == 1 and seen[1].name == "open", "240 st set, one wall: reach 168 st, the machine 200 st away behind it is not shown")
end)
test("obstruction numbers: 150 st behind one wall is visible to the basic set, 190 st is not; two walls cut further; the fine set copes better", function()
    local function seen(radar, dist, walls)
        local t = Sensors.New()
        Sensors.Scan(t, radar, OBS, { actor("x", 0, -dist) }, 1, function() return walls end)
        return #Sensors.List(t, 2) == 1
    end
    near(Sensors.EffectiveRange(BASIC, 0), 240) near(Sensors.EffectiveRange(BASIC, 1), 168) near(Sensors.EffectiveRange(BASIC, 2), 96) near(Sensors.EffectiveRange(BASIC, 5), 96)
    assert(seen(BASIC, 150, 1) and not seen(BASIC, 190, 1) and not seen(BASIC, 120, 2) and seen(BASIC, 90, 2) and seen(BASIC, 200, 0))
    assert(seen(ENH, 280, 1) and not seen(BASIC, 280, 0) and seen(ENH, 380, 0) and not seen(ENH, 380, 2))
end)
test("identification needs range: far contacts are classified only; an opaque key never carries the name", function()
    local t = Sensors.New()
    Sensors.Scan(t, BASIC, OBS, { actor("T-01", 0, -100), actor("T-02", 0, -220, { arch = "HEAVY" }) }, 1, clear)
    local list = Sensors.List(t, 5)
    assert(list[1].name == "T-01" and list[1].arch == "SENTRY" and list[1].identified)
    assert(list[2].name == nil and list[2].arch == nil and not list[2].identified and list[2].kind == "VEHICLE")
    assert(type(list[1].key) == "number" and list[1].key ~= list[2].key)
    Sensors.Scan(t, BASIC, OBS, { actor("T-01", 0, -100), actor("T-02", 0, -120, { arch = "HEAVY" }) }, 2, clear)
    assert(Sensors.List(t, 5)[2].name == "T-02", "approaching identifies the same contact")
end)
test("contact ageing: a lost return goes stale, then disappears; a new return revives the same contact", function()
    local t = Sensors.New()
    local a = actor("T", 0, -100)
    Sensors.Scan(t, BASIC, OBS, { a }, 10, clear)
    local key = Sensors.List(t, 1)[1].key
    a.z = -400
    Sensors.Scan(t, BASIC, OBS, { a }, 10.6, clear)
    local c = Sensors.List(t, 1)[1]
    assert(c and not c.stale and c.age > 0.5 and c.key == key, "0.6 s old is still fresh")
    Sensors.Scan(t, BASIC, OBS, { a }, 12, clear)
    assert(Sensors.List(t, 1)[1].stale, "2 s without a return is stale")
    Sensors.Expire(t, BASIC, 15)
    assert(Sensors.List(t, 1)[1].stale)
    Sensors.Expire(t, BASIC, 16.5)
    assert(#Sensors.List(t, 1) == 0, "6 s: dropped")
    a.z = -100
    Sensors.Scan(t, BASIC, OBS, { a }, 20, clear)
    assert(#Sensors.List(t, 1) == 1)
    -- the enhanced set holds contacts longer but flags them stale sooner
    assert(ENH.lost > BASIC.lost and ENH.stale < BASIC.stale)
end)
test("a vanished actor stops returning and its contact ages out; a removed radar still expires contacts", function()
    local t = Sensors.New()
    Sensors.Scan(t, BASIC, OBS, { actor("T", 0, -100) }, 1, clear)
    Sensors.Scan(t, BASIC, OBS, {}, 1.5, clear)
    assert(#Sensors.List(t, 5) == 0, "removed from the world: gone at the next scan")
    Sensors.Scan(t, BASIC, OBS, { actor("T", 0, -100) }, 2, clear)
    Sensors.Expire(t, BASIC, 100)
    assert(#Sensors.List(t, 5) == 0)
end)
test("disabled and destroyed machines stay on the display with their status, then clear after the hold and do not come back", function()
    local t = Sensors.New()
    local a = actor("T", 0, -100)
    Sensors.Scan(t, BASIC, OBS, { a }, 1, clear)
    assert(Sensors.List(t, 1)[1].status == "ACTIVE")
    a.operational, a.disabled = false, true
    Sensors.Scan(t, BASIC, OBS, { a }, 2, clear)
    assert(Sensors.List(t, 1)[1].status == "DISABLED")
    a.destroyed = true
    Sensors.Scan(t, BASIC, OBS, { a }, 3, clear)
    assert(Sensors.List(t, 1)[1].status == "DESTROYED")
    Sensors.Scan(t, BASIC, OBS, { a }, 3 + BASIC.wreckHold - 1, clear)
    assert(#Sensors.List(t, 1) == 1)
    Sensors.Scan(t, BASIC, OBS, { a }, 3 + BASIC.wreckHold + 1, clear)
    assert(#Sensors.List(t, 1) == 0, "wreck cleared")
    Sensors.Scan(t, BASIC, OBS, { a }, 60, clear)
    assert(#Sensors.List(t, 1) == 0, "a standing wreck is not re-acquired")
    local fresh = actor("T", 0, -100)
    Sensors.Scan(t, BASIC, OBS, { fresh }, 70, clear)
    assert(#Sensors.List(t, 1) == 1 and Sensors.List(t, 1)[1].status == "ACTIVE", "a rebuilt machine is a new contact")
end)
test("movement is reported; the list is nearest first and bounded; reset restarts the keys", function()
    local t = Sensors.New()
    local list = {}
    for i = 1, 12 do table.insert(list, actor("T" .. i, 0, -(20 + i * 10), { speed = if i == 3 then 5 else 0 })) end
    Sensors.Scan(t, ENH, OBS, list, 1, clear)
    local out = Sensors.List(t, 8)
    assert(#out == 8 and out[1].distance < out[2].distance and out[8].distance < out[8].distance + 1)
    local moving = 0
    for _, c in ipairs(Sensors.List(t, 12)) do if c.moving then moving += 1 end end
    assert(moving == 1)
    Sensors.Reset(t)
    assert(#Sensors.List(t, 8) == 0)
    Sensors.Scan(t, ENH, OBS, { actor("T1", 0, -50) }, 2, clear)
    assert(Sensors.List(t, 1)[1].key == 1)
end)

print("Capability under power starvation and damage")
test("full power: the enhanced set, thermal imager and tracker work at registry strength", function()
    local spec = compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)).avionics
    local cap = Avionics.Capability(spec, 1, 1)
    assert(cap.radar.state == "ONLINE" and cap.radar.mode == "ENHANCED" and cap.thermal.available and cap.tracker.available and cap.tracker.detail == 2 and cap.stabilized)
    near(cap.radar.range, 460) near(cap.radar.interval, 0.2)
end)
test("starved of power: the enhanced radar falls back to the basic set, thermal goes dark, the tracker loses enhanced capability; the basic radar never stops", function()
    local spec = compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)).avionics
    local half = Avionics.Capability(spec, 0.45, 1)
    assert(half.radar.mode == "BASIC" and half.radar.state == "DEGRADED" and half.radar.range < 460 and half.radar.interval > 0.4, "RS-9 falls back to RS-4 numbers")
    assert(not half.thermal.available and half.thermal.reason == "NO POWER" and half.tracker.available and half.tracker.detail == 0 and half.tracker.degraded)
    local dead = Avionics.Capability(spec, 0, 1)
    assert(dead.radar and dead.radar.mode == "BASIC" and dead.radar.range > 200, "essential instrumentation is still there with no avionics power")
    assert(not dead.tracker.available and not dead.thermal.available and not dead.stabilized)
    local basic = Avionics.Capability(compile(preset("BALANCED")).avionics, 0, 1)
    assert(basic.radar.state == "ONLINE" and basic.radar.range == 240, "the integrated set draws nothing and is unaffected by the avionics bus")
end)
test("sensor mast damage: reach shrinks, then the thermal imager and the tracker's analysis are lost", function()
    local spec = compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)).avionics
    local ok, hurt, crit = Avionics.Capability(spec, 1, 1), Avionics.Capability(spec, 1, 0.5), Avionics.Capability(spec, 1, 0.2)
    near(hurt.radar.range, ok.radar.range * 0.85) near(crit.radar.range, ok.radar.range * 0.6)
    assert(hurt.thermal.available and not crit.thermal.available and crit.thermal.reason == "SENSOR DAMAGE" and crit.tracker.detail == 0 and hurt.tracker.detail == 2)
    assert(crit.radar.interval > ok.radar.interval and crit.radar.state == "DEGRADED")
end)
test("run-time demand follows the modes and never exceeds the rated power", function()
    local spec = compile(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE)).avionics
    local idle = Avionics.Demand(spec, { zoomIndex = 1, thermalOn = false, locked = false })
    local busy = Avionics.Demand(spec, { zoomIndex = 3, thermalOn = true, locked = true })
    near(busy, spec.ratedPower, 1e-6) assert(idle < busy and idle > 0)
    near(idle, 2 + 5 + 0.4 + 0.8 + 1, 1e-6)
    assert(Avionics.Demand(compile(preset("BALANCED")).avionics, { zoomIndex = 1 }) == 0, "the factory set costs nothing")
    assert(Avionics.Demand(nil, {}) == 0)
end)

print("Energy ledger with the avionics load")
local function ledger(loadout, reactorScale)
    local compiled = compile(loadout)
    local cfg = table.clone(compiled.energy)
    cfg.output *= reactorScale or 1
    local e = Energy.New(cfg)
    Energy.SetPolicy(e, Profiles.Policy(Profiles.New("BALANCED")))
    return e, cfg, compiled
end
local function run(e, seconds, requests)
    local dt = 1 / 30
    local delivered, wanted = 0, 0
    for _ = 1, math.floor(seconds / dt) do
        for key, rate in pairs(requests) do Energy.Request(e, key, rate) end
        Energy.Advance(e, dt, true)
        delivered += (e.delivered.avionics or 0) * dt
        wanted += (requests.avionics or 0) * dt
    end
    return if wanted > 0 then delivered / wanted else 1
end
test("on a healthy reactor the whole suite is served and the capacitor stays full", function()
    local e, _, c = ledger(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE))
    local demand = Avionics.Demand(c.avionics, { zoomIndex = 3, thermalOn = true, locked = true })
    local factor = run(e, 10, { idle = 8, propulsion = 20, avionics = demand })
    assert(factor > 0.999, tostring(factor))
    assert(e.charge > e.config.capacity * 0.99)
end)
test("avionics are the lowest priority: with the reactor starved propulsion keeps its full supply and the sensors take the loss", function()
    local e, _, c = ledger(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE), 0.4)
    local demand = Avionics.Demand(c.avionics, { zoomIndex = 3, thermalOn = true, locked = true })
    local propulsionServed, ticks = 0, 0
    local dt = 1 / 30
    local delivered, wanted = 0, 0
    for _ = 1, 30 * 40 do
        Energy.Request(e, "idle", 8); Energy.Request(e, "propulsion", 22); Energy.Request(e, "avionics", demand)
        Energy.Advance(e, dt, true)
        propulsionServed += (e.delivered.propulsion or 0) / 22
        ticks += 1
        delivered += (e.delivered.avionics or 0) * dt
        wanted += demand * dt
    end
    assert(propulsionServed / ticks > 0.999, "propulsion is mandatory and always served first")
    assert(delivered / wanted < 0.9 or e.charge < e.config.capacity, "the starved reactor cannot feed everything")
end)
test("the capacitor floor: sensors alone cannot drain the bank the shield needs", function()
    local e, cfg = ledger(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE), 0)
    local demand = 20.5
    for _ = 1, 30 * 60 do
        Energy.Request(e, "avionics", demand)
        Energy.Advance(e, 1 / 30, true)
    end
    assert(e.charge >= cfg.capacity * 0.25 - 0.5, "stopped at the floor: " .. e.charge)
    assert(Energy.Floor.avionics == 0.25 and Energy.Priority.avionics > Energy.Priority.sprint)
    near(Energy.Reserve(e, "avionics"), cfg.capacity * 0.25, 1e-6)
    assert(Energy.Reserve(e, "propulsion") == 0 and Energy.Reserve(e, "idle") == 0, "mandatory loads have no floor")
    assert(Energy.Reserve(e, "shield") == 0, "profile reserves are untouched")
end)
test("profile arbitration is unchanged: weapons and sprint still follow the three profiles when avionics are present", function()
    for _, id in ipairs(Profiles.Order) do
        local e = ledger(with("BALANCED", "CKP_RECON", FULL, NO_MISSILE))
        Energy.SetPolicy(e, Profiles.Policy(Profiles.New(id)))
        for _ = 1, 60 do
            Energy.Request(e, "avionics", 20.5); Energy.Request(e, "weapons", 60); Energy.Request(e, "sprint", 100); Energy.Request(e, "idle", 8); Energy.Request(e, "propulsion", 30)
            Energy.Advance(e, 1 / 30, true)
        end
        assert((e.delivered.propulsion or 0) > 29.9 and (e.delivered.idle or 0) > 7.99, id)
        local l = e.ledger
        assert(math.abs(l.initial + l.generated - l.loss - l.wasted - l.consumed - e.charge) < 1e-3 + l.generated * 1e-6, "energy is conserved: " .. id)
    end
end)

print("Thermal signatures")
test("a running engine is warm, moving is hotter, firing adds a pulse that cools, and nothing exceeds 1", function()
    local m = {}
    local idle = Thermal.Level(m, { powered = true, speed = 0, speedMax = 7 }, 0)
    local moving = Thermal.Level(m, { powered = true, speed = 7, speedMax = 7 }, 1)
    local fired = Thermal.Level(m, { powered = true, speed = 0, speedMax = 7, firedAgo = 0.2 }, 2)
    local later = Thermal.Level(m, { powered = true, speed = 0, speedMax = 7, firedAgo = 5 }, 3)
    assert(idle > 0.4 and moving > idle and fired > idle + 0.25 and later < fired and later >= idle)
    assert(Thermal.Level({}, { powered = true, speed = 99, speedMax = 7, reactorHeat = 1, firedAgo = 0 }, 0) <= 1)
    assert(Thermal.Band(idle) == "WARM" and Thermal.Band(0.9) == "HOT" and Thermal.Band(0.2) == "COOL" and Thermal.Band(0.05) == "COLD")
end)
test("a disabled machine cools by half-life; a burning wreck holds extra heat; an unpowered machine is ambient", function()
    local m = {}
    local running = Thermal.Level(m, { powered = true, speed = 0, speedMax = 7 }, 0)
    local down0 = Thermal.Level(m, { powered = false, speed = 0 }, 10)
    local down28 = Thermal.Level(m, { powered = false, speed = 0 }, 10 + Thermal.COOL_HALF_LIFE)
    local down120 = Thermal.Level(m, { powered = false, speed = 0 }, 130)
    near(down0, running, 1e-9, "starts from the running signature") near(down28, running / 2, 1e-9) assert(down120 < 0.05 * running + 0.03)
    assert(Thermal.Level(m, { powered = false, burning = true, speed = 0 }, 10 + Thermal.COOL_HALF_LIFE) > down28)
    assert(Thermal.Level({}, { powered = false, speed = 0 }, 0) == Thermal.AMBIENT)
    assert(Thermal.Level({}, { powered = false, destroyed = true, speed = 0 }, 0) == Thermal.AMBIENT, "a wreck first seen already dead has no history: cold")
    assert(Thermal.Level(m, { powered = true, destroyed = true, speed = 0 }, 100) < running, "destroyed overrides powered")
    local burn = {}
    Thermal.Level(burn, { powered = true, speed = 0, speedMax = 7 }, 0)
    local b0 = Thermal.Level(burn, { powered = false, burning = true, speed = 0 }, 1)
    assert(Thermal.Level(burn, { powered = false, burning = true, speed = 0 }, 1 + Thermal.BURN_TIME + 1) < b0 - Thermal.BURN + 0.01, "the fire stops adding heat after BURN_TIME")
    assert(Thermal.Level(m, { powered = true, speed = 0, speedMax = 7 }, 200) > 0.4, "a rebuilt machine runs hot again")
end)

print("Zoom, camera lifecycle and field of view")
test("optical magnification is true: tan(fov/2) shrinks m-fold, not the degrees", function()
    near(Avionics.Fov(74, 1), 74)
    local f2, f4 = Avionics.Fov(74, 2), Avionics.Fov(74, 4)
    near(math.tan(math.rad(74 / 2)) / math.tan(math.rad(f2 / 2)), 2, 1e-9) near(math.tan(math.rad(74 / 2)) / math.tan(math.rad(f4 / 2)), 4, 1e-9)
    assert(f4 > 74 / 4 and f2 > 74 / 2, "dividing the degrees would over-zoom")
    assert(Avionics.Fov(74, 0.5) == 74 and Avionics.Fov(74, 1e9) >= 4)
    -- an ultrawide viewport lowers the baseline; the same magnification applies to whatever baseline the camera uses
    near(math.tan(math.rad(60 / 2)) / math.tan(math.rad(Avionics.Fov(60, 4) / 2)), 4, 1e-9)
end)
test("zoom indices clamp to the installed optics: no optics means 1x, never more than the lens offers", function()
    local with_optics = compile(with("BALANCED", nil, { radar = "AV_RADAR_BASIC", optics = "AV_OPTICS_ZOOM" })).avionics
    local without = compile(preset("BALANCED")).avionics
    assert(Avionics.ClampZoom(with_optics, 3) == 3 and Avionics.ClampZoom(with_optics, 9) == 3 and Avionics.ClampZoom(with_optics, -2) == 1 and Avionics.ClampZoom(with_optics, 2.7) == 2)
    assert(Avionics.ClampZoom(without, 3) == 1 and Avionics.ClampZoom(with_optics, "x") == 1 and Avionics.ClampZoom(with_optics, 0 / 0) == 1)
    assert(Avionics.Magnification(with_optics, 2) == 2 and Avionics.Magnification(without, 3) == 1)
end)
test("the zoom controller is smooth, monotone and settles; look sensitivity falls with magnification", function()
    local z = Zoom.New()
    Zoom.SetTarget(z, 4)
    local previous, fovs = 1, {}
    for _ = 1, 120 do
        Zoom.Step(z, 1 / 60)
        assert(z.current >= previous - 1e-9 and z.current <= 4 + 1e-9, "no overshoot")
        previous = z.current
        table.insert(fovs, Zoom.Fov(z, 74))
    end
    near(z.current, 4, 1e-3) assert(fovs[1] < 74 and fovs[#fovs] < fovs[1])
    near(Zoom.LookScale(z), 0.25, 1e-3)
    assert(z.current < 3.9 or Zoom.IsZoomed(z))
end)
test("lifecycle: reset is immediate and complete for every path that must restore the camera", function()
    -- toggling off, switching cameras, garage return, ejection, respawn and a new sortie all call Reset; no field of view survives it
    for _, path in ipairs({ "toggle off", "switch camera", "return to garage", "safe ejection", "respawn", "new sortie" }) do
        local z = Zoom.New()
        Zoom.SetTarget(z, 4)
        for _ = 1, 30 do Zoom.Step(z, 1 / 60) end
        assert(Zoom.IsZoomed(z) and Zoom.Fov(z, 74) < 74)
        Zoom.Reset(z)
        assert(z.current == 1 and z.target == 1 and Zoom.Fov(z, 74) == 74 and Zoom.LookScale(z) == 1 and not Zoom.IsZoomed(z), path)
    end
end)
test("zoom is a view change only: it never appears in any weapon or damage data", function()
    for id, c in pairs(Components) do
        if c.combat then
            for key in pairs(c.combat) do assert(not string.find(string.lower(key), "zoom") and not string.find(string.lower(key), "magnif"), id) end
        end
    end
    local spec = compile(with("BALANCED", nil, { radar = "AV_RADAR_BASIC", optics = "AV_OPTICS_ZOOM" }))
    local plain = compile(preset("BALANCED"))
    for socket, w in pairs(plain.weapons) do
        for k, v in pairs(w) do assert(spec.weapons[socket][k] == v, "weapon " .. socket .. "." .. k .. " differs with optics installed") end
    end
end)

print("Cockpit annunciators")
test("every lamp lights for exactly the condition it names, amber before red, and nothing lights on a healthy deployed machine", function()
    local healthy = { deployed = true, capFraction = 0.9, reactorFraction = 1, reactorFactor = 1, coreFraction = 1, thermal = 20, radarFitted = true, radarState = "ONLINE", impaired = false, armsFailed = 0 }
    local base = Warnings.Evaluate(healthy)
    for _, key in ipairs(Warnings.Keys) do assert(base[key] == 0, key) end
    local function with_(change)
        local v = table.clone(healthy)
        for k, x in pairs(change) do v[k] = x end
        return Warnings.Evaluate(v)
    end
    assert(with_({ capFraction = 0.12 }).CAP == 1 and with_({ capFraction = 0.04 }).CAP == 2)
    assert(with_({ reactorFraction = 0.5 }).RCTR == 1 and with_({ reactorFraction = 0.2 }).RCTR == 2 and with_({ reactorFactor = 0.7 }).RCTR == 1 and with_({ reactorFactor = 0.4 }).RCTR == 2)
    assert(with_({ thermal = 75 }).THRM == 1 and with_({ thermal = 95 }).THRM == 2)
    assert(with_({ armsFailed = 1 }).WPN == 1 and with_({ armsFailed = 2 }).WPN == 2)
    assert(with_({ coreFraction = 0.5 }).CORE == 1 and with_({ coreFraction = 0.2 }).CORE == 2)
    assert(with_({ radarState = "DEGRADED" }).SENS == 1 and with_({ impaired = true }).SENS == 1 and with_({ radarState = "OFFLINE" }).SENS == 2)
    local only = with_({ capFraction = 0.04 })
    assert(only.RCTR == 0 and only.CORE == 0 and only.WPN == 0 and only.SENS == 0 and only.THRM == 0, "one fault, one lamp")
    local docked = Warnings.Evaluate({ deployed = false, capFraction = 0, thermal = 100, radarFitted = true, radarState = "OFFLINE" })
    assert(docked.CAP == 0 and docked.THRM == 0 and docked.SENS == 0, "a stowed machine raises no capacitor, thermal or sensor warnings")
    assert(Warnings.Evaluate({ deployed = true, radarFitted = false, radarState = "NONE" }).SENS == 0, "no radar fitted is not a fault")
end)

print(string.format("avionics_tests: %d passed, %d failed", passed, failed))
if failed > 0 then error("avionics_tests failed") end
