-- Tiny procedural-part toolkit. Every part it emits is anchored, non-colliding, and carries the
-- rig attributes (`Joint`, `LocalCF`, `Group`) that MechRig consumes.
--
-- Swappable assets: if ServerStorage/IronframeAssets/<ChassisId>/<PartName> exists (a MeshPart
-- authored in Blender), it is cloned in place of the procedural part and inherits the same joint
-- and LocalCF. Sizing/orientation of the imported mesh then follows the artist's pivot.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local MechRig = require(Shared:WaitForChild("MechRig"))

local PartKit = {}
PartKit.__index = PartKit

local METAL = Enum.Material.Metal
local PAINT = Enum.Material.SmoothPlastic -- painted armor reads better than unlit Metal
local NEON = Enum.Material.Neon

local function findImported(chassisId: string, partName: string): BasePart?
    local assets = ServerStorage:FindFirstChild("IronframeAssets")
    local folder = assets and assets:FindFirstChild(chassisId)
    local template = folder and folder:FindFirstChild(partName)
    if template and template:IsA("BasePart") then
        return template
    end
    return nil
end

function PartKit.new(model: Model, chassisId: string)
    return setmetatable({ model = model, chassisId = chassisId, counts = {}, imported = 0 }, PartKit)
end

function PartKit:add(name, joint, size, localCF, color, material, group, shape)
    local part
    local template = findImported(self.chassisId, name)
    if template then
        part = template:Clone()
        self.imported += 1
    else
        part = Instance.new("Part")
        if shape then
            part.Shape = shape
        end
        part.Size = size
    end
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Material = material or (if group == "armor" then PAINT else METAL)
    part.Color = color
    part:SetAttribute("Joint", joint)
    part:SetAttribute("LocalCF", localCF)
    part:SetAttribute("Group", group or "frame")
    part.Parent = self.model
    self.counts[group or "frame"] = (self.counts[group or "frame"] or 0) + 1
    return part
end

function PartKit:box(name, joint, size, cf, color, group, material)
    return self:add(name, joint, size, cf, color, material, group)
end

-- Cylinders: Roblox cylinders run along local X. The cyl* helpers take a cf whose
-- orientation describes where the cylinder should point, then compensate.
function PartKit:cylX(name, joint, length, diameter, cf, color, group, material)
    return self:add(name, joint, Vector3.new(length, diameter, diameter), cf, color, material, group, Enum.PartType.Cylinder)
end

function PartKit:cylY(name, joint, length, diameter, cf, color, group, material)
    return self:add(name, joint, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, 0, math.pi / 2), color, material, group, Enum.PartType.Cylinder)
end

function PartKit:cylZ(name, joint, length, diameter, cf, color, group, material)
    return self:add(name, joint, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, math.pi / 2, 0), color, material, group, Enum.PartType.Cylinder)
end

function PartKit:glow(name, joint, size, cf, color, group)
    return self:add(name, joint, size, cf, color, NEON, group or "glow")
end

function PartKit:glowCylZ(name, joint, length, diameter, cf, color)
    return self:cylZ(name, joint, length, diameter, cf, color, "glow", NEON)
end

-- Hydraulic actuator whose ends follow two different joints: housing + clamp collar at A,
-- rod + rod-end boot at B. Placement is by (end, offset) so MechRig needs no per-part sizes.
function PartKit:link(spec, housingColor, rodColor)
    local world = MechRig.Solve(CFrame.identity, nil)
    local a = world[spec.jointA]:PointToWorldSpace(spec.pointA)
    local b = world[spec.jointB]:PointToWorldSpace(spec.pointB)
    local rest = (b - a).Magnitude
    local function piece(role, joint, length, diameter, color, endName, offset, material)
        local part = self:cylX("Hyd_" .. spec.id .. "_" .. role, joint, length, diameter, CFrame.identity, color, "hydraulic", material)
        part:SetAttribute("LinkId", spec.id)
        part:SetAttribute("LinkRole", role)
        part:SetAttribute("LinkEnd", endName)
        part:SetAttribute("LinkOffset", offset)
        return part
    end
    local housingLength, rodLength = rest * 0.58, rest * 0.64
    local housing = piece("Housing", spec.jointA, housingLength, 0.66, housingColor, "A", housingLength / 2)
    piece("Collar", spec.jointA, 0.28, 0.95, rodColor, "A", housingLength * 0.72, Enum.Material.Metal)
    local rod = piece("Rod", spec.jointB, rodLength, 0.3, rodColor, "B", rodLength / 2, Enum.Material.Metal)
    piece("Boot", spec.jointB, 0.34, 0.58, housingColor, "B", 0.2)
    return housing, rod
end

function PartKit:addLinks(housingColor, rodColor)
    for _, spec in ipairs(RigSpec.Links) do
        self:link(spec, housingColor, rodColor)
    end
end

return PartKit
