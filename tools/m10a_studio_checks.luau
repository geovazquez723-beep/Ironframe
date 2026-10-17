-- M10A logic checks. Run with execute_luau in EDIT mode (builds a throw-away district in a scratch Model; call
-- require(ServerScriptService.IronframeServer.AssetLibrary).Load() first to check the AI-skinned tanks). It drives the REAL weapon hit path (CombatTargets.Hit -> Destructibles.Hit)
-- with the real weapon ids and registry numbers, steps the district manually, and checks collision / line of sight / reset.
-- Returns a JSON string of results; any failed expectation is listed under "failures".
local S = game.ServerScriptService.IronframeServer
local Shared = game.ReplicatedStorage.IronframeShared
local D = require(S.Destructibles)
local Targets = require(S.CombatTargets)
local Components = require(Shared.ComponentRegistry)
local Http = game:GetService("HttpService")

-- Edit mode only: the Play-mode server runs its own module instances, so production state is reached through the
-- IronframeRangeAudit BindableFunction instead (see tools/m10a_client_scenario.luau and docs/M10A_DESTRUCTIBLE_PROVING_GROUND.md).
assert(not game:GetService("RunService"):IsRunning(), "run this check in EDIT mode (Play uses IronframeRangeAudit)")
local scratch = Instance.new("Model")
scratch.Name = "M10AChecks"
scratch.Parent = workspace
local d = require(S.DistrictBuilder).Build(scratch, Vector3.new(0, 0, 0), scratch)

local results, failures = {}, {}
local function check(name, cond, detail)
    results[name] = detail == nil and cond or detail
    if not cond then table.insert(failures, name .. (detail ~= nil and (": " .. tostring(detail)) or "")) end
end
local function stepFor(seconds)
    local t = os.clock()
    while os.clock() - t < seconds do
        D.Step(os.clock(), 1 / 30)
        task.wait(1 / 30)
    end
end
local function module(name)
    for _, m in ipairs(d.modules) do if m.name == name then return m end end
    error("no module " .. name)
end
local function fire(part, weaponId)
    local spec = Components[weaponId].combat
    return Targets.Hit(part, spec.category, spec.damage, os.clock(), { weapon = weaponId, position = part.Position + Vector3.new(0, 0, -part.Size.Z / 2 - 0.1), normal = Vector3.new(0, 0, -1) })
end
-- Shots until the module is destroyed (or `cap`), with a physical cadence-free count (rate limits belong to Weapons.Step).
local function shotsToDestroy(obj, weaponId, cap)
    local n = 0
    while not obj.destroyed and n < (cap or 4000) do
        if d.resetting then break end
        fire(obj.part, weaponId)
        n += 1
    end
    return n
end

-- 1. Weapon identity on the same material (barricade = CONCRETE 520 hp) and on panels.
local panelShots, concreteShots = {}, {}
for i, id in ipairs({ "W_MACHINE_GUN", "W_LASER_RIFLE", "W_HMG_MAULER" }) do
    -- Fresh modules per weapon, each far from its neighbours so splash does not interfere.
    local barricade = module("Barricade" .. i)
    local panel = module("WH_WEST_R3C" .. (i * 2 - 1))
    concreteShots[id] = shotsToDestroy(barricade, id)
    panelShots[id] = shotsToDestroy(panel, id)
end
check("concrete_shots", concreteShots.W_MACHINE_GUN > concreteShots.W_LASER_RIFLE and concreteShots.W_LASER_RIFLE > concreteShots.W_HMG_MAULER, Http:JSONEncode(concreteShots))
check("panel_mg_is_effective", panelShots.W_MACHINE_GUN <= 14, Http:JSONEncode(panelShots))
check("mg_vs_concrete_far_worse", concreteShots.W_MACHINE_GUN > 8 * panelShots.W_MACHINE_GUN)

-- 2. Destroyed module: part out of the workspace (collision + LOS), line of sight restored, unit destroyed.
local bar = module("Barricade1")
check("barricade_removed", bar.destroyed and bar.root.Parent == nil and bar.part:GetAttribute("Stage") == "DESTROYED")
local params = RaycastParams.new()
local origin = bar.cf.Position + Vector3.new(0, 0, -30)
local through = workspace:Raycast(origin, Vector3.new(0, 0, 60), params)
check("los_through_gap", through == nil or through.Instance ~= bar.part)

-- 3. Wall breach: shoot a lower panel of the rear wall; the panel above must collapse (support rule) and the opening is real.
local low, up = module("WH_BACK_R1C3"), module("WH_BACK_R2C3")
local before = up.destroyed
shotsToDestroy(low, "W_HMG_MAULER")
stepFor(1.4)
check("support_collapse_above", before == false and up.destroyed == true)
local hole = workspace:Raycast(low.cf.Position + Vector3.new(0, 4, -8), Vector3.new(0, 0, 16), params)
check("breach_is_open", hole == nil or (hole.Instance ~= low.part and hole.Instance ~= up.part))

-- 4. Gantry shed partial collapse: destroy one column, beam and its roof panels come down (and only that side).
local col = module("ShedColumn_-60_582")
shotsToDestroy(col, "W_HMG_MAULER")
stepFor(3.2)
check("shed_beam_collapsed", module("ShedBeam_582").destroyed)
check("shed_roof_collapsed", module("ShedRoof_0_1").destroyed and module("ShedRoof_1_1").destroyed and module("ShedRoof_2_1").destroyed)
check("shed_other_side_standing", not module("ShedBeam_598").destroyed and not module("ShedRoof_0_2").destroyed)
check("collapse_not_counted_as_damage", d.stats.collapses >= 4)

-- 5. Tanks: component rules via the production hit path.
local t1, t2, t3 = d.vehicles[1], d.vehicles[2], d.vehicles[3]
local function hitComp(tank, comp, weaponId, n)
    local part = tank.build.groups[comp].hit[1]
    for _ = 1, n do fire(part, weaponId) end
end
hitComp(t3, "TRACK_L", "W_HMG_MAULER", 40)
check("track_disables_mobility", t3.status.mobile == false and t3.status.status == "IMMOBILIZED" and t3.status.turretOperational == true)
hitComp(t2, "TURRET", "W_HMG_MAULER", 60)
check("turret_disabled_not_hull", t2.status.status == "TURRET DISABLED" and t2.status.mobile and not t2.status.destroyed)
hitComp(t1, "HULL", "W_HMG_MAULER", 120)
check("hull_destroys_vehicle", t1.status.destroyed and t1.status.status == "VEHICLE DESTROYED")
check("vehicle_stats", d.stats.vehiclesDestroyed == 1 and d.stats.targetsDisabled >= 1)

-- 6. Training mech.
local mech = d.mech
local function hitMech(comp, n, weaponId)
    for _, v in ipairs(mech.volumes) do
        if v.component == comp then for _ = 1, n do fire(v.part, weaponId) end break end
    end
end
hitMech("SHOULDER_ARMOR", 60, "W_HMG_MAULER")
hitMech("ARM_MOUNT", 60, "W_HMG_MAULER")
hitMech("LEG_ASSEMBLY", 60, "W_HMG_MAULER")
stepFor(1.2)
check("mech_components", mech.status.armorLost and mech.status.weaponMountLost and mech.status.legsLost and not mech.status.disabled)
hitMech("CHASSIS", 120, "W_HMG_MAULER")
stepFor(1.6)
check("mech_terminal", mech.status.disabled and mech.status.status == "TARGET DISABLED")
check("mech_never_a_pilot_target", mech.model:GetAttribute("Unmanned") == true)

-- 7. Reset: everything restored, no growth in instance count, registry unchanged.
local baseline = D.Audit(d)
local function resetAll()
    D.Reset(d, "ALL")
    local t = os.clock()
    while d.resetting and os.clock() - t < 10 do D.Step(os.clock(), 1 / 30) task.wait(1 / 30) end
end
resetAll()
local afterReset = D.Audit(d)
local intact = true
for _, m in ipairs(d.modules) do
    if m.destroyed or m.unit.health ~= m.unit.capacity or m.root.Parent ~= m.home or m.part.CFrame ~= m.cf then intact = false break end
end
check("reset_modules_restored", intact and afterReset.rubble == 0 and afterReset.overlays == 0)
local allTanksFresh = true
for _, t in ipairs(d.vehicles) do
    if t.status.status ~= "OPERATIONAL" or not t.model.Parent then allTanksFresh = false end
end
check("reset_vehicles_restored", allTanksFresh and d.mech.status.status == "OPERATIONAL" and d.stats.vehiclesDestroyed == 0)

-- 8. Repeated destroy/reset cycles must not leak instances or registry entries.
local counts = {}
for cycle = 1, 4 do
    for _, name in ipairs({ "Barricade5", "WH_FRONT_R1C1", "WH_FRONT_R1C5", "BunkerRoof1" }) do
        local m = module(name)
        shotsToDestroy(m, "W_HMG_MAULER", 200)
    end
    hitComp(d.vehicles[1], "HULL", "W_HMG_MAULER", 120)
    hitComp(d.vehicles[1], "TURRET", "W_HMG_MAULER", 60)
    hitMech("CHASSIS", 120, "W_HMG_MAULER")
    stepFor(1.5)
    resetAll()
    local a = D.Audit(d)
    counts[cycle] = { instances = a.instances, indexed = a.totalIndexed, rubble = a.rubble, overlays = a.overlays }
end
check("no_leak_instances", counts[1].instances == counts[4].instances and counts[1].indexed == counts[4].indexed, Http:JSONEncode(counts))
check("registry_stable", D.Audit(d).totalIndexed == baseline.totalIndexed, Http:JSONEncode({ baseline.totalIndexed, D.Audit(d).totalIndexed }))

-- 9. Protection: pilots, capsules and non-registered parts never take damage.
local capsule = Instance.new("Part")
capsule:SetAttribute("Targetable", false)
check("capsule_not_damageable", fire(capsule, "W_HMG_MAULER") == 0)
check("hangar_not_registered", fire(workspace:FindFirstChildOfClass("Terrain") or capsule, "W_HMG_MAULER") == 0)
capsule:Destroy()
check("no_plasma_or_unknown_damage", Targets.Hit(module("Barricade2").part, "plasma", 50, os.clock(), { weapon = "W_PLASMA_CANNON" }) == 0)

results.audit = D.Audit(d)
results.stats = d.stats
scratch:Destroy()
return Http:JSONEncode({ failures = failures, results = results })
