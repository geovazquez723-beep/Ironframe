-- Builds a rigged, anchored mech model from a loadout and poses it at rest.
-- Visuals live in BastionBuilder/WeaponModules/PartKit; the rig contract lives in RigSpec.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local MechRig = require(Shared:WaitForChild("MechRig"))
local PartKit = require(script.Parent.PartKit)
local BastionBuilder = require(script.Parent.BastionBuilder)

local Factory = {}

local BUILDERS = { IF42_BASTION = BastionBuilder }
local VARIANTS = { BALANCED = "STANDARD", ENERGY = "ENERGY", MISSILE = "MISSILE", ROOK = "ROOK" }

-- options.useAssets = false forces the all-procedural build (tests, and the documented fallback when assets are missing).
function Factory.Create(ownerUserId, presetId, loadout, position, options)
    local builder = assert(BUILDERS[loadout.chassisId], "No visual builder for " .. tostring(loadout.chassisId))
    local model = Instance.new("Model")
    model.Name = tostring(ownerUserId)
    model:SetAttribute("OwnerUserId", ownerUserId)
    model:SetAttribute("State", "OPERATIONAL")
    model:SetAttribute("ChassisId", loadout.chassisId)
    model:SetAttribute("PresetId", presetId)
    -- Pilots are never damageable or targetable; this is advertised on the model for future systems.
    model:SetAttribute("PilotTargetable", false)

    local rootCF = CFrame.new(position)
    model:SetAttribute("BaseCF", rootCF)

    local kit = PartKit.new(model, loadout.chassisId)
    builder.Build(kit, {
        presetId = presetId,
        variant = VARIANTS[presetId] or "STANDARD",
        reinforced = loadout.systems and loadout.systems.armor == "ARMOR_REINFORCED",
        loadout = loadout,
        useAssets = not (options and options.useAssets == false),
    })
    model:SetAttribute("AiMeshParts", kit.meshParts)
    model.PrimaryPart = model:FindFirstChild("RigRoot")

    local rig = MechRig.Bind(model)
    model:SetAttribute("PartCount", #rig.parts + #rig.linkParts)
    MechRig.Apply(rig, rootCF, nil)
    return model, kit
end

-- Rig diagnostics for the UI and self tests.
function Factory.Describe(model)
    local info = { parts = 0, joints = 0, links = 0, socketsFilled = 0, socketsTotal = #RigSpec.SocketOrder, armorPanels = 0, imported = 0, meshParts = 0 }
    if not model then
        return info
    end
    local jointsSeen, socketsSeen = {}, {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            info.parts += 1
            local joint = d:GetAttribute("Joint")
            if joint then
                jointsSeen[joint] = true
            end
            if d:GetAttribute("LinkRole") == "Housing" then
                info.links += 1
            end
            if d:IsA("MeshPart") then
                info.meshParts += 1
            end
            if d:GetAttribute("Group") == "armor" then
                info.armorPanels += 1
            end
            local socket = string.match(d.Name, "^Weapon_(%a+_%a+)_")
            if socket then
                socketsSeen[socket] = true
            end
        end
    end
    for _ in pairs(jointsSeen) do
        info.joints += 1
    end
    for _ in pairs(socketsSeen) do
        info.socketsFilled += 1
    end
    return info
end

return Factory
