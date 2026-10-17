-- Hangar dressing: procedural machinery, pipework, storage and ALL lighting, plus placement of the accepted
-- AI-generated models through AssetLibrary. To add assets from a later batch, add rows to the PLACEMENTS
-- table below (ids come from IronframeShared/AssetRegistry); this builder needs no other change.

local HangarKit = require(script.Parent.HangarKit)
local Dressing = {}

local part, cyl, glow, sign, light = HangarKit.part, HangarKit.cyl, HangarKit.glow, HangarKit.sign, HangarKit.light
local COLOR = HangarKit.COLOR
local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local METAL = Enum.Material.Metal
local AIM = V3(0, 9, 0) -- aim point on the Bastion (bay-local)

-- ---------------------------------------------------------------------------------------------
-- AI asset placements: { id, position (bay-local, y = floor/rest line), facing = bay-local point the model's
-- front (-Z) looks at, scale, grounded }. Instances per asset are the number of rows using the id.
-- ---------------------------------------------------------------------------------------------
local FLOODLIGHT_SCALE = 1.8
local PLACEMENTS = {
    -- service arms flanking the platform, reaching toward the Bastion
    { "HNG_003", V3(-34, 0, 6), V3(-6, 0, 4), 1.6, true },
    { "HNG_003", V3(34, 0, 6), V3(6, 0, 4), 1.6, true },
    -- maintenance lifts: one working beside the platform, one parked near the doors
    { "HNG_002", V3(-38, 0, 20), V3(-38, 0, 0), 1.7, true },
    { "HNG_002", V3(40, 0, 38), V3(20, 0, 38), 1.7, true },
    -- diagnostic stations: two at the platform, three east wall, two west wall
    { "HNG_004", V3(-27, 0, -25), V3(0, 0, 0), 1.4, true },
    { "HNG_004", V3(27, 0, -25), V3(0, 0, 0), 1.4, true },
    { "HNG_004", V3(55, 0, -34), V3(0, 0, -34), 1.4, true },
    { "HNG_004", V3(55, 0, -16), V3(0, 0, -16), 1.4, true },
    { "HNG_004", V3(55, 0, 2), V3(0, 0, 2), 1.4, true },
    { "HNG_004", V3(-55, 0, -40), V3(0, 0, -40), 1.4, true },
    { "HNG_004", V3(-55, 0, -22), V3(0, 0, -22), 1.4, true },
    -- tool cabinets: west storage run and two on the east side
    { "HNG_006", V3(-57, 0, -2), V3(0, 0, -2), 1.5, true },
    { "HNG_006", V3(-57, 0, 5), V3(0, 0, 5), 1.5, true },
    { "HNG_006", V3(-57, 0, 12), V3(0, 0, 12), 1.5, true },
    { "HNG_006", V3(-57, 0, 19), V3(0, 0, 19), 1.5, true },
    { "HNG_006", V3(57, 0, 22), V3(0, 0, 22), 1.5, true },
    { "HNG_006", V3(57, 0, 29), V3(0, 0, 29), 1.5, true },
    -- cable reels near the doors and the east wall
    { "HNG_005", V3(-54, 0, 34), V3(0, 0, 30), 1.7, true },
    { "HNG_005", V3(-54, 0, 39), V3(0, 0, 36), 1.7, true },
    { "HNG_005", V3(-54, 0, 44), V3(0, 0, 40), 1.7, true },
    { "HNG_005", V3(54, 0, -46), V3(0, 0, -44), 1.7, true },
    { "HNG_005", V3(54, 0, -52), V3(0, 0, -50), 1.7, true },
}

-- Floodlights hang from structure: { position (bay-local, y = pivot), role }. role selects the beam.
local FLOODLIGHTS = {
    { V3(-24, 27.6, 3.4), "key" }, -- bridge girder, front-left of the Bastion
    { V3(24, 27.6, 3.4), "fill" },
    { V3(-8, 27.6, 8.6), "key2" },
    { V3(8, 27.6, 8.6), "fill2" },
    { V3(-46, 30.7, -30), "side" },
    { V3(46, 30.7, -30), "side" },
    { V3(-30, 36.9, -24), "high" },
    { V3(30, 36.9, -24), "high" },
}

local LIGHT_ROLES = {
    key = { color = COLOR.warm, brightness = 1.3, range = 90, angle = 55, shadows = true },
    fill = { color = Color3.fromRGB(190, 215, 255), brightness = 0.55, range = 90, angle = 55 },
    key2 = { color = COLOR.warm, brightness = 0.7, range = 80, angle = 50 },
    fill2 = { color = Color3.fromRGB(190, 215, 255), brightness = 0.4, range = 80, angle = 50 },
    side = { color = COLOR.warm, brightness = 0.5, range = 90, angle = 60 },
    high = { color = Color3.fromRGB(210, 225, 255), brightness = 0.5, range = 100, angle = 60 },
}

local function emitter(bay, name, pos, target, role)
    local p = part(bay, name, V3(0.4, 0.4, 0.4), CFrame.lookAt(pos, target) * ANG(math.pi / 2, 0, 0), COLOR.black, METAL, { shadow = false, transparency = 1 })
    light(p, "SpotLight", role.color, role.range, role.brightness, { Angle = role.angle, Face = Enum.NormalId.Bottom, Shadows = role.shadows == true })
    return p
end

local function transformerBank(bay, at, x, z, s)
    part(bay, "Transformer", V3(5, 9, 6), at(x, 4.5, z), COLOR.oliveDark, METAL)
    part(bay, "TransformerCap", V3(5.4, 0.8, 6.4), at(x, 9.4, z), COLOR.steel, METAL)
    for i = 0, 5 do
        part(bay, "CoolingFin", V3(0.5, 7, 6.2), at(x - s * 2.8, 4.5, z - 2.5 + i), COLOR.steel, METAL, { shadow = false })
    end
    for i = 0, 2 do
        cyl(bay, "Insulator", "Y", 1.4, 0.8, at(x + (i - 1) * 1.6, 10.4, z), COLOR.lightSteel, Enum.Material.SmoothPlastic)
    end
    glow(bay, "TransformerStatus", V3(0.2, 0.5, 0.5), at(x + s * 0, 6.5, z - 3.1), COLOR.green)
    sign(bay, "VoltageSign", "HIGH VOLTAGE", V3(3.2, 1, 0.12), at(x, 3, z - 3.12), Enum.NormalId.Front, COLOR.hazardYellow, COLOR.black)
end

local function pipeRun(bay, at, x, y, dia, color)
    cyl(bay, "Pipe", "Z", 112, dia, at(x, y, 0), color, METAL)
    for z = -50, 50, 10 do
        cyl(bay, "PipeFlange", "Z", 0.5, dia + 0.5, at(x, y, z), COLOR.steel, METAL, { shadow = false })
    end
    for z = -45, 45, 18 do
        part(bay, "PipeSupport", V3(dia + 0.4, 0.4, 0.8), at(x + (x > 0 and 1 or -1) * 0.2, y - dia / 2 - 0.3, z), COLOR.gunmetal, METAL, { shadow = false })
    end
end

local function wallServices(bay, at)
    for _, s in ipairs({ -1, 1 }) do
        local x = s * 60.2
        pipeRun(bay, at, x, 5, 1.3, COLOR.gunmetal)
        pipeRun(bay, at, x, 8.2, 0.9, COLOR.oliveDark)
        for z = -36, 36, 24 do
            cyl(bay, "ValveWheel", "X", 0.3, 1.6, at(s * 59.2, 8.2, z), COLOR.hazardYellow, METAL, { shadow = false })
            part(bay, "ValveBody", V3(1.0, 1.4, 1.0), at(s * 59.7, 8.2, z), COLOR.steel, METAL, { shadow = false })
        end
        -- cable tray above the catwalk
        part(bay, "CableTray", V3(1.4, 0.4, 112), at(x - s * 0.2, 19.5, 0), COLOR.steel, METAL)
        for i = 0, 3 do
            cyl(bay, "CableBundle", "Z", 112, 0.35, at(x - s * 0.2, 20 + (i % 2) * 0.35, -0.4 + i * 0.35), if i == 2 then COLOR.hazardYellow else COLOR.black, Enum.Material.SmoothPlastic, { shadow = false })
        end
        for z = -50, 50, 10 do
            part(bay, "TrayHanger", V3(0.3, 1.4, 0.3), at(x - s * 0.2, 20.2, z), COLOR.steel, METAL, { shadow = false })
        end
        -- overhead ventilation duct with grills and branch stubs
        part(bay, "Duct", V3(5, 4.5, 108), at(s * 38, 36.5, 0), COLOR.steel, METAL)
        part(bay, "DuctBand", V3(5.2, 0.5, 108), at(s * 38, 38.5, 0), COLOR.oliveDark, METAL, { shadow = false })
        for z = -48, 48, 16 do
            part(bay, "DuctJoint", V3(5.5, 4.9, 0.6), at(s * 38, 36.5, z), COLOR.gunmetal, METAL, { shadow = false })
            for _, h in ipairs({ -1.1, 0, 1.1 }) do
                part(bay, "DuctGrill", V3(0.1, 0.4, 3.2), at(s * 38 - s * 2.55, 36.5 + h, z + 8), COLOR.black, METAL, { shadow = false })
            end
            part(bay, "DuctHanger", V3(0.3, 4, 0.3), at(s * 38 - 2.6, 40.2, z), COLOR.steel, METAL, { shadow = false })
            part(bay, "DuctHanger", V3(0.3, 4, 0.3), at(s * 38 + 2.6, 40.2, z), COLOR.steel, METAL, { shadow = false })
        end
    end
end

local function stationsAndStorage(bay, at)
    -- transformer banks under the east catwalk, wall display, glowing status panels
    transformerBank(bay, at, 56.5, -46, 1)
    transformerBank(bay, at, 56.5, -40, 1)
    transformerBank(bay, at, 56.5, 44, 1)
    sign(bay, "WallDisplayE", "IF-42 BASTION\nNOMINAL", V3(14, 6, 0.4), at(60.35, 24, -27) * ANG(0, math.pi / 2, 0), Enum.NormalId.Front, COLOR.black, COLOR.cool)
    glow(bay, "WallDisplayEdgeE", V3(0.2, 6.4, 14.4), at(60.8, 24, -27), COLOR.cool, { transparency = 0.7 })
    sign(bay, "WallDisplayW", "MAINTENANCE\nBAY 01 ACTIVE", V3(14, 6, 0.4), at(-60.35, 24, 9) * ANG(0, -math.pi / 2, 0), Enum.NormalId.Front, COLOR.black, COLOR.amber)
    -- storage: crates, barrels, pallets (north-east corner and west work area)
    for i = 0, 1 do
        for j = 0, 1 do
            part(bay, "Crate", V3(8, 5, 4.4), at(44 - j * 9, 2.5, 50 - i * 5.2), COLOR.oliveDark, METAL)
            part(bay, "CrateLid", V3(8.2, 0.4, 4.6), at(44 - j * 9, 5.2, 50 - i * 5.2), COLOR.steel, METAL, { shadow = false })
        end
    end
    part(bay, "CrateStacked", V3(8, 5, 4.4), at(44, 7.9, 50), COLOR.olive, METAL)
    part(bay, "CrateStackedStripe", V3(8.1, 0.7, 4.5), at(44, 8.6, 50), COLOR.hazardYellow, METAL, { shadow = false })
    for i = 0, 7 do
        local x, z = 34 + (i % 4) * 3.4, 22 + math.floor(i / 4) * 3.4
        cyl(bay, "Barrel", "Y", 3.4, 2.6, at(x, 1.7, z), COLOR.gunmetal, METAL)
        cyl(bay, "BarrelBand", "Y", 0.5, 2.7, at(x, 2.4, z), COLOR.hazardYellow, METAL, { shadow = false })
    end
    part(bay, "Pallet", V3(11, 0.5, 8), at(36.5, 0.25, 24), COLOR.concreteDark, METAL, { shadow = false })
    -- west work area: workbench with vise and tool board
    part(bay, "BenchTop", V3(12, 0.5, 4.5), at(-50, 3.4, -30), COLOR.steel, Enum.Material.DiamondPlate)
    for _, dx in ipairs({ -5.4, 5.4 }) do
        for _, dz in ipairs({ -1.8, 1.8 }) do
            part(bay, "BenchLeg", V3(0.5, 3.2, 0.5), at(-50 + dx, 1.6, -30 + dz), COLOR.gunmetal, METAL, { shadow = false })
        end
    end
    part(bay, "BenchVise", V3(1.4, 1.2, 1.2), at(-46, 4.2, -30), COLOR.oliveDark, METAL)
    part(bay, "ToolBoard", V3(10, 4.5, 0.3), at(-60.5, 7.5, -30) * ANG(0, math.pi / 2, 0), COLOR.oliveDark, METAL)
end

local function lighting(bay, at)
    -- warm maintenance lamps under the catwalks and above the doors, cooler fill from the ceiling
    for _, inst in ipairs(bay:GetDescendants()) do
        if inst:IsA("BasePart") and (inst.Name == "CatwalkLampW" or inst.Name == "CatwalkLampE") then
            light(inst, "PointLight", COLOR.warm, 24, 0.9)
        end
    end
    for _, x in ipairs({ -8, 8 }) do
        local p = part(bay, "DoorGlowEmitter", V3(0.4, 0.4, 0.4), at(x * 1.6, 32, 52), COLOR.black, METAL, { shadow = false, transparency = 1 })
        light(p, "PointLight", COLOR.amber, 22, 0.8)
    end
    for _, x in ipairs({ -26, 26 }) do
        for _, z in ipairs({ -26, 26 }) do
            local p = part(bay, "CoolFillEmitter", V3(0.4, 0.4, 0.4), at(x, 38, z), COLOR.black, METAL, { shadow = false, transparency = 1 })
            light(p, "PointLight", Color3.fromRGB(160, 195, 255), 55, 0.45)
        end
    end
    -- cool rim from the door side, behind the Bastion, separating its silhouette from the dark doors
    emitter(bay, "RimEmitter", at(0, 30, 40).Position, at(AIM.X, AIM.Y, AIM.Z).Position, { color = Color3.fromRGB(150, 195, 255), brightness = 1.3, range = 80, angle = 45 })
end

function Dressing.Build(bay, origin, AssetLibrary)
    local function at(x, y, z)
        return CF(origin + V3(x, y, z))
    end
    local assetFolder = Instance.new("Folder")
    assetFolder.Name = "AIAssets"
    assetFolder.Parent = bay

    wallServices(bay, at)
    stationsAndStorage(bay, at)

    local missing = {}
    for _, row in ipairs(PLACEMENTS) do
        local id, pos, facing, scale, grounded = row[1], row[2], row[3], row[4], row[5]
        local worldPos, worldFacing = origin + pos, origin + Vector3.new(facing.X, pos.Y, facing.Z)
        local model = AssetLibrary.Place(id, CFrame.lookAt(worldPos, worldFacing), { scale = scale, grounded = grounded, parent = assetFolder, name = id })
        if not model then
            missing[id] = true
        elseif id == "HNG_004" then
            -- glowing diagnostic screen: faint cyan light in front of the console
            local body = model:FindFirstChildWhichIsA("MeshPart", true)
            local p = part(model, "ScreenGlow", V3(0.3, 0.3, 0.3), CFrame.lookAt(model:GetPivot().Position + Vector3.new(0, 1.8, 0), worldFacing) * CFrame.new(0, 0, -3), COLOR.black, METAL, { shadow = false, transparency = 1 })
            light(p, "PointLight", COLOR.cool, 11, 0.5)
            _ = body
        end
    end
    for id in pairs(missing) do
        warn("[IF-HANGAR] asset unavailable, placements skipped (not substituted): " .. id)
    end

    -- hanging floodlights (AI model) with matching emitters that actually light the Bastion
    for _, row in ipairs(FLOODLIGHTS) do
        local pos, roleName = row[1], row[2]
        local worldPos = origin + pos
        local look = CFrame.lookAt(worldPos, Vector3.new(origin.X, worldPos.Y, origin.Z))
        AssetLibrary.Place("HNG_007", look, { scale = FLOODLIGHT_SCALE, parent = assetFolder, name = "HNG_007" })
        local front = look * CFrame.new(0, -0.8, -3.2)
        emitter(bay, "Floodlight_" .. roleName, front.Position, origin + AIM, LIGHT_ROLES[roleName])
    end

    lighting(bay, at)
end

return Dressing
