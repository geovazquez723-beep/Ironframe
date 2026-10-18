-- Offline (Luau CLI) tests for the M11B physical combat fidelity rules. Run: luau tools/fidelity_tests.luau
--
-- What is testable without Roblox: which logical component a registered surface point belongs to (TankHit), the fitted compound mech volumes and
-- their ray resolution (VolumeHit), the per-weapon impact recipes (ImpactProfile), and the bounded budgets and ordering of the destruction sequences.
-- What is NOT here (it needs the engine): that the tank hit mesh matches the drawn mesh, and what the effects look like. Those are measured and
-- inspected in Studio (tools/m11b_studio_checks.luau, docs/M11B_PHYSICAL_COMBAT_FIDELITY.md).
local Shared = "../src/ReplicatedStorage/IronframeShared/"
local TankHit = require(Shared .. "TankHit")
local Volume = require(Shared .. "VolumeHit")
local Profile = require(Shared .. "ImpactProfile")
local Damage = require(Shared .. "MechDamage")
local Config = require(Shared .. "DestructionConfig")
local Unit = require(Shared .. "DestructibleState")
local Rules = require(Shared .. "ComponentRules")
local Components = require(Shared .. "ComponentRegistry")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= (tol or 1e-6), string.format("%s: %.5f vs %.5f", what or "value", a, b)) end

-- Identity rotation as the 9 numbers a part would report, and a yaw rotation about +Y.
local function part(name, joint, group, shape, size, x, y, z, yaw)
    local c, s = math.cos(yaw or 0), math.sin(yaw or 0)
    return { name = name, joint = joint, group = group, shape = shape, size = size, m = { x, y, z, c, 0, s, 0, 1, 0, -s, 0, c } }
end

print("TankHit (which component owns a surface point)")
test("the rear upper deck of the hull mesh is the ENGINE; everything else on the hull is HULL", function()
    assert(TankHit.HullComponent(8.5, 9) == "ENGINE", "rear deck")
    assert(TankHit.HullComponent(7.9, 10.5) == "ENGINE", "engine louvres")
    assert(TankHit.HullComponent(7.2, 12.7) == "ENGINE", "upper rear plate")
    assert(TankHit.HullComponent(4.0, 12.7) == "HULL", "lower rear plate")
    assert(TankHit.HullComponent(6.6, -3) == "HULL", "front deck")
    assert(TankHit.HullComponent(6.0, 1.0) == "ENGINE" and TankHit.HullComponent(5.99, 1.0) == "HULL" and TankHit.HullComponent(6.0, 0.99) == "HULL", "exact boundaries")
end)
test("every component loss has a distinct cosmetic failure event and the damage-presentation instance budget is bounded", function()
    for _, comp in ipairs({ "HULL", "TURRET", "TRACK_L", "TRACK_R", "ENGINE" }) do
        assert(TankHit.FailureEvent[comp], comp)
    end
    assert(TankHit.FailureEvent.TRACK_L ~= TankHit.FailureEvent.TURRET and TankHit.FailureEvent.TURRET ~= TankHit.FailureEvent.HULL)
    for key, value in pairs(TankHit.Limits) do
        assert(value > 0, key)
    end
    assert(TankHit.MaxParts() <= 100, "worst-case welded damage parts per tank: " .. TankHit.MaxParts())
end)
test("the hull destruction sequence is ordered (failure, turret thrown, cook-offs, wreck) and finishes inside two seconds", function()
    local h = TankHit.Sequence.HULL
    assert(0 < h.turretThrow and h.turretThrow < h.cookoff1 and h.cookoff1 < h.cookoff2 and h.cookoff2 <= h.plates and h.plates < h.wreck, "order")
    assert(h.wreck + h.animate <= 2.0, "total")
    assert(TankHit.Sequence.TRACK.animate <= 1 and TankHit.Sequence.TURRET.animate <= 1)
end)

print("Tank components (damage stays with the component that was struck)")
local function newTank()
    return {
        HULL = Unit.New({ material = "VEHICLE_HULL" }), TURRET = Unit.New({ material = "VEHICLE_TURRET" }),
        TRACK_L = Unit.New({ material = "VEHICLE_TRACK" }), TRACK_R = Unit.New({ material = "VEHICLE_TRACK" }), ENGINE = Unit.New({ material = "VEHICLE_ENGINE" }),
    }
end
test("a hit resolved to one component damages only that component (per-component damage)", function()
    for _, comp in ipairs({ "HULL", "TURRET", "TRACK_L", "TRACK_R", "ENGINE" }) do
        local units = newTank()
        local dealt = Unit.Hit(units[comp], "HEAVY", 25)
        assert(dealt > 0, comp)
        for name, u in pairs(units) do
            if name ~= comp then
                assert(u.health == u.capacity and u.hits == 0, comp .. " hit damaged " .. name)
            end
        end
    end
end)
test("a hull-mesh hit on the rear deck damages the ENGINE and leaves the HULL intact; a lower plate does the reverse", function()
    local units = newTank()
    local deck = TankHit.HullComponent(8.2, 7)
    Unit.Hit(units[deck], "MG", 8)
    assert(units.ENGINE.hits == 1 and units.HULL.hits == 0)
    local plate = TankHit.HullComponent(3.5, 12)
    Unit.Hit(units[plate], "MG", 8)
    assert(units.HULL.hits == 1 and units.ENGINE.hits == 1)
end)
test("destroyed components keep their consequences: tracks and engine immobilise, the turret stops firing, the hull ends the vehicle", function()
    local units = newTank()
    Unit.Destroy(units.TRACK_R)
    local s = Rules.Tank(units)
    assert(not s.mobile and s.turretOperational and not s.destroyed, "track")
    units = newTank()
    Unit.Destroy(units.TURRET)
    s = Rules.Tank(units)
    assert(s.mobile and not s.turretOperational, "turret")
    units = newTank()
    Unit.Destroy(units.ENGINE)
    assert(not Rules.Tank(units).mobile)
    units = newTank()
    Unit.Destroy(units.HULL)
    s = Rules.Tank(units)
    assert(s.destroyed and not s.mobile and not s.turretOperational, "hull")
end)
test("a reset restores every component (reset and rebuild)", function()
    local units = newTank()
    for _, u in pairs(units) do
        Unit.Destroy(u)
    end
    for _, u in pairs(units) do
        Unit.Reset(u)
    end
    local s = Rules.Tank(units)
    assert(s.mobile and s.turretOperational and not s.destroyed and s.status == "OPERATIONAL")
end)

print("ImpactProfile (the weapons must look and sound different)")
local FAMILIES = { "HULL", "TURRET", "TRACK_L", "ENGINE", "CORE", "ARM_L", "LEG_R", "REACTOR" }
test("visual weight ranks MG < LASER < HEAVY on every component, and the Mauler is several times the machine gun", function()
    for _, comp in ipairs(FAMILIES) do
        local mg, lr, hmg = Profile.For("MG", comp), Profile.For("LASER", comp), Profile.For("HEAVY", comp)
        assert(mg.weight < lr.weight and lr.weight < hmg.weight, comp)
        assert(hmg.weight >= 3 * mg.weight, comp .. " heavy vs mg " .. hmg.weight .. " / " .. mg.weight)
    end
end)
test("a machine-gun round is not artillery: no shock ring, no fragments, no chips, no smoke on any component", function()
    for _, comp in ipairs(FAMILIES) do
        local r = Profile.For("MG", comp)
        assert(r.shock == 0 and r.fragments == 0 and r.chips == 0, comp)
        assert(r.smoke <= (if comp == "ENGINE" or comp == "REACTOR" then 1 else 0), comp)
        assert(r.sparks <= 8 and r.flash <= 1.5, comp)
        assert(r.directional, "MG sparks follow the reflected path")
    end
end)
test("the laser is precise and energy-intensive: a hot glowing mark that lingers, fine fast sparks, a wisp of smoke, an energy sizzle", function()
    local lr, mg, hmg = Profile.For("LASER", "HULL"), Profile.For("MG", "HULL"), Profile.For("HEAVY", "HULL")
    assert(lr.glow and lr.mark and lr.mark < hmg.mark, "molten mark, smaller than a Mauler crater")
    assert(lr.light.decay < mg.light.decay and lr.light.decay < hmg.light.decay, "its light lingers longer than either")
    assert(lr.sparkSpeed > mg.sparkSpeed and lr.sparkSize < hmg.sparkSize, "fine, fast sparks")
    assert(lr.smoke >= 1 and lr.fragments == 0 and lr.shock == 0)
    assert(lr.sound.name == "laserSizzle" and mg.sound.name ~= lr.sound.name)
end)
test("the Mauler is materially destructive: shock ring, plate fragments, chips, a crater and a low heavy thud", function()
    local r, mg = Profile.For("HEAVY", "HULL"), Profile.For("MG", "HULL")
    assert(r.shock > 0 and r.fragments >= 3 and r.chips >= 8 and r.mark and r.mark >= 2.5 and r.flash >= 5)
    assert(r.sound.pitch < mg.sound.pitch and r.sound.volume > mg.sound.volume, "lower and louder")
    assert(r.sound2 and r.sound2.name == "explosion")
    assert(r.shake > 0 and r.shake <= 1, "a hit reaction exists but is bounded (no exaggerated screen shake)")
end)
test("component modifiers: tracks kick up dirt, the engine and reactor arc, the reactor vents steam, turrets ring with sparks", function()
    assert(Profile.For("MG", "TRACK_L").dust > Profile.For("MG", "HULL").dust)
    assert(Profile.For("HEAVY", "TRACK_R").dust > Profile.For("HEAVY", "HULL").dust)
    assert(Profile.For("LASER", "ENGINE").arcs > 0 and Profile.For("LASER", "HULL").arcs == 0)
    assert(Profile.For("HEAVY", "REACTOR").steam and not Profile.For("HEAVY", "CORE").steam)
    assert(Profile.For("HEAVY", "TURRET").sparks > Profile.For("HEAVY", "HULL").sparks)
    assert(Profile.FamilyOf("TRACK_L") == "TRACK" and Profile.FamilyOf("ARM_R") == "ARM" and Profile.FamilyOf("LEG_L") == "LEG" and Profile.FamilyOf("nonsense") == "HULL")
end)
test("every effect count is bounded for every weapon class and component (pools are sized from these)", function()
    local L = Profile.Limits
    for _, class in ipairs(Profile.Classes) do
        for _, comp in ipairs(FAMILIES) do
            local r = Profile.For(class, comp)
            assert(r.sparks <= L.sparks and r.chips <= L.chips and r.dust <= L.dust and r.smoke <= L.smoke and r.fragments <= L.fragments and r.arcs <= L.arcs, class .. " " .. comp)
        end
    end
    assert(Profile.For("PLASMA", "HULL").class == "MG", "an unknown class degrades to the lightest recipe, never to a heavy one")
end)
test("different projectile types: the real weapons and the tank cannon map to the intended classes", function()
    assert(Config.WeaponClass("W_MACHINE_GUN") == "MG" and Config.WeaponClass("W_LASER_RIFLE") == "LASER" and Config.WeaponClass("W_HMG_MAULER") == "HEAVY")
    assert(Config.WeaponClass("TANK_CANNON") == "HEAVY", "tank shells hit like the Mauler")
    assert(Profile.MarkClass("MG") == "pit" and Profile.MarkClass("LASER") == "burn" and Profile.MarkClass("HEAVY") == "crater")
    -- weapon numbers are untouched by M11B
    local mg, lr, hmg = Components.W_MACHINE_GUN.combat, Components.W_LASER_RIFLE.combat, Components.W_HMG_MAULER.combat
    assert(mg.damage == 8 and lr.damage == 25 and hmg.damage == 25 and mg.interval == 0.1 and lr.interval == 0.25)
end)
test("sparks reflect off the surface: unit length is preserved and a head-on round returns along its path", function()
    local rx, ry, rz = Profile.Reflect(0, 0, 1, 0, 0, -1)
    near(rx, 0) near(ry, 0) near(rz, -1)
    local ax, ay, az = Profile.Reflect(0.6, -0.8, 0, 0, 1, 0)
    near(math.sqrt(ax * ax + ay * ay + az * az), 1, 1e-9, "length")
    assert(ay > 0)
    near(ax, 0.6, 1e-9, "x preserved")
end)

print("VolumeHit (fitted compound volumes: where a shot lands)")
-- A small synthetic mech in the chassis frame: a torso block, a left pauldron, a left arm weapon, a leg and decoration that must be ignored.
local function synthetic()
    return {
        part("TorsoCore", "Torso", "frame", "Block", { 4, 4, 3 }, 0, 6, 0),
        part("PauldronL", "Torso", "armor", "Block", { 2, 1.5, 2.5 }, -3.5, 8.2, 0),
        part("PauldronR", "Torso", "armor", "Block", { 2, 1.5, 2.5 }, 3.5, 8.2, 0),
        part("Weapon_left_arm_Receiver", "ElbowL", "weapon", "Block", { 0.9, 1, 2.4 }, -5, 5, -2),
        part("ThighL", "ThighL", "frame", "Block", { 1.6, 3, 1.6 }, -1.5, 2.5, 0),
        part("ReactorCore", "Torso", "reactor", "Cylinder", { 2, 2.4, 2.4 }, 0, 6, 2.6),
        part("RigRoot", "Root", "frame", "Block", { 1, 1, 1 }, 0, 0, 0),
        part("Hyd_A_Rod", "Torso", "hydraulic", "Block", { 0.3, 3, 0.3 }, -2, 4, 1),
        part("Glow1", "Torso", "glow", "Block", { 1, 0.2, 0.2 }, 0, 7, -1.6),
        part("Bolt", "Torso", "detail", "Block", { 0.2, 0.2, 0.2 }, 1, 7, -1.6),
        part("Standoff", "Torso", "frame", "Block", { 0.3, 0.3, 0.3 }, 1, 6, -1.6),
    }
end
test("fitting keeps armour, frame, joint, reactor and weapon parts of useful size and drops decoration, greeble and the rig root", function()
    local fit = Volume.Fit(synthetic())
    assert(#fit.boxes == 6 and fit.dropped == 5, "boxes " .. #fit.boxes .. " dropped " .. fit.dropped)
    for _, b in ipairs(fit.boxes) do
        assert(b.name ~= "RigRoot" and b.name ~= "Hyd_A_Rod" and b.name ~= "Glow1" and b.name ~= "Bolt" and b.name ~= "Standoff", b.name)
    end
end)
test("boxes are classified into the damage regions the game already uses", function()
    local fit = Volume.Fit(synthetic())
    local region = {}
    for _, b in ipairs(fit.boxes) do
        region[b.name] = b.region
    end
    assert(region.TorsoCore == "CORE" and region.ThighL == "LEG_L" and region.ReactorCore == "REACTOR", "core / leg / reactor")
    assert(region.PauldronL == "ARM_L" and region.PauldronR == "ARM_R", "shoulder armour is sided by position")
    assert(region.Weapon_left_arm_Receiver == "ARM_L", "weapon assemblies belong to their arm")
    assert(fit.counts.ARM_L == 2 and fit.counts.CORE == 1)
end)
test("rounded shapes shrink so a box does not claim the empty corners of a cylinder", function()
    local fit = Volume.Fit(synthetic())
    for _, b in ipairs(fit.boxes) do
        if b.name == "ReactorCore" then
            near(b.h[1], 1.0, 1e-9, "axis") near(b.h[2], 1.2 * 0.9, 1e-9, "radius y") near(b.h[3], 1.2 * 0.9, 1e-9, "radius z")
        end
        if b.name == "TorsoCore" then
            near(b.h[1], 2, 1e-9) near(b.h[2], 2, 1e-9) near(b.h[3], 1.5, 1e-9)
        end
    end
end)
test("alignment: a ray aimed at the middle of each visible face lands exactly on it, and a ray just beside the part misses (near-miss rejection)", function()
    local parts = synthetic()
    local fit = Volume.Fit(parts)
    for _, b in ipairs(fit.boxes) do
        if b.name == "TorsoCore" or b.name == "ThighL" or b.name == "PauldronR" then
            -- along -Z from the front: the front face is at c.z - h.z
            local r = Volume.Ray({ b }, nil, b.c[1], b.c[2], b.c[3] - 20, 0, 0, 1, 40)
            assert(r, b.name)
            near(r.t, 20 - b.h[3], 1e-9, b.name .. " front face distance")
            near(r.nz, -1, 1e-9) near(r.nx, 0, 1e-9)
            local beside = Volume.Ray({ b }, nil, b.c[1] + b.h[1] + 0.3, b.c[2], b.c[3] - 20, 0, 0, 1, 40)
            assert(beside == nil, b.name .. " 0.3 studs outside the edge must miss")
            local above = Volume.Ray({ b }, nil, b.c[1], b.c[2] + b.h[2] + 0.3, b.c[3] - 20, 0, 0, 1, 40)
            assert(above == nil, b.name .. " 0.3 studs above must miss")
        end
    end
end)
test("empty space between the limbs is empty: a ray through the gap between torso and thigh passes", function()
    local fit = Volume.Fit(synthetic())
    -- below the torso (y 4..8) and beside the thigh (x -2.3..-0.7): clear air
    local clear = Volume.Ray(fit.boxes, Volume.Bounds(fit.boxes), 0.5, 2.0, -30, 0, 0, 1, 60)
    assert(clear == nil, "air under the torso and beside the thigh must not register")
end)
test("first legitimate surface: overlapping volumes of different regions report the nearest only, once", function()
    local fit = Volume.Fit(synthetic())
    local bounds = Volume.Bounds(fit.boxes)
    -- A ray from the front at the shoulder height meets the left pauldron box (ARM_L) before the torso behind it.
    local hit = Volume.Ray(fit.boxes, bounds, -3.5, 8.2, -30, 0, 0, 1, 80)
    assert(hit and hit.region == "ARM_L", hit and hit.region)
    -- Applying it is ONE damage application on ONE region (plus the model's own spill), never two region hits for one round.
    local state = Damage.New()
    local result = Damage.Apply(state, hit.region, 20)
    assert(result.applied.ARM_L == 20 and result.applied.LEG_L == nil and result.applied.REACTOR == nil)
    -- And from above the shoulder gap the torso is hit instead.
    local top = Volume.Ray(fit.boxes, bounds, 0, 30, 0, 0, -1, 0, 60)
    assert(top and top.region == "CORE", top and top.region)
end)
test("cover: a surface nearer than the volume stops the shot (the probe is limited to the world hit distance)", function()
    local fit = Volume.Fit(synthetic())
    local bounds = Volume.Bounds(fit.boxes)
    local free = Volume.Ray(fit.boxes, bounds, 0, 6, -40, 0, 0, 1, 100)
    assert(free and free.t > 30)
    assert(Volume.Ray(fit.boxes, bounds, 0, 6, -40, 0, 0, 1, free.t - 0.01) == nil, "wall 0.01 short of the armour blocks it")
    assert(Volume.Ray(fit.boxes, bounds, 0, 6, -40, 0, 0, 1, free.t + 0.01) ~= nil, "wall just behind the armour does not")
end)
test("swept shells: a shell radius widens every volume; a start inside a volume is a contact at the origin", function()
    local fit = Volume.Fit({ part("Block", "Torso", "frame", "Block", { 4, 4, 4 }, 0, 0, 0) })
    assert(Volume.Ray(fit.boxes, nil, 2.6, 0, -10, 0, 0, 1, 20, 0) == nil, "0.6 outside: a hitscan ray misses")
    assert(Volume.Ray(fit.boxes, nil, 2.6, 0, -10, 0, 0, 1, 20, 0.9) ~= nil, "a 0.9 radius shell grazes it")
    local inside = Volume.Ray(fit.boxes, nil, 0, 0, 0, 0, 0, 1, 20)
    assert(inside and inside.t == 0)
end)
test("rotated volumes: a box yawed 45 degrees is hit on its rotated face with a rotated normal", function()
    local fit = Volume.Fit({ part("Block", "Torso", "frame", "Block", { 4, 4, 4 }, 0, 0, 0, math.rad(45)) })
    local r = Volume.Ray(fit.boxes, nil, 0, 0, -20, 0, 0, 1, 40)
    assert(r)
    near(r.t, 20 - 2 * math.sqrt(2), 1e-6, "corner first")
    local flat = Volume.Ray(fit.boxes, nil, 20, 0, 0, -1, 0, 0, 40)
    assert(flat and math.abs(flat.nx) > 0.5 and math.abs(flat.nz) > 0.5, "diagonal normal")
end)
test("the broad phase never changes an answer, only skips hopeless rays", function()
    local fit = Volume.Fit(synthetic())
    local bounds = Volume.Bounds(fit.boxes)
    local seed = 7
    local function rand() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    for _ = 1, 400 do
        local ox, oy, oz = (rand() - 0.5) * 60, rand() * 25, (rand() - 0.5) * 60
        local dx, dy, dz = rand() - 0.5, rand() - 0.5, rand() - 0.5
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        dx, dy, dz = dx / len, dy / len, dz / len
        local a = Volume.Ray(fit.boxes, bounds, ox, oy, oz, dx, dy, dz, 80, 0.5)
        local b = Volume.Ray(fit.boxes, nil, ox, oy, oz, dx, dy, dz, 80, 0.5)
        assert((a == nil) == (b == nil), "broad phase changed the result")
        if a and b then
            near(a.t, b.t, 1e-9) assert(a.region == b.region)
        end
    end
end)
test("reset and rebuild: fitting the same rig twice gives identical volumes (a rebuilt machine is the same machine)", function()
    local a, b = Volume.Fit(synthetic()), Volume.Fit(synthetic())
    assert(#a.boxes == #b.boxes)
    for i, box in ipairs(a.boxes) do
        local other = b.boxes[i]
        assert(box.region == other.region and box.name == other.name)
        for axis = 1, 3 do near(box.c[axis], other.c[axis]) near(box.h[axis], other.h[axis]) end
    end
end)
test("per-region damage: hits on different regions land independently, and only the model's spill reaches the core", function()
    local state = Damage.New()
    Damage.Apply(state, "ARM_L", 40)
    Damage.Apply(state, "LEG_R", 40)
    assert(state.health.ARM_L == state.capacity.ARM_L - 40 and state.health.LEG_R == state.capacity.LEG_R - 40)
    assert(state.health.ARM_R == state.capacity.ARM_R and state.health.LEG_L == state.capacity.LEG_L and state.health.REACTOR == state.capacity.REACTOR)
    near(state.health.CORE, state.capacity.CORE - 2 * 40 * 0.2, 1e-9, "spill 20 %")
end)

print("Shield interaction (outside the hull, never a shell striking invisible armour)")
local PLANE = { z = -13, halfWidth = 11, centreY = 10, halfHeight = 8 }
test("a frontal round crosses the forward shield plane before it reaches the armour, at the point where its path meets the plane", function()
    -- contact on the torso front (z = -2) travelling toward +Z, slightly rising: the plane is 11 studs earlier.
    local x, y, z = Volume.PlaneCrossing(PLANE, 1.0, 8.0, -2.0, 0, 0, 1)
    assert(x and z)
    near(x, 1.0) near(y :: number, 8.0) near(z :: number, -13)
    local x2, y2 = Volume.PlaneCrossing(PLANE, 0, 8, -2, 0.2, 0.1, 0.9747)
    assert(x2 and x2 < 0, "an oblique path crosses to one side of the contact")
    near(y2 :: number, 8 - 0.1 * 11 / 0.9747, 1e-3, "height follows the slope")
end)
test("no shield point when the path misses the plane rectangle, comes from behind or the flank, or the contact is already in front of it", function()
    assert(Volume.PlaneCrossing(PLANE, 0, 8, -2, 0, 0, -1) == nil, "from behind (travelling toward the front)")
    assert(Volume.PlaneCrossing(PLANE, 20, 8, 0, -1, 0, 0) == nil, "flank")
    assert(Volume.PlaneCrossing(PLANE, 15, 8, -2, 0, 0, 1) == nil, "outside the 22 stud width")
    assert(Volume.PlaneCrossing(PLANE, 0, 25, -2, 0, 0, 1) == nil, "above the 16 stud height")
    assert(Volume.PlaneCrossing(PLANE, 0, 8, -20, 0, 0, 1) == nil, "contact already in front of the plane")
end)

print(string.format("fidelity_tests: %d passed, %d failed", passed, failed))
if failed > 0 then
    error("fidelity tests failed")
end
