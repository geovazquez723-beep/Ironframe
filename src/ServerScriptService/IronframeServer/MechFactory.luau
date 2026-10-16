local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local ComponentRegistry = require(Shared:WaitForChild("ComponentRegistry"))

local Factory = {}
local GUNMETAL = Color3.fromRGB(69, 80, 91)
local ARMOR = Color3.fromRGB(103, 116, 125)
local DARK = Color3.fromRGB(37, 44, 52)
local ACCENT = Color3.fromRGB(246, 169, 59)
local LIGHT = Color3.fromRGB(90, 222, 240)

local function block(parent, name, size, location, color, material)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(location)
    part.Anchored = true
    part.CanCollide = false
    part.Material = material or Enum.Material.Metal
    part.Color = color or ARMOR
    part.Parent = parent
    return part
end

function Factory.Create(ownerUserId, loadout, position)
    local model = Instance.new("Model")
    model.Name = tostring(ownerUserId)
    model:SetAttribute("OwnerUserId", ownerUserId)
    model:SetAttribute("State", "OPERATIONAL")
    model:SetAttribute("ChassisId", loadout.chassisId)

    local root = block(model, "RigRoot", Vector3.new(1, 1, 1), Vector3.new(0, 0, 0), DARK)
    root.Transparency = 1
    model.PrimaryPart = root

    block(model, "CentralTorso", Vector3.new(6.3, 5.4, 4.3), Vector3.new(0, 11.0, 0), GUNMETAL)
    block(model, "TorsoChestArmor", Vector3.new(5.2, 3.0, 0.7), Vector3.new(0, 11.7, -2.35), ARMOR)
    block(model, "Cockpit", Vector3.new(3.0, 1.4, 0.7), Vector3.new(0, 12.9, -2.78), LIGHT, Enum.Material.Neon)
    block(model, "HeadSensor", Vector3.new(2.5, 1.1, 2.2), Vector3.new(0, 14.5, -0.25), DARK)
    block(model, "HeadSensorGlow", Vector3.new(1.8, 0.35, 0.35), Vector3.new(0, 14.6, -1.5), LIGHT, Enum.Material.Neon)
    block(model, "Pelvis", Vector3.new(5, 2.2, 3.2), Vector3.new(0, 7.25, 0.2), GUNMETAL)
    block(model, "BackReactor", Vector3.new(3.8, 3.4, 1.2), Vector3.new(0, 10.9, 2.8), DARK)
    block(model, "ReactorGlow", Vector3.new(2.0, 1.5, 0.25), Vector3.new(0, 11, 3.55), ACCENT, Enum.Material.Neon)

    for _, side in ipairs({ -1, 1 }) do
        local label = side == -1 and "Left" or "Right"
        block(model, label.."UpperArm", Vector3.new(2.4, 3.9, 2.7), Vector3.new(side*4.2, 11.4, 0), GUNMETAL)
        block(model, label.."LowerArm", Vector3.new(2.0, 3.0, 2.4), Vector3.new(side*4.2, 8.4, 0), ARMOR)
        block(model, label.."UpperLeg", Vector3.new(2.6, 3.7, 3.1), Vector3.new(side*1.65, 5.2, 0.3), ARMOR)
        block(model, label.."KneeJoint", Vector3.new(2.0, 1.0, 2.7), Vector3.new(side*1.65, 3.4, -0.2), DARK)
        block(model, label.."LowerLeg", Vector3.new(2.8, 2.5, 3.2), Vector3.new(side*1.65, 2.0, 0.3), GUNMETAL)
        block(model, label.."Foot", Vector3.new(3.0, 1.0, 4.3), Vector3.new(side*1.65, 0.6, -0.8), DARK)
        block(model, label.."ShoulderArmor", Vector3.new(3.2, 2.0, 3.9), Vector3.new(side*3.8, 13.8, 0), ARMOR)
    end

    local mountPositions = {
        left_arm = Vector3.new(-4.5, 9.1, -2.3),
        right_arm = Vector3.new(4.5, 9.1, -2.3),
        left_shoulder = Vector3.new(-3.8, 15.3, -1.0),
        right_shoulder = Vector3.new(3.8, 15.3, -1.0),
        left_torso = Vector3.new(-2.0, 11.0, -3.5),
        right_torso = Vector3.new(2.0, 11.0, -3.5),
    }
    for socket, weaponId in pairs(loadout.mounts) do
        local weapon = ComponentRegistry[weaponId]
        local location = mountPositions[socket]
        if weapon and location then
            local caliber = 0.65 + weapon.size * 0.28
            local length = 1.3 + weapon.size * 0.9
            block(model, "Weapon_" .. socket, Vector3.new(caliber, caliber, length),
                location + Vector3.new(0, 0, -length/3), DARK)
            local glowColor = weapon.family == "energy" and LIGHT or ACCENT
            block(model, "Muzzle_" .. socket, Vector3.new(caliber*0.6, caliber*0.6, 0.2),
                location + Vector3.new(0, 0, -length*0.82), glowColor, Enum.Material.Neon)
        end
    end

    model:PivotTo(CFrame.new(position))
    return model
end

return Factory
