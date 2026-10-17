-- World setup and per-player maintenance bay construction.
-- Architecture lives in HangarArchitecture, props/lighting/AI-asset placement in HangarDressing, accepted
-- AI-generated models come from AssetLibrary (cloud ids from IronframeShared/AssetRegistry).

local Lighting = game:GetService("Lighting")

local AssetLibrary = require(script.Parent.AssetLibrary)
local HangarArchitecture = require(script.Parent.HangarArchitecture)
local HangarDressing = require(script.Parent.HangarDressing)
local ProvingGround = require(script.Parent.ProvingGround)

local WorldBuilder = {}
local BAY_WIDTH = 140 -- interior is 124 wide; keeps neighbouring bays' walls apart

local function ensure(parent, className, name)
    local existing = parent:FindFirstChild(name)
    if existing then
        return existing
    end
    local inst = Instance.new(className)
    inst.Name = name
    inst.Parent = parent
    return inst
end

function WorldBuilder.BuildBay(index)
    local x = (index - 1) * BAY_WIDTH
    local origin = Vector3.new(x, 0, 0)
    local bay = Instance.new("Model")
    bay.Name = "Bay_" .. index
    bay.Parent = workspace:WaitForChild("IronframeHangar")
    HangarArchitecture.Build(bay, origin)
    HangarDressing.Build(bay, origin, AssetLibrary)
    ProvingGround.Build(bay, origin)
    return Vector3.new(x, 0.45, 0), bay
end

function WorldBuilder.Initialize()
    ensure(workspace, "Folder", "IronframeHangar")
    ensure(workspace, "Folder", "IronframeMechs")

    -- The template SpawnLocation sits under bay 1's mech; hide it (runtime only, not saved). Avatars are
    -- parked at the operator station by Main anyway.
    for _, spawn in ipairs(workspace:GetDescendants()) do
        if spawn:IsA("SpawnLocation") then
            spawn.Transparency = 1
            spawn.CanCollide = false
            for _, child in ipairs(spawn:GetChildren()) do
                if child:IsA("Decal") or child:IsA("Texture") then child:Destroy() end
            end
        end
    end

    -- Enclosed industrial interior: low cool ambient, warm local lights (see HangarDressing), light haze for
    -- depth, restrained bloom so only emissive details bloom.
    Lighting.ClockTime = 14
    Lighting.Brightness = 1
    Lighting.ExposureCompensation = 0
    Lighting.Ambient = Color3.fromRGB(42, 50, 64)
    Lighting.OutdoorAmbient = Color3.fromRGB(42, 50, 64)
    Lighting.EnvironmentDiffuseScale = 0.25
    Lighting.EnvironmentSpecularScale = 0.25
    Lighting.GlobalShadows = true
    local atmosphere = ensure(Lighting, "Atmosphere", "IronframeAtmosphere")
    atmosphere.Density = 0.28
    atmosphere.Offset = 0
    atmosphere.Color = Color3.fromRGB(48, 58, 74)
    atmosphere.Decay = Color3.fromRGB(22, 28, 40)
    atmosphere.Glare = 0
    atmosphere.Haze = 0.6
    local bloom = ensure(Lighting, "BloomEffect", "IronframeBloom")
    bloom.Intensity = 0.28
    bloom.Size = 24
    bloom.Threshold = 1.7
    local grade = ensure(Lighting, "ColorCorrectionEffect", "IronframeGrade")
    grade.Contrast = 0.1
    grade.Saturation = -0.04
    grade.TintColor = Color3.fromRGB(250, 252, 255)

    AssetLibrary.Load()
    print(string.format("[IF-COCKPIT] Replicated %d cockpit AI assets to clients", AssetLibrary.Publish("CPT_", "IronframeCockpitAssets")))
    print("[IF-STEP-01] Industrial hangar world initialized")
end

return WorldBuilder
