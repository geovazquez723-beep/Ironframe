local Lighting = game:GetService("Lighting")

local WorldBuilder = {}
local BAY_WIDTH = 105

local function createPart(parent, name, size, position, color, material)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.Position = position
    part.Anchored = true
    part.Material = material or Enum.Material.Metal
    part.Color = color
    part.Parent = parent
    return part
end

function WorldBuilder.BuildBay(index)
    local x = (index - 1) * BAY_WIDTH
    local bay = Instance.new("Model")
    bay.Name = "Bay_" .. index
    bay.Parent = workspace:WaitForChild("IronframeHangar")
    local floorColor = Color3.fromRGB(32, 38, 44)
    local steel = Color3.fromRGB(67, 78, 88)
    local light = Color3.fromRGB(245, 160, 60)
    createPart(bay, "Floor", Vector3.new(94, 1, 78), Vector3.new(x, -0.5, 0), floorColor)
    createPart(bay, "MaintenancePlinth", Vector3.new(29, 1.3, 27), Vector3.new(x, -0.25, 0), steel)
    for _, sx in ipairs({ -19, 19 }) do
        for _, sz in ipairs({ -15, 15 }) do
            createPart(bay, "GantryPillar", Vector3.new(2, 23, 2), Vector3.new(x+sx, 11, sz), steel)
            local lamp = createPart(bay, "SafetyLamp", Vector3.new(2.5, 0.5, 2.5),
                Vector3.new(x+sx, 21.5, sz), light, Enum.Material.Neon)
            local pointLight = Instance.new("PointLight")
            pointLight.Range = 26
            pointLight.Brightness = 2.3
            pointLight.Color = light
            pointLight.Parent = lamp
        end
    end
    createPart(bay, "OverheadRailFront", Vector3.new(40, 1.2, 1.4), Vector3.new(x, 22, -15), steel)
    createPart(bay, "OverheadRailRear", Vector3.new(40, 1.2, 1.4), Vector3.new(x, 22, 15), steel)
    createPart(bay, "RearWall", Vector3.new(92, 29, 1), Vector3.new(x, 14, 37), Color3.fromRGB(52, 62, 74))
    createPart(bay, "SafetyLineA", Vector3.new(33, 0.1, 0.5), Vector3.new(x, 0.08, -17), light, Enum.Material.Neon)
    createPart(bay, "SafetyLineB", Vector3.new(33, 0.1, 0.5), Vector3.new(x, 0.08, 17), light, Enum.Material.Neon)
    -- Key / fill / rim lights so armor layering reads clearly in the showroom.
    local function spot(name, offset, color, brightness, range)
        local housing = createPart(bay, name, Vector3.new(2, 1, 2), Vector3.new(x, 0, 0) + offset, steel)
        housing.Transparency = 1 -- emitter only; a solid housing would self-occlude its own beam
        housing.CanCollide = false
        local light = Instance.new("SpotLight")
        light.Face = Enum.NormalId.Bottom
        light.Angle = 80
        light.Range = range or 70
        light.Brightness = brightness
        light.Color = color
        light.Shadows = false
        light.Parent = housing
        -- Aim the beam at the mech by rotating the housing toward the plinth centre.
        housing.CFrame = CFrame.lookAt(housing.Position, Vector3.new(x, 8, 0)) * CFrame.Angles(math.pi / 2, 0, 0)
    end
    spot("KeyLight", Vector3.new(-14, 18, -32), Color3.fromRGB(255, 244, 228), 2.5, 120)
    spot("FillLight", Vector3.new(20, 16, -30), Color3.fromRGB(190, 215, 255), 1.5, 120)
    spot("RimLight", Vector3.new(0, 24, 28), Color3.fromRGB(120, 210, 255), 0.8)
    return Vector3.new(x, 0.45, 0)
end

function WorldBuilder.Initialize()
    if not workspace:FindFirstChild("IronframeHangar") then
        local hangar = Instance.new("Folder")
        hangar.Name = "IronframeHangar"
        hangar.Parent = workspace
    end
    if not workspace:FindFirstChild("IronframeMechs") then
        local mechs = Instance.new("Folder")
        mechs.Name = "IronframeMechs"
        mechs.Parent = workspace
    end
    Lighting.ClockTime = 19.5
    Lighting.Brightness = 2.2
    Lighting.ExposureCompensation = 0
    Lighting.Ambient = Color3.fromRGB(70, 80, 94)
    Lighting.OutdoorAmbient = Color3.fromRGB(60, 70, 85)
    print("[IF-STEP-01] Industrial garage world initialized")
end

return WorldBuilder
