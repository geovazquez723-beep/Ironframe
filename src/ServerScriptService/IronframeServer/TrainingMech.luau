-- Stationary unmanned training mech (M10A).
--
-- The visual is the existing procedural IF-42 rig (MechFactory / BastionBuilder / MechRig), re-colored as a training target and
-- parked outside IronframeMechs, so no client controller, drive or animator ever touches it. It is NOT a second controller: it
-- has no locomotion, no input and no AI. A handful of invisible, joint-attached hit volumes carry four damageable components
-- (they follow every pose, so hit geometry always matches what is on screen):
--
--   CHASSIS         central torso / head / left arm  -> TARGET DISABLED (terminal slump, fire, smoke)
--   ARM_MOUNT       right arm and its weapon          -> weapon mount lost (limp arm, weapon shot off)
--   SHOULDER_ARMOR  both pauldron assemblies          -> armor stripped (plates fly off)
--   LEG_ASSEMBLY    both legs                         -> mobility disabled (the machine kneels)
--
-- Damage presentation is a pose (MechRig.Apply with joint overrides) plus part removal and tint. The player's operational
-- Bastion damage system is untouched: nothing here can address a player's mech, and pilots are never targets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Loadouts = require(Shared:WaitForChild("Loadouts"))
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local MechRig = require(Shared:WaitForChild("MechRig"))
local Unit = require(Shared:WaitForChild("DestructibleState"))
local Rules = require(Shared:WaitForChild("ComponentRules"))
local Factory = require(script.Parent.MechFactory)
local Destructibles = require(script.Parent.Destructibles)

local TrainingMech = {}

local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local SOOT = Color3.fromRGB(22, 22, 24)
local ORANGE = Color3.fromRGB(190, 96, 34)

-- Hit volumes: { component, joint, offset CFrame, size }. Joint frames come from RigSpec/MechRig, so they follow poses.
local VOLUMES = {
    { "CHASSIS", "Torso", CF(0, 2.6, 0.2), V3(9.6, 7.8, 7.4) },
    { "CHASSIS", "Hip", CF(0, 0.4, 0), V3(6.6, 3.2, 6.0) },
    { "CHASSIS", "Head", CF(0, 0.2, -0.3), V3(3.6, 3.2, 3.6) },
    { "CHASSIS", "ShoulderL", CF(0, -2.2, 0), V3(3.4, 6.0, 3.8) },
    { "CHASSIS", "ElbowL", CF(0, -1.8, -0.3), V3(3.2, 5.0, 3.8) },
    { "CHASSIS", "ElbowL", CF(0, -3.4, -3.2), V3(2.0, 2.0, 7.0) },
    { "ARM_MOUNT", "ShoulderR", CF(0, -2.2, 0), V3(3.4, 6.0, 3.8) },
    { "ARM_MOUNT", "ElbowR", CF(0, -1.8, -0.3), V3(3.2, 5.0, 3.8) },
    { "ARM_MOUNT", "ElbowR", CF(0, -3.4, -4.6), V3(3.0, 3.0, 9.0) },
    { "SHOULDER_ARMOR", "Torso", CF(-5.3, 6.3, 0.1), V3(4.4, 2.6, 5.6) },
    { "SHOULDER_ARMOR", "Torso", CF(5.3, 6.3, 0.1), V3(4.4, 2.6, 5.6) },
}
for _, tag in ipairs({ "L", "R" }) do
    table.insert(VOLUMES, { "LEG_ASSEMBLY", "Thigh" .. tag, CF(0, -1.9, 0.3), V3(3.4, 4.6, 4.2) })
    table.insert(VOLUMES, { "LEG_ASSEMBLY", "Knee" .. tag, CF(0, -1.9, 0.3), V3(3.2, 4.6, 4.0) })
    table.insert(VOLUMES, { "LEG_ASSEMBLY", "Ankle" .. tag, CF(0, -0.6, -0.8), V3(3.4, 2.0, 5.0) })
end

local function classify(part: BasePart): string
    local name = part.Name
    local joint = part:GetAttribute("Joint")
    local link = part:GetAttribute("LinkId")
    if link then
        if string.find(link, "R$") and (string.find(link, "^Shoulder") or string.find(link, "^Elbow")) then
            return "ARM_MOUNT"
        elseif string.find(link, "^Hip") or string.find(link, "^Knee") then
            return "LEG_ASSEMBLY"
        end
        return "CHASSIS"
    end
    if string.find(name, "^Pauldron") or string.find(name, "^ShoulderLame") or string.find(name, "^ReinforcedPauldron") or string.find(name, "^ShoulderMarker") then
        return "SHOULDER_ARMOR"
    end
    if joint == "ShoulderR" or joint == "ElbowR" or string.find(name, "^Weapon_right_arm") or string.find(name, "^Mount_right_arm") then
        return "ARM_MOUNT"
    end
    if joint and (string.find(joint, "^Thigh") or string.find(joint, "^Knee") or string.find(joint, "^Ankle")) then
        return "LEG_ASSEMBLY"
    end
    return "CHASSIS"
end

local function recolor(model: Model)
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part:GetAttribute("Group") == "armor" then
            part.Color = ORANGE:Lerp(part.Color, 0.42)
        end
    end
end

-- Poses -------------------------------------------------------------------------------------------------------------------
local function rest(joint: string): number
    return RigSpec.JointsByName[joint].rest
end

-- Joint overrides + root offset for the current set of lost components. Pure function of the flags.
local function targetPose(mech)
    local angles, pitch, roll, torsoYaw = {}, 0, 0, nil
    if mech.flags.arm then
        angles.ShoulderR, angles.ElbowR = -0.18, 0.1
    end
    local drop = 0
    if mech.flags.legs or mech.flags.chassis then
        for _, tag in ipairs({ "L", "R" }) do
            angles["Thigh" .. tag], angles["Knee" .. tag], angles["Ankle" .. tag] = 1.2, -2.15, 0.95
        end
        -- Lower the root so the lowest of knee/ankle sits on the ground (same solver the renderer uses).
        local world = MechRig.Solve(CFrame.identity, angles)
        local lowest = math.huge
        for _, joint in ipairs({ "KneeL", "KneeR", "AnkleL", "AnkleR" }) do
            lowest = math.min(lowest, world[joint].Position.Y)
        end
        drop = lowest - 1.3
        pitch = 0.05
    end
    if mech.flags.chassis then
        torsoYaw = 0.38
        angles.Torso, angles.Head = 0.38, -0.55
        angles.ShoulderL, angles.ElbowL = -0.2, 0.2
        angles.ShoulderR, angles.ElbowR = -0.25, 0.15
        pitch = 0.2
        roll = 0.06
    end
    return { angles = angles, offsetY = -drop, pitch = pitch, roll = roll, torsoYaw = torsoYaw }
end

local function lerpPose(a, b, f: number)
    local angles = {}
    local names = {}
    for k in pairs(a.angles) do names[k] = true end
    for k in pairs(b.angles) do names[k] = true end
    for k in pairs(names) do
        local from = if a.angles[k] ~= nil then a.angles[k] else rest(k)
        local to = if b.angles[k] ~= nil then b.angles[k] else rest(k)
        angles[k] = from + (to - from) * f
    end
    return {
        angles = angles,
        offsetY = a.offsetY + (b.offsetY - a.offsetY) * f,
        pitch = a.pitch + (b.pitch - a.pitch) * f,
        roll = a.roll + (b.roll - a.roll) * f,
    }
end

local function applyPose(mech, pose)
    local base = mech.baseCF
    local rootCF = base * CF(0, pose.offsetY, 0) * ANG(pose.pitch, 0, pose.roll)
    local world = MechRig.Apply(mech.rig, rootCF, pose.angles)
    mech.pose = pose
    -- Hit volumes follow the pose so what you see is what you hit.
    for _, volume in ipairs(mech.volumes) do
        volume.part.CFrame = world[volume.joint] * volume.offset
    end
end

-- Build / respawn ---------------------------------------------------------------------------------------------------------------
local function hideParts(mech, d, component: string, limit: number)
    local group = mech.partsBy[component]
    local list = {}
    for _, part in ipairs(group) do
        if part.Parent then
            table.insert(list, part)
        end
    end
    table.sort(list, function(a, b) return a.Size.Magnitude > b.Size.Magnitude end)
    for i, part in ipairs(list) do
        if i <= limit then
            Destructibles.Emit(d, { t = "x", f = "metal", k = "break", cf = part.CFrame, s = part.Size, c = part.Color, mat = part.Material, e = 0.7 }, true)
        end
        part:Destroy()
    end
    mech.partsBy[component] = {}
end

local function tintGroup(mech, component: string, amount: number)
    for _, part in ipairs(mech.partsBy[component]) do
        if part.Parent then
            part.Color = (mech.base[part] or part.Color):Lerp(SOOT, amount)
        end
    end
end

local function startAnimation(mech, t: number, duration: number)
    mech.anim = { from = mech.pose, to = targetPose(mech), start = t, duration = duration, last = -1 }
end

local function onStage(d, mech, comp: string, old: string, new: string, position: Vector3, normal: Vector3, class: string)
    if mech.status.disabled and comp ~= "CHASSIS" then
        return
    end
    if new == "DAMAGED" then
        tintGroup(mech, comp, 0.2)
        table.insert(mech.emitters, Destructibles.SmokeEmitter(mech.volumeFor[comp].part, if comp == "CHASSIS" then 6 else 3, 1.8, 14))
        Destructibles.Emit(d, { t = "s", f = "machine", p = position, n = normal, w = class, e = 1 }, true)
        return
    end
    if new ~= "DESTROYED" then
        return
    end
    Destructibles.NoteComponentLost(d)
    local notice
    if comp == "SHOULDER_ARMOR" then
        hideParts(mech, d, comp, 8)
        notice = "ARMOR STRIPPED"
    elseif comp == "ARM_MOUNT" then
        mech.flags.arm = true
        tintGroup(mech, comp, 0.55)
        -- The weapon is shot off the mount: its parts go, the dark limp arm stays.
        local gone = {}
        for _, part in ipairs(mech.partsBy[comp]) do
            if string.find(part.Name, "^Weapon_") then
                table.insert(gone, part)
            end
        end
        local kept = {}
        for _, part in ipairs(mech.partsBy[comp]) do
            if not table.find(gone, part) then
                table.insert(kept, part)
            end
        end
        table.sort(gone, function(a, b) return a.Size.Magnitude > b.Size.Magnitude end)
        for i, part in ipairs(gone) do
            if i <= 6 then
                Destructibles.Emit(d, { t = "x", f = "metal", k = "break", cf = part.CFrame, s = part.Size, c = part.Color, mat = part.Material, e = 0.8 }, true)
            end
            part:Destroy()
        end
        mech.partsBy[comp] = kept
        table.insert(mech.emitters, Destructibles.SmokeEmitter(mech.volumeFor[comp].part, 6, 2, 20))
        startAnimation(mech, os.clock(), 0.5)
        notice = "WEAPON MOUNT LOST"
    elseif comp == "LEG_ASSEMBLY" then
        mech.flags.legs = true
        tintGroup(mech, comp, 0.5)
        table.insert(mech.emitters, Destructibles.SmokeEmitter(mech.volumeFor[comp].part, 6, 2.2, 20))
        startAnimation(mech, os.clock(), 0.8)
        notice = "MOBILITY DISABLED"
    elseif comp == "CHASSIS" then
        mech.flags.chassis = true
        for _, group in pairs({ "CHASSIS", "ARM_MOUNT", "SHOULDER_ARMOR", "LEG_ASSEMBLY" }) do
            tintGroup(mech, group, 0.58)
        end
        local chest = mech.volumeFor.CHASSIS.part
        table.insert(mech.emitters, Destructibles.SmokeEmitter(chest, 16, 4.6, 26))
        table.insert(mech.emitters, Destructibles.FireEmitter(chest, 18, 3))
        table.insert(mech.emitters, Destructibles.SmokeEmitter(mech.volumeFor.LEG_ASSEMBLY.part, 8, 2.4, 20))
        startAnimation(mech, os.clock(), 1.1)
        Destructibles.Emit(d, { t = "x", f = "machine", k = "explosion", cf = chest.CFrame, s = chest.Size, c = Color3.fromRGB(70, 70, 70), mat = Enum.Material.Metal, e = 3.0 }, true)
        notice = "TARGET DISABLED"
    end
    mech.status = Rules.Mech(mech.units)
    mech.model:SetAttribute("Status", mech.status.status)
    if notice then
        Destructibles.Notice(d, string.format("TRAINING MECH %s - %s", mech.id, notice), nil)
    end
    if comp == "CHASSIS" then
        Destructibles.NoteTargetDisabled(d, false)
    end
end

local function update(d, mech, _dt: number, t: number)
    local anim = mech.anim
    if not anim then
        return
    end
    local f = math.clamp((t - anim.start) / anim.duration, 0, 1)
    -- Cap pose updates at ~20 Hz (each is one BulkMoveTo of the rig's parts), always finishing exactly on the target.
    if f < 1 and t - anim.last < 0.05 then
        return
    end
    anim.last = t
    local eased = 1 - (1 - f) * (1 - f)
    applyPose(mech, if f >= 1 then anim.to else lerpPose(anim.from, anim.to, eased))
    if f >= 1 then
        mech.anim = nil
    end
end

local function construct(d, mech)
    local loadout = table.clone(Loadouts.presets.AUTOCANNON)
    local model = Factory.Create(0, "AUTOCANNON", loadout, mech.position, { useAssets = false })
    model.Name = "TrainingMech_" .. mech.id
    for _, attribute in ipairs({ "OwnerUserId", "PresetId" }) do
        model:SetAttribute(attribute, nil)
    end
    model:SetAttribute("State", "TRAINING_TARGET")
    model:SetAttribute("TrainingTarget", true)
    model:SetAttribute("Unmanned", true)
    model:SetAttribute("Status", "OPERATIONAL")
    recolor(model)
    mech.model = model
    mech.rig = MechRig.Bind(model)
    mech.baseCF = CF(mech.position) * ANG(0, mech.yaw, 0)
    mech.partsBy = { CHASSIS = {}, ARM_MOUNT = {}, SHOULDER_ARMOR = {}, LEG_ASSEMBLY = {} }
    mech.base = {}
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local component = classify(part)
            table.insert(mech.partsBy[component], part)
            mech.base[part] = part.Color
        end
    end
    mech.units = {
        CHASSIS = Unit.New({ material = "MECH_CHASSIS" }), ARM_MOUNT = Unit.New({ material = "MECH_ARM" }),
        SHOULDER_ARMOR = Unit.New({ material = "MECH_ARMOR" }), LEG_ASSEMBLY = Unit.New({ material = "MECH_LEG" }),
    }
    mech.comps = {}
    for name, unit in pairs(mech.units) do
        mech.comps[name] = { unit = unit }
    end
    mech.flags, mech.emitters, mech.anim = { arm = false, legs = false, chassis = false }, {}, nil
    mech.volumes, mech.volumeFor = {}, {}
    local holder = Instance.new("Folder")
    holder.Name = "HitVolumes"
    holder.Parent = model
    for _, v in ipairs(VOLUMES) do
        local part = Instance.new("Part")
        part.Name = "Hit_" .. v[1]
        part.Size = v[4]
        part.Transparency = 1
        part.Anchored = true
        part.CanCollide, part.CanTouch, part.CastShadow = false, false, false
        part.CanQuery = true
        part.Parent = holder
        table.insert(mech.volumes, { part = part, joint = v[2], offset = v[3], component = v[1] })
        mech.volumeFor[v[1]] = mech.volumeFor[v[1]] or { part = part }
        Destructibles.IndexPart(d, mech, v[1], part)
    end
    mech.hostPart = mech.volumeFor.CHASSIS.part
    mech.status = Rules.Mech(mech.units)
    applyPose(mech, { angles = {}, offsetY = 0, pitch = 0, roll = 0 })
    model.Parent = d.folder
end

local function respawn(d, mech)
    Destructibles.UnindexObject(mech)
    if mech.model then
        mech.model:Destroy()
    end
    construct(d, mech)
end

-- spec: id, position (ground level), yaw (radians, 0 faces -Z)
function TrainingMech.Create(d, spec)
    local mech = {
        kind = "mech", id = spec.id, position = spec.position, yaw = spec.yaw or 0, parts = {},
        onStage = onStage, update = update, respawn = respawn,
    }
    construct(d, mech)
    d.mech = mech
    table.insert(d.objects, mech)
    d.totals.targets += 1
    return mech
end

function TrainingMech.Describe(mech)
    local parts = 0
    for _, group in pairs(mech.partsBy) do
        parts += #group
    end
    return { parts = parts, volumes = #mech.volumes, status = mech.status.status }
end

return TrainingMech
