-- Focused self tests. Run at server start (results shown in the garage UI) and callable from the
-- Studio command bar: require(game.ServerScriptService.IronframeServer.SelfTest).Run()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Compiler = require(Shared:WaitForChild("LoadoutCompiler"))
local Loadouts = require(Shared:WaitForChild("Loadouts"))
local Components = require(Shared:WaitForChild("ComponentRegistry"))
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local MechRig = require(Shared:WaitForChild("MechRig"))
local Showroom = require(Shared:WaitForChild("Showroom"))
local Factory = require(script.Parent.MechFactory)
local Ejection = require(script.Parent.EjectionSequence)
local AssetRegistry = require(Shared:WaitForChild("AssetRegistry"))
local AssetLibrary = require(script.Parent.AssetLibrary)
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local CockpitConfig = require(Shared:WaitForChild("CockpitConfig"))

local SelfTest = {}

local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = clone(v) end
    return copy
end

local function hasIssue(result, fragment)
    for _, issue in ipairs(result.issues) do
        if string.find(issue, fragment, 1, true) then return true end
    end
    return false
end

local function preset(id) return clone(Loadouts.presets[id]) end

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test("all presets compile valid", function()
    for _, id in ipairs(Loadouts.order) do
        local r = Compiler.Compile(Loadouts.presets[id])
        assert(r.valid, id .. ": " .. table.concat(r.issues, "; "))
    end
end)

test("compat: oversized weapon in small socket rejected", function()
    local l = preset("BALANCED")
    l.mounts.left_shoulder = "W_PLASMA_CANNON" -- size 3 into size-2 socket
    assert(hasIssue(Compiler.Compile(l), "Incompatible weapon in left_shoulder"))
end)

test("compat: missile family rejected from torso socket", function()
    local l = preset("BALANCED")
    l.mounts.left_torso = "W_MISSILE_POD"
    assert(hasIssue(Compiler.Compile(l), "Incompatible weapon in left_torso"))
end)

test("compat: unknown socket rejected", function()
    local l = preset("BALANCED")
    l.mounts.back_hump = "W_MICRO_LASER"
    assert(hasIssue(Compiler.Compile(l), "Unknown weapon socket"))
end)

test("compat: empty socket is legal", function()
    local l = preset("BALANCED")
    l.mounts.left_torso = nil
    local r = Compiler.Compile(l)
    assert(r.valid and r.metrics.equippedWeapons == 5)
end)

test("overweight build rejected", function()
    local l = preset("ENERGY")
    l.systems = { reactor = "CORE_300", cooling = "RAD_ADVANCED", armor = "ARMOR_REINFORCED" }
    l.mounts.right_arm = "W_PLASMA_CANNON"
    local r = Compiler.Compile(l)
    assert(r.metrics.mass > r.metrics.massLimit, "build was not actually overweight")
    assert(not r.valid and hasIssue(r, "Mass limit exceeded"))
end)

test("invalid component IDs rejected", function()
    local l = preset("BALANCED")
    l.systems.reactor = "CORE_NOPE"
    l.mounts.right_arm = "W_NOPE"
    local r = Compiler.Compile(l)
    assert(not r.valid and hasIssue(r, "Invalid component for system slot: reactor") and hasIssue(r, "Unknown weapon in right_arm"))
    local wrongClass = preset("BALANCED")
    wrongClass.systems.armor = "CORE_220" -- real ID, wrong class
    assert(hasIssue(Compiler.Compile(wrongClass), "system slot: armor"))
    assert(not Compiler.Compile({ chassisId = "NOPE", systems = {}, mounts = {} }).valid)
    assert(not Compiler.Compile(nil).valid)
end)

test("power overdraw rejected", function()
    -- Temporary weak reactor so the check is exercised without changing shipped balance.
    Components.TEST_WEAK_CORE = { name = "Test Weak Core", class = "reactor", mass = 1, powerOutput = 10 }
    local ok, err = pcall(function()
        local l = preset("ENERGY")
        l.systems.reactor = "TEST_WEAK_CORE"
        local r = Compiler.Compile(l)
        assert(r.metrics.powerDraw > r.metrics.powerOutput)
        assert(not r.valid and hasIssue(r, "Reactor power budget exceeded"))
    end)
    Components.TEST_WEAK_CORE = nil
    assert(ok, err)
end)

test("rig: every preset binds all joints, 6 sockets, hydraulics", function()
    for _, id in ipairs(Loadouts.order) do
        local model = Factory.Create(1, id, Loadouts.presets[id], Vector3.new(0, 0, 0))
        local d = Factory.Describe(model)
        assert(d.socketsFilled == 6, id .. " sockets=" .. d.socketsFilled)
        assert(d.joints == #RigSpec.Joints, id .. " joints=" .. d.joints)
        assert(d.links == #RigSpec.Links, id .. " links=" .. d.links)
        assert(d.armorPanels >= 24, id .. " armor panels=" .. d.armorPanels)
        assert(model.PrimaryPart ~= nil)
        assert(model:GetAttribute("PilotTargetable") == false)
        assert(not model:FindFirstChildWhichIsA("Humanoid", true), "mech must not contain a pilot humanoid")
        model:Destroy()
    end
end)

test("rig: weapons stay attached while torso turns", function()
    local model = Factory.Create(1, "BALANCED", Loadouts.presets.BALANCED, Vector3.new(0, 0, 0))
    local rig = MechRig.Bind(model)
    local rootCF = CFrame.new(0, 0, 0)
    local function snapshot(angles)
        local world = MechRig.Solve(rootCF, angles)
        MechRig.Apply(rig, rootCF, angles)
        local rel = {}
        for _, entry in ipairs(rig.parts) do
            if string.sub(entry.part.Name, 1, 7) == "Weapon_" then
                rel[entry.part] = world[entry.joint]:ToObjectSpace(entry.part.CFrame)
            end
        end
        return rel
    end
    local rest = snapshot(nil)
    local movedBefore = {}
    for part in pairs(rest) do movedBefore[part] = part.Position end
    local turned = snapshot({ Torso = math.rad(45), ElbowL = math.rad(70) })
    local count, moved = 0, 0
    for part, relRest in pairs(rest) do
        count += 1
        local d = (relRest.Position - turned[part].Position).Magnitude
        assert(d < 1e-3, part.Name .. " detached by " .. d)
        if (part.Position - movedBefore[part]).Magnitude > 0.5 then moved += 1 end
    end
    assert(count >= 6, "too few weapon parts: " .. count) -- AI weapon meshes consolidate a weapon into one part
    assert(moved > 0, "torso turn did not move weapons")
    model:Destroy()
end)

-- Oriented-box penetration depth (SAT) between two parts; 0 when separated.
local function penetration(a: BasePart, b: BasePart): number
    local ca, cb = a.CFrame, b.CFrame
    local ha, hb = a.Size / 2, b.Size / 2
    local ra, rb = { ca.RightVector, ca.UpVector, ca.LookVector }, { cb.RightVector, cb.UpVector, cb.LookVector }
    local axes = {}
    for _, v in ipairs(ra) do table.insert(axes, v) end
    for _, v in ipairs(rb) do table.insert(axes, v) end
    for _, u in ipairs(ra) do
        for _, v in ipairs(rb) do
            local c = u:Cross(v)
            if c.Magnitude > 1e-4 then table.insert(axes, c.Unit) end
        end
    end
    local function radius(cf, h, axis)
        return math.abs(cf.RightVector:Dot(axis)) * h.X + math.abs(cf.UpVector:Dot(axis)) * h.Y + math.abs(cf.LookVector:Dot(axis)) * h.Z
    end
    local d, minOverlap = cb.Position - ca.Position, math.huge
    for _, axis in ipairs(axes) do
        local overlap = radius(ca, ha, axis) + radius(cb, hb, axis) - math.abs(d:Dot(axis))
        if overlap <= 0 then return 0 end
        minOverlap = math.min(minOverlap, overlap)
    end
    return minOverlap
end

test("m05: AI armor keeps the rig contract and falls back cleanly", function()
    for _, id in ipairs(Loadouts.order) do
        local procedural = Factory.Create(1, id, Loadouts.presets[id], Vector3.zero, { useAssets = false })
        local dp = Factory.Describe(procedural)
        assert(dp.meshParts == 0, "procedural fallback must not contain MeshParts")
        procedural:Destroy()
        local withAssets = Factory.Create(1, id, Loadouts.presets[id], Vector3.zero)
        local da = Factory.Describe(withAssets)
        assert(da.joints == dp.joints and da.links == dp.links and da.socketsFilled == dp.socketsFilled, id .. ": AI armor changed the rig contract")
        if AssetLibrary.Has("MEC_010") and AssetLibrary.Has("MEC_011") then
            assert(da.meshParts >= 12, id .. ": expected AI armor meshes, found " .. da.meshParts)
            assert(da.parts < dp.parts, id .. ": AI armor should consolidate procedural parts")
        end
        withAssets:Destroy()
    end
end)

test("m05: left and right armor reuse one mesh asset; weapon visuals keep logical ids", function()
    local model = Factory.Create(1, "BALANCED", Loadouts.presets.BALANCED, Vector3.zero)
    for _, base in ipairs({ "ThighArmor", "ShinArmor", "FootArmor", "Pauldron", "UpperArmArmor", "ForearmArmor" }) do
        local l, r = model:FindFirstChild(base .. "L"), model:FindFirstChild(base .. "R")
        if l and r then
            assert(l:GetAttribute("AssetId") == r:GetAttribute("AssetId") and l.MeshId == r.MeshId, base .. " L/R do not share one mesh")
            assert(l.Size == r.Size, base .. " L/R sizes differ")
        end
    end
    -- Metrics come from the compiler only: swapping weapon visuals must not change cost or stats.
    local metrics = Compiler.Compile(Loadouts.presets.BALANCED).metrics
    assert(metrics.mass > 0 and metrics.equippedWeapons == 6)
    model:Destroy()
end)

test("m05: AI armor clears neighbouring armor through the idle sweep", function()
    local model = Factory.Create(1, "BALANCED", Loadouts.presets.BALANCED, Vector3.zero)
    if not model:FindFirstChild("Pauldron" .. "L") then
        model:Destroy()
        return -- assets unavailable: procedural fallback has its own spacing rules
    end
    local rig = MechRig.Bind(model)
    local checks = {
        { "PauldronL", "HeadBlock", 0.25 }, { "PauldronR", "HeadBlock", 0.25 },
        { "PauldronL", "UpperArmArmorL", 0.25 }, { "PauldronR", "UpperArmArmorR", 0.25 },
        { "PauldronL", "ChestArmor", 0.25 }, { "PauldronR", "ChestArmor", 0.25 },
        { "ChestArmor", "UpperArmArmorL", 0.25 }, { "ChestArmor", "UpperArmArmorR", 0.25 },
        { "ThighArmorL", "ThighArmorR", 0.25 }, { "ThighArmorL", "ShinArmorL", 0.6 },
    }
    for t = 0, 60, 0.5 do
        MechRig.Apply(rig, CFrame.new(), (Showroom.Pose(t, 0)))
        for _, c in ipairs(checks) do
            local a, b = model:FindFirstChild(c[1]), model:FindFirstChild(c[2])
            if a and b then
                local depth = penetration(a, b)
                assert(depth <= c[3], string.format("%s / %s interpenetrate %.2f studs at t=%.1f (limit %.2f)", c[1], c[2], depth, t, c[3]))
            end
        end
    end
    model:Destroy()
end)

test("showroom: deterministic and within limits", function()
    local a, bobA = Showroom.Pose(12.34, 1.5)
    local b, bobB = Showroom.Pose(12.34, 1.5)
    assert(bobA == bobB)
    for name, angle in pairs(a) do
        assert(angle == b[name])
        local j = RigSpec.JointsByName[name]
        assert(math.abs(angle - j.rest) <= j.limit + 1e-6, name .. " out of limit")
    end
end)

test("ejection: pilot safe before any mech hook; never targetable", function()
    local session = { pilotSafe = false, machineState = "OPERATIONAL" }
    local log = {}
    local function mark(tag)
        assert(session.pilotSafe == true, tag .. " ran before pilot was safe")
        assert(Ejection.IsPilotTargetable(session) == false)
        table.insert(log, tag)
    end
    Ejection.Run(session, {
        onPilotSafe = function() mark("safe") end,
        onMechDisabled = function() mark("disabled") end,
        onCleanup = function() mark("cleanup") end,
        onRebuild = function() mark("rebuild") end,
        isStale = function() return false end,
    }, function(_, fn) fn() end)
    assert(table.concat(log, ",") == "safe,disabled,cleanup,rebuild", table.concat(log, ","))
    assert(session.pilotSafe and session.pilotTargetable == false)
end)

test("ejection: stale session never rebuilds but pilot stays safe", function()
    local session = { pilotSafe = false }
    local rebuilt = false
    Ejection.Run(session, {
        onPilotSafe = function() end, onMechDisabled = function() end, onCleanup = function() end,
        onRebuild = function() rebuilt = true end, isStale = function() return true end,
    }, function(_, fn) fn() end)
    assert(not rebuilt and session.pilotSafe)
end)

test("asset registry: stable ids, cloud model ids, accepted assets only", function()
    assert(#AssetRegistry.list >= 11, "expected at least 11 accepted assets, got " .. #AssetRegistry.list)
    for _, id in ipairs({ "MEC_010", "MEC_011", "MEC_012", "MEC_013", "MEC_015" }) do
        assert(AssetRegistry.byId[id], "first-wave armor asset missing from registry: " .. id)
    end
    for _, entry in ipairs(AssetRegistry.list) do
        assert(string.match(entry.id, "^%u%u%u_%d%d%d$"), "bad id " .. entry.id)
        assert(type(entry.modelAssetId) == "number" and entry.modelAssetId > 0, entry.id .. " lacks a model asset id")
        assert(AssetRegistry.byId[entry.id] == entry)
    end
    assert(AssetRegistry.byId.HNG_001 == nil and AssetRegistry.byId.MEC_001 == nil, "NEEDS_REVIEW/REJECTED assets must not be registered")
end)

test("asset library: unknown asset is skipped, never substituted", function()
    assert(AssetLibrary.Place("HNG_999", CFrame.new(), {}) == nil)
end)

test("m06a: rig contract untouched (14 joints, 6 sockets) and Apply exposes the Torso frame", function()
    assert(#RigSpec.Joints == 14, "joint count changed: " .. #RigSpec.Joints)
    assert(#RigSpec.SocketOrder == 6, "socket count changed")
    local model = Factory.Create(1, "BALANCED", Loadouts.presets.BALANCED, Vector3.zero)
    local world = MechRig.Apply(MechRig.Bind(model), CFrame.new(0, 5, 0), nil)
    assert(typeof(world.Torso) == "CFrame" and world.Torso.Position.Y > 5, "Apply must return solved joint frames")
    model:Destroy()
end)

test("m06a: pilot eye sits inside the torso envelope and head-look limits are sane", function()
    local eye = CockpitConfig.EYE_OFFSET
    assert(eye.Y > 3.2 and eye.Y < 5.4 and math.abs(eye.X) < 0.5, "eye not centred in the chest cockpit")
    assert(eye.Z > CockpitConfig.HIDE_MIN.Z and eye.Z < CockpitConfig.HIDE_MAX.Z, "eye outside the hidden hull box")
    assert(CockpitConfig.MAX_YAW <= math.rad(80) and CockpitConfig.MAX_PITCH_UP <= math.rad(45) and CockpitConfig.MAX_PITCH_DOWN <= math.rad(45))
    assert(CockpitConfig.SWAY <= 0.005 and CockpitConfig.VIBRATION <= 0.01, "comfort defaults must stay minimal")
end)

test("m06a: telemetry bus publishes, rejects bad status and defaults to STANDBY", function()
    Telemetry.Reset()
    assert(Telemetry.Get("heat.level").status == "STANDBY" and Telemetry.Value("heat.level", 7) == 7)
    local seen = 0
    local disconnect = Telemetry.Subscribe(function() seen += 1 end)
    Telemetry.Publish("heat.level", 12, "LIVE")
    Telemetry.Publish("heat.level", 12, "LIVE") -- unchanged: no notification
    assert(seen == 1 and Telemetry.Value("heat.level") == 12)
    assert(not pcall(Telemetry.Publish, "heat.level", 1, "BOGUS"))
    disconnect()
    Telemetry.Publish("heat.level", 13)
    assert(seen == 1)
    Telemetry.Reset()
end)

test("m06a: cockpit AI assets are replicated read-only when registered", function()
    local registered = 0
    for _, entry in ipairs(AssetRegistry.list) do
        if string.sub(entry.id, 1, 4) == "CPT_" then
            registered += 1
        end
    end
    local folder = game:GetService("ReplicatedStorage"):FindFirstChild("IronframeCockpitAssets")
    local replicated = folder and #folder:GetChildren() or 0
    assert(replicated <= registered, "more cockpit assets replicated than registered")
    if registered > 0 and AssetLibrary.Has("CPT_001") then
        assert(replicated >= 1, "registered cockpit assets were not replicated")
        for _, d in ipairs(folder:GetDescendants()) do
            assert(not d:IsA("Script") and not d:IsA("LocalScript"), "cockpit asset carries code")
        end
    end
end)

test("m08a: installed energy components compile without changing existing presets", function()
    for _, id in ipairs(Loadouts.order) do
        local compiled = Compiler.Compile(Loadouts.presets[id])
        assert(compiled.valid and compiled.energy.output == 80 and compiled.energy.capacity == 160)
        assert(compiled.energy.shield.activationCost == 25)
    end
    local upgrade = preset("BALANCED")
    upgrade.systems.capacitor, upgrade.systems.reactor = "CAP_HIGH_DENSITY", "CORE_300"
    local compiled = Compiler.Compile(upgrade)
    assert(compiled.valid and compiled.energy.capacity == 240 and compiled.energy.output == 120)
end)
test("m08a: invalid resource components are rejected", function()
    local invalid = preset("BALANCED")
    invalid.systems.shield = "CORE_220"
    assert(not Compiler.Compile(invalid).valid)
    invalid = preset("BALANCED")
    invalid.systems.capacitor = "CAP_MISSING"
    assert(not Compiler.Compile(invalid).valid)
end)

function SelfTest.Run()
    local result = { passed = 0, total = #tests, failed = {} }
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            result.passed += 1
        else
            table.insert(result.failed, t.name)
            warn(string.format("[IF-TEST] FAIL %s: %s", t.name, tostring(err)))
        end
    end
    print(string.format("[IF-TEST] %d/%d passed", result.passed, result.total))
    return result
end

return SelfTest
