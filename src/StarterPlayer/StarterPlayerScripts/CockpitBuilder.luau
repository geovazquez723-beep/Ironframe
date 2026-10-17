-- Client-only IF-42 Bastion cockpit interior (M06A).
--
-- Everything here is built on the client from controlled procedural geometry (plus optional AI-generated decorative
-- meshes, CPT_001..CPT_004, replicated read-only by the server) and is never replicated to other players. All parts are
-- authored in the TORSO JOINT FRAME (RigSpec: mech faces -Z, +X right, +Y up) around a root at the origin, so
-- `Builder.Place(cockpit, torsoCF)` is the only per-frame transform needed to keep the interior glued to the animated
-- torso. The model is parented to Workspace only while the pilot is inside, so it costs nothing in the garage view.
--
-- Layout (Torso frame, eye at Config.EYE_OFFSET):
--   forward armored canopy with A-pillars       z = -3.5      sill y 3.55, header y 5.4
--   dash cowl + 3 multifunction displays        z = -2.6      screens tilted to face the pilot
--   left / right wing consoles                  x = +-1.9     each carries one SurfaceGui instrument
--   overhead equipment panel                    y = 5.2       diagnostic display + status LEDs
--   seat, control sticks, pedals, ribs, conduit, wiring, equipment housings
-- The central forward cone (+-37 deg wide, +21/-15 deg tall) is free of structure except two hairline mullions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("IronframeShared"):WaitForChild("CockpitConfig"))

local Builder = {}

local V, C, A = Vector3.new, CFrame.new, CFrame.Angles
local COLORS = Config.COLORS
local METAL, PLASTIC, NEON, GLASS = Enum.Material.Metal, Enum.Material.SmoothPlastic, Enum.Material.Neon, Enum.Material.Glass

local GUN = Color3.fromRGB(40, 44, 49)
local GRAPH = Color3.fromRGB(30, 33, 37)
local DARK = Color3.fromRGB(17, 19, 22)
local STEEL = Color3.fromRGB(78, 84, 90)
local CABLE = Color3.fromRGB(12, 13, 15)
local HAZARD = Color3.fromRGB(196, 150, 36)
local MESH_TINT = Color3.fromRGB(150, 158, 166)

export type Screen = { part: Part, width: number, height: number }
export type Cockpit = {
    model: Model,
    root: Part,
    screens: { [string]: Screen },
    indicators: { { part: Part, onColor: Color3, offColor: Color3, order: number, group: string } },
    lights: { { light: PointLight, brightness: number, baseColor: Color3 } },
    glowParts: { { part: Part, onColor: Color3, offColor: Color3 } },
    stats: { parts: number, meshParts: number, screens: number, indicators: number, lights: number, aiAssets: { string } },
}

-- AI mesh templates live in ReplicatedStorage/IronframeCockpitAssets (written by the server, read-only here).
local function findTemplate(id: string): Model?
    local folder = ReplicatedStorage:FindFirstChild("IronframeCockpitAssets")
    local template = folder and folder:FindFirstChild(id)
    if template and template:IsA("Model") then
        return template
    end
    return nil
end

function Builder.Build(): Cockpit
    local model = Instance.new("Model")
    model.Name = "IronframeCockpit"
    local root = Instance.new("Part")
    root.Name = "CockpitRoot"
    root.Size = V(0.2, 0.2, 0.2)
    root.Transparency = 1
    root.Anchored, root.CanCollide, root.CanQuery, root.CanTouch = true, false, false, false
    root.CFrame = CFrame.identity
    root.Parent = model
    model.PrimaryPart = root

    local cockpit: Cockpit = {
        model = model, root = root, screens = {}, indicators = {}, lights = {}, glowParts = {},
        stats = { parts = 1, meshParts = 0, screens = 0, indicators = 0, lights = 0, aiAssets = {} },
    }
    local stats = cockpit.stats

    local function P(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, extra: { [string]: any }?): Part
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = cf
        part.Color = color
        part.Material = material or METAL
        part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
        part.CastShadow = size.Magnitude > 1.4 -- big shell pieces shadow-block the hangar floodlights (interior must not be lit through its roof)
        part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
        if extra then
            for key, value in pairs(extra) do
                (part :: any)[key] = value
            end
        end
        part.Parent = model
        stats.parts += 1
        return part
    end
    -- Roblox cylinders run along local X: these orient them along Z (cylZ) or Y (cylY).
    local function cylZ(name: string, length: number, diameter: number, cf: CFrame, color: Color3, material: Enum.Material?)
        return P(name, V(length, diameter, diameter), cf * A(0, math.pi / 2, 0), color, material, { Shape = Enum.PartType.Cylinder })
    end
    local function cylY(name: string, length: number, diameter: number, cf: CFrame, color: Color3, material: Enum.Material?)
        return P(name, V(length, diameter, diameter), cf * A(0, 0, math.pi / 2), color, material, { Shape = Enum.PartType.Cylinder })
    end
    -- Cable / conduit run between two points (cylinder along the segment).
    local function cable(name: string, a: Vector3, b: Vector3, diameter: number, color: Color3?)
        local mid = (a + b) / 2
        local part = P(name, V((b - a).Magnitude, diameter, diameter), CFrame.lookAt(mid, b) * A(0, math.pi / 2, 0), color or CABLE, PLASTIC, { Shape = Enum.PartType.Cylinder })
        return part
    end
    local function led(name: string, cf: CFrame, color: Color3, group: string, order: number, size: Vector3?)
        color = color:Lerp(DARK, 0.4) -- Neon blooms hard in the hangar post-processing; keep indicators restrained
        local dim = color:Lerp(DARK, 0.88)
        local part = P(name, size or V(0.07, 0.07, 0.05), cf, dim, NEON)
        table.insert(cockpit.indicators, { part = part, onColor = color, offColor = dim, order = order, group = group })
        stats.indicators += 1
        return part
    end
    local function strip(name: string, size: Vector3, cf: CFrame, color: Color3)
        local part = P(name, size, cf, color:Lerp(DARK, 0.9), NEON)
        table.insert(cockpit.glowParts, { part = part, onColor = color, offColor = color:Lerp(DARK, 0.9) })
        return part
    end
    local function lamp(name: string, position: Vector3, color: Color3, brightness: number, range: number)
        local holder = P(name, V(0.05, 0.05, 0.05), C(position), DARK, PLASTIC, { Transparency = 1 })
        local light = Instance.new("PointLight")
        light.Color, light.Brightness, light.Range, light.Shadows = color, brightness, range, false
        light.Parent = holder
        table.insert(cockpit.lights, { light = light, brightness = brightness, baseColor = color })
        stats.lights += 1
    end
    -- Instrument display: dark glass panel inside a bolted bezel, tilted toward `target`. Front face is -Z.
    local function screen(key: string, width: number, height: number, position: Vector3, target: Vector3, roll: number?)
        local cf = CFrame.lookAt(position, target) * A(0, 0, roll or 0)
        P(key .. "_Housing", V(width + 0.2, height + 0.2, 0.55), cf * C(0, 0, 0.3), GRAPH)
        P(key .. "_BezelT", V(width + 0.2, 0.09, 0.1), cf * C(0, height / 2 + 0.05, -0.02), STEEL)
        P(key .. "_BezelB", V(width + 0.2, 0.09, 0.1), cf * C(0, -height / 2 - 0.05, -0.02), STEEL)
        P(key .. "_BezelL", V(0.09, height + 0.2, 0.1), cf * C(-width / 2 - 0.05, 0, -0.02), STEEL)
        P(key .. "_BezelR", V(0.09, height + 0.2, 0.1), cf * C(width / 2 + 0.05, 0, -0.02), STEEL)
        for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            cylZ(key .. "_Bolt", 0.04, 0.07, cf * C(corner[1] * (width / 2 + 0.05), corner[2] * (height / 2 + 0.05), -0.09), STEEL, METAL)
        end
        local face = P(key, V(width, height, 0.04), cf, COLORS.black, PLASTIC)
        cockpit.screens[key] = { part = face, width = width, height = height }
        stats.screens += 1
        return cf
    end

    local eye = Config.EYE_OFFSET

    -- ------------------------------------------------------------------------------------------------------------
    -- Structural shell
    -- ------------------------------------------------------------------------------------------------------------
    P("Floor", V(5.3, 0.3, 5.8), C(0, 2.35, -0.55), GRAPH, Enum.Material.DiamondPlate)
    for i = 0, 7 do
        P("FloorRib" .. i, V(5.1, 0.07, 0.14), C(0, 2.52, -3.1 + i * 0.7), DARK)
    end
    P("Roof", V(5.6, 0.3, 5.8), C(0, 5.8, -0.55), GUN)
    for i = 0, 7 do
        P("RoofRib" .. i, V(5.3, 0.2, 0.22), C(0, 5.58, -3.0 + i * 0.75), i % 2 == 0 and DARK or GRAPH)
    end
    P("Bulkhead", V(5.3, 3.5, 0.3), C(0, 4.05, 2.2), GUN)
    cylZ("BulkheadHatch", 0.12, 1.8, C(0, 3.9, 2.02), GRAPH, METAL)
    cylZ("BulkheadHatchRing", 0.14, 2.1, C(0, 3.9, 2.0), STEEL, METAL)
    P("FrontLower", V(5.3, 1.25, 0.5), C(0, 2.95, -3.35), GRAPH)

    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "L" else "R"
        P("Wall" .. t, V(0.3, 3.5, 5.6), C(s * 2.65, 4.05, -0.65), GUN)
        for i = 0, 4 do
            P("WallRib" .. t .. i, V(0.24, 3.3, 0.18), C(s * 2.5, 4.05, -3.05 + i * 1.15), DARK)
            P("WallPanel" .. t .. i, V(0.12, 1.0, 0.9), C(s * 2.52, 3.4 + (i % 2) * 1.2, -2.45 + i * 1.15), if i % 2 == 0 then GRAPH else GUN)
        end
        P("WallRailLow" .. t, V(0.2, 0.14, 5.4), C(s * 2.5, 3.2, -0.65), STEEL)
        P("WallRailHigh" .. t, V(0.2, 0.14, 5.4), C(s * 2.5, 5.2, -0.65), STEEL)
        -- A-pillar framing the canopy opening
        P("APillar" .. t, V(0.42, 2.2, 0.6), C(s * 2.42, 4.55, -3.3) * A(0, 0, -s * 0.05), GUN)
        P("APillarBrace" .. t, V(0.24, 1.4, 0.34), C(s * 2.35, 5.05, -2.75) * A(-0.95, 0, 0), DARK)
        P("APillarFoot" .. t, V(0.6, 0.35, 0.7), C(s * 2.35, 3.65, -3.15), GRAPH)
        for i = 0, 3 do
            cylZ("APillarBolt" .. t .. i, 0.05, 0.1, C(s * 2.42, 3.85 + i * 0.52, -3.0), STEEL)
        end
        -- Forward-wall equipment housings (the first things seen when turning the head)
        P("EquipBoxLower" .. t, V(0.5, 0.8, 1.15), C(s * 2.32, 3.0, -2.2), DARK)
        for i = 0, 3 do
            P("EquipVent" .. t .. i, V(0.06, 0.08, 0.85), C(s * 2.04, 2.78 + i * 0.14, -2.2), GRAPH)
        end
        P("EquipBoxUpper" .. t, V(0.45, 0.65, 1.0), C(s * 2.35, 5.0, -0.1), GRAPH)
        for i = 0, 2 do
            cylY("EquipKnob" .. t .. i, 0.09, 0.12, C(s * 2.1, 5.05, -0.35 + i * 0.25), STEEL)
        end
        led("EquipLed" .. t, C(s * 2.1, 5.2, 0.3), COLORS.amber, "equip", 4 + (if s < 0 then 0 else 1))
        led("EquipLedB" .. t, C(s * 2.1, 5.2, 0.45), COLORS.cyan, "equip", 6 + (if s < 0 then 0 else 1))
        -- Ceiling cable harness
        cable("Harness" .. t .. "A", V(s * 2.3, 5.45, -3.0), V(s * 2.3, 5.45, 1.8), 0.16)
        cable("Harness" .. t .. "B", V(s * 2.1, 5.4, -3.0), V(s * 1.7, 5.45, -1.0), 0.1)
        cable("Harness" .. t .. "C", V(s * 2.45, 3.25, -3.0), V(s * 2.45, 3.25, 1.6), 0.12)
        cable("Harness" .. t .. "D", V(s * 2.4, 3.1, -2.6), V(s * 2.0, 2.65, -2.6), 0.1)
        strip("CeilingStrip" .. t, V(0.06, 0.04, 3.4), C(s * 1.8, 5.5, -0.9), COLORS.cyan)
    end

    -- Canopy: sill, header, brow, glass and hairline mullions (kept off the central cone).
    P("Sill", V(4.9, 0.24, 0.55), C(0, 3.55, -3.3), STEEL)
    for i = -4, 4 do
        P("SillMark" .. i, V(0.3, 0.02, 0.5), C(i * 0.5, 3.68, -3.3), if i % 2 == 0 then HAZARD else DARK, PLASTIC)
    end
    P("Header", V(5.3, 0.55, 0.6), C(0, 5.38, -3.3), GUN)
    P("Brow", V(5.3, 0.28, 1.1), C(0, 5.5, -2.8) * A(0.18, 0, 0), GRAPH)
    P("Canopy", V(4.7, 2.0, 0.04), C(0, 4.5, -3.52), Color3.fromRGB(110, 190, 210), GLASS, { Transparency = 0.9 })
    for _, s in ipairs({ -1, 1 }) do
        P("Mullion", V(0.07, 2.0, 0.1), C(s * 1.55, 4.5, -3.5), STEEL)
    end

    -- ------------------------------------------------------------------------------------------------------------
    -- Detail pass: wall equipment modules, hazard banding, cable runs, vents, placards
    -- ------------------------------------------------------------------------------------------------------------
    local function bolt4(name: string, cf: CFrame, width: number, height: number)
        for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            cylZ(name, 0.05, 0.07, cf * C(c[1] * width / 2, c[2] * height / 2, 0), STEEL)
        end
    end
    local function placard(name: string, text: string, size: Vector3, cf: CFrame, color: Color3?)
        local plate = P(name, size, cf, DARK, PLASTIC)
        local gui = Instance.new("SurfaceGui")
        gui.Face = Enum.NormalId.Front
        gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
        gui.PixelsPerStud = 260
        gui.LightInfluence = 0.3
        gui.Brightness = 1.2
        gui.MaxDistance = 14
        gui.Parent = plate
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = text
        label.Font = Enum.Font.RobotoMono
        label.TextScaled = true
        label.TextColor3 = color or COLORS.amber
        label.Parent = gui
        return plate
    end
    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "L" else "R"
        -- hazard banding along the lower wall
        for i = 0, 11 do
            P("WallHazard" .. t .. i, V(0.06, 0.16, 0.3), C(s * 2.5, 2.75, -3.0 + i * 0.5) * A(0.5, 0, 0), if i % 2 == 0 then HAZARD else DARK, PLASTIC)
        end
        -- recessed equipment modules between the ribs
        for i = 0, 3 do
            local z = -2.55 + i * 1.15
            local y = 3.95 + (i % 2) * 0.55
            local module = C(s * 2.46, y, z)
            P("WallModule" .. t .. i, V(0.16, 0.72, 0.8), module, if i % 2 == 0 then GRAPH else DARK)
            bolt4("WallModuleBolt" .. t .. i, module * A(0, s * math.pi / 2, 0) * C(0, 0, -0.1), 0.7, 0.62)
            for v = 0, 3 do
                P("WallModuleVent" .. t .. i .. v, V(0.05, 0.05, 0.5), module * C(s * -0.1, -0.2 + v * 0.1, 0), STEEL)
            end
            led("WallModuleLed" .. t .. i, module * C(s * -0.1, 0.27, -0.28), if (i + (s < 0 and 0 or 1)) % 2 == 0 then COLORS.cyan else COLORS.amber, "wall", 20 + i * 2 + (s < 0 and 0 or 1), V(0.04, 0.04, 0.04))
        end
        -- cable bundles with clamps along the walls
        for row, y in ipairs({ 3.55, 4.75, 5.05 }) do
            cable("WallCable" .. t .. row, V(s * 2.38, y, -3.0), V(s * 2.38, y - 0.05, 1.6), 0.09 + 0.03 * (row % 2))
            for i = 0, 4 do
                P("CableClamp" .. t .. row .. i, V(0.12, 0.16, 0.1), C(s * 2.38, y, -3.0 + i * 1.15), STEEL)
            end
        end
        placard("PlacardCoolant" .. t, if s < 0 then "COOLANT LOOP A" else "COOLANT LOOP B", V(0.55, 0.12, 0.03), C(s * 2.34, 3.45, -2.9) * A(0, s * math.pi / 2, 0), COLORS.amber)
        placard("PlacardPower" .. t, if s < 0 then "AUX POWER" else "REACTOR FEED", V(0.5, 0.12, 0.03), C(s * 2.34, 4.5, -1.45) * A(0, s * math.pi / 2, 0), COLORS.cyan)
    end
    -- roof: longitudinal conduits, vents, hanging cable loops
    for _, x in ipairs({ -1.2, -0.45, 0.45, 1.2 }) do
        cable("RoofConduit" .. x, V(x, 5.5, -3.0), V(x, 5.5, 1.9), 0.12, GRAPH)
    end
    for i = 0, 2 do
        P("RoofVent" .. i, V(1.0, 0.04, 0.4), C(0, 5.62, -0.4 + i * 0.7), STEEL)
        for v = 0, 3 do
            P("RoofVentSlat" .. i .. v, V(1.0, 0.03, 0.04), C(0, 5.6, -0.52 + i * 0.7 + v * 0.1), DARK)
        end
    end
    placard("PlacardCanopy", "CANOPY SEAL  NOMINAL", V(0.9, 0.12, 0.03), C(0, 5.12, -3.0) * A(0.1, 0, 0), COLORS.amber)
    placard("PlacardEject", "EJECTION ARMED  PILOT SAFE", V(1.2, 0.12, 0.03), C(0, 2.95, 1.9), COLORS.cyan)
    -- floor footplates and hazard step
    for _, x in ipairs({ -1.2, 1.2 }) do
        P("FootPlate" .. x, V(0.9, 0.08, 1.2), C(x, 2.56, -1.4), GRAPH, Enum.Material.DiamondPlate)
    end
    for i = 0, 8 do
        P("FloorHazard" .. i, V(0.3, 0.03, 0.3), C(-2.2 + i * 0.55, 2.52, 2.0), if i % 2 == 0 then HAZARD else DARK, PLASTIC)
    end

    -- Edge lighting: thin emissive strips that define the canopy frame, dash lip and console edges
    strip("SillGlow", V(4.5, 0.03, 0.03), C(0, 3.45, -3.04), COLORS.cyan)
    strip("HeaderGlow", V(4.5, 0.03, 0.03), C(0, 5.08, -3.05), COLORS.cyan)
    for _, s in ipairs({ -1, 1 }) do
        strip("PillarGlow" .. s, V(0.03, 1.5, 0.03), C(s * 2.2, 4.5, -3.05), COLORS.cyan)
        strip("WallFloorGlow" .. s, V(0.03, 0.03, 4.2), C(s * 2.4, 2.62, -1.0), COLORS.amber)
    end

    -- ------------------------------------------------------------------------------------------------------------
    -- Dash: cowl base, three multifunction displays, switch rows
    -- ------------------------------------------------------------------------------------------------------------
    P("DashCowl", V(5.0, 0.26, 0.9), C(0, 3.3, -3.35), GUN)
    P("DashBody", V(3.7, 0.8, 1.0), C(0, 2.6, -2.75), DARK)
    P("DashSkirt", V(3.9, 0.3, 1.5), C(0, 2.55, -2.45), GRAPH)
    local aim = V(0, eye.Y - 0.1, eye.Z)
    screen("MFD_L", 1.12, 0.86, V(-1.04, 3.47, -2.5), V(-1.04 * 0.35, aim.Y, aim.Z), 0)
    screen("MFD_C", 0.84, 0.86, V(0, 3.5, -2.55), aim, 0)
    screen("MFD_R", 1.12, 0.86, V(1.04, 3.47, -2.5), V(1.04 * 0.35, aim.Y, aim.Z), 0)
    -- Mechanical switch rows beneath the displays
    for row, spec in ipairs({ { -1.04, 5 }, { 0, 4 }, { 1.04, 5 } }) do
        local cx, count = spec[1], spec[2]
        local strip3 = C(cx, 2.96, -2.28) * A(0.58, 0, 0)
        P("SwitchPanel" .. row, V(1.05, 0.17, 0.12), strip3, GRAPH)
        for i = 1, count do
            local x = (i - (count + 1) / 2) * (0.9 / count) * 1.15
            local isLed = i % 2 == 0
            if isLed then
                led("DashLed" .. row .. "_" .. i, strip3 * C(x, 0, -0.07), if (row + i) % 3 == 0 then COLORS.amber else COLORS.cyan, "dash", 8 + row + i)
            else
                P("DashSwitch" .. row .. "_" .. i, V(0.08, 0.1, 0.1), strip3 * C(x, 0, -0.07), STEEL)
            end
        end
    end

    -- ------------------------------------------------------------------------------------------------------------
    -- Wing consoles (left: diagnostics, right: sensors) angled toward the pilot
    -- ------------------------------------------------------------------------------------------------------------
    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "L" else "R"
        local base = V(s * 1.98, 3.0, -1.72)
        P("ConsoleBody" .. t, V(0.95, 1.05, 1.8), C(base) * A(0, s * -0.55, 0), DARK)
        P("ConsoleDeck" .. t, V(1.15, 0.2, 2.0), C(base + V(0, -0.5, 0)) * A(0, s * -0.55, 0), GRAPH)
        local screenPos = V(s * 1.86, 3.62, -1.9)
        local cf = screen("Console" .. t, 0.82, 0.86, screenPos, V(s * 0.45, eye.Y - 0.35, eye.Z))
        local switchRow = cf * C(0, -0.62, 0.02)
        P("ConsoleSwitches" .. t, V(0.82, 0.14, 0.14), switchRow, GRAPH)
        for i = 1, 5 do
            if i % 2 == 1 then
                P("ConsoleToggle" .. t .. i, V(0.06, 0.1, 0.1), switchRow * C((i - 3) * 0.16, 0.06, -0.06), STEEL)
            else
                led("ConsoleLed" .. t .. i, switchRow * C((i - 3) * 0.16, 0, -0.08), if s < 0 then COLORS.cyan else COLORS.amber, "console", 12 + i + (if s < 0 then 0 else 2))
            end
        end
        -- Rotary selectors and conduit on the console shoulder
        for i = 0, 2 do
            P("ConsoleDial" .. t .. i, V(0.1, 0.07, 0.07), cf * C((i - 1) * 0.24, 0.57, 0.0), STEEL)
        end
        cable("ConsoleConduit" .. t, V(s * 2.3, 3.3, -2.5), V(s * 2.3, 3.0, -0.6), 0.14)
    end

    -- ------------------------------------------------------------------------------------------------------------
    -- Overhead diagnostic panel
    -- ------------------------------------------------------------------------------------------------------------
    P("OverheadMount", V(2.7, 0.2, 0.9), C(0, 5.62, -2.05), GRAPH) -- hanger bracket tying the display housing to the roof
    P("OverheadStrutL", V(0.14, 0.4, 0.14), C(-1.1, 5.45, -1.95), DARK)
    P("OverheadStrutR", V(0.14, 0.4, 0.14), C(1.1, 5.45, -1.95), DARK)
    local overheadAim = V(0, eye.Y + 0.2, eye.Z)
    local ocf = screen("Overhead", 2.0, 0.5, V(0, 5.2, -1.7), overheadAim)
    for i = 1, 8 do
        led("OverheadLed" .. i, ocf * C(-1.15 + i * 0.26, -0.33, -0.03), if i % 3 == 0 then COLORS.amber else COLORS.cyan, "overhead", i, V(0.045, 0.045, 0.03))
    end
    for _, s in ipairs({ -1, 1 }) do
        P("OverheadToggleBank" .. s, V(0.34, 0.12, 0.2), ocf * C(s * 1.2, -0.05, 0.05), STEEL)
        cable("OverheadFeed" .. s, V(s * 1.3, 5.45, -1.9), V(s * 1.9, 5.5, -3.0), 0.1)
    end
    lamp("OverheadLamp", V(0, 5.3, -1.0), COLORS.cyan, 0.3, 6)

    -- ------------------------------------------------------------------------------------------------------------
    -- Seat, harness, hand controls, pedals
    -- ------------------------------------------------------------------------------------------------------------
    P("SeatBase", V(1.5, 0.35, 1.5), C(0, 2.85, 0.1), GRAPH, PLASTIC)
    -- lap belt across the seat (seen when looking down)
    P("LapBeltL", V(0.55, 0.04, 0.16), C(-0.5, 3.04, -0.25) * A(0, 0.25, 0), HAZARD, PLASTIC)
    P("LapBeltR", V(0.55, 0.04, 0.16), C(0.5, 3.04, -0.25) * A(0, -0.25, 0), HAZARD, PLASTIC)
    P("LapBuckle", V(0.18, 0.06, 0.14), C(0, 3.06, -0.28), STEEL)
    for _, x in ipairs({ -0.62, 0.62 }) do
        P("SeatRail" .. x, V(0.08, 0.06, 1.4), C(x, 2.7, -0.05), STEEL)
    end
    P("SeatBack", V(1.4, 2.0, 0.45), C(0, 3.85, 0.85) * A(0.12, 0, 0), GUN, PLASTIC)
    P("Headrest", V(0.8, 0.7, 0.4), C(0, 4.9, 0.95), GRAPH, PLASTIC)
    for _, s in ipairs({ -1, 1 }) do
        P("SeatBolster" .. s, V(0.25, 1.4, 0.9), C(s * 0.8, 3.7, 0.5), GRAPH, PLASTIC)
        P("HarnessStrap" .. s, V(0.14, 1.5, 0.05), C(s * 0.38, 4.15, 0.6) * A(0.12, 0, s * 0.1), HAZARD, PLASTIC)
        P("ArmRest" .. s, V(0.5, 0.2, 1.3), C(s * 1.4, 2.95, -0.8), GRAPH, PLASTIC)
        local sx, sz = s * 1.4, -1.25
        cylY("StickBootRing" .. s, 0.08, 0.62, C(sx, 2.95, sz), STEEL, METAL)
        if not findTemplate("CPT_003") then -- procedural stand-in; the AI stick replaces it when available
            cylY("StickBoot" .. s, 0.5, 0.42, C(sx, 3.35, sz), DARK, PLASTIC)
            cylY("StickShaft" .. s, 0.55, 0.12, C(sx, 3.8, sz), STEEL, METAL)
            P("StickGrip" .. s, V(0.26, 0.55, 0.3), C(sx, 4.15, sz - 0.05) * A(-0.2, 0, -s * 0.08), DARK, PLASTIC)
            P("StickHat" .. s, V(0.1, 0.05, 0.1), C(sx, 4.4, sz - 0.14), COLORS.steel, METAL)
            P("StickGuard" .. s, V(0.04, 0.1, 0.12), C(sx - s * 0.14, 4.28, sz - 0.14), HAZARD, PLASTIC)
        end
        led("StickLed" .. s, C(sx, 3.0, sz - 0.34), COLORS.amber, "stick", 16 + s)
        for i = 1, 2 do
            P("PedalBase" .. s .. i, V(0.5, 0.1, 0.7), C(s * 0.42 + (i - 1.5) * 0.0, 2.64, -1.35 - (i - 1) * 0.0) * A(-0.5, 0, 0), STEEL)
        end
    end

    -- ------------------------------------------------------------------------------------------------------------
    -- Lighting: dim cyan ambient, warm amber console glow
    -- ------------------------------------------------------------------------------------------------------------
    lamp("DashCyan", V(0, 4.1, -1.9), COLORS.cyan, 0.55, 6)
    lamp("ConsoleAmberL", V(-1.5, 3.3, -1.0), COLORS.amber, 0.35, 4)
    lamp("ConsoleAmberR", V(1.5, 3.3, -1.0), COLORS.amber, 0.35, 4)
    lamp("CabinFill", V(0, 4.6, 0.3), Color3.fromRGB(150, 190, 205), 0.3, 9)

    -- ------------------------------------------------------------------------------------------------------------
    -- AI-generated decorative assemblies (optional; the procedural cockpit above is complete without them)
    -- ------------------------------------------------------------------------------------------------------------
    -- Scales the asset so its bounding box fits `targetSize` (asset-local axes; `stretch` 0..1 blends from uniform
    -- scaling toward per-axis scaling) and places it with `targetCF` (orientation included). Mesh geometry is never edited.
    local function fit(id: string, targetCF: CFrame, targetSize: Vector3, stretch: number?)
        local template = findTemplate(id)
        if not template then
            return
        end
        local pivot, size = template:GetBoundingBox()
        local k = V(targetSize.X / size.X, targetSize.Y / size.Y, targetSize.Z / size.Z)
        local uniform = math.min(k.X, k.Y, k.Z)
        local scale = V(uniform, uniform, uniform):Lerp(k, stretch or 0)
        for _, d in ipairs(template:GetDescendants()) do
            if d:IsA("MeshPart") then
                local rel = pivot:ToObjectSpace(d.CFrame)
                local clone = d:Clone()
                clone.Size = d.Size * scale
                clone.CFrame = targetCF * (C(rel.Position * scale) * (rel - rel.Position))
                clone.Anchored, clone.CanCollide, clone.CanQuery, clone.CanTouch, clone.Massless = true, false, false, false, true
                clone.CastShadow = false
                clone.Material = PLASTIC
                clone:SetAttribute("TintColor", MESH_TINT) -- client ArmorGrade multiplies this into the baked texture
                clone:SetAttribute("AssetId", id)
                clone.Parent = model
                stats.parts += 1
                stats.meshParts += 1
            end
        end
        if not table.find(stats.aiAssets, id) then
            table.insert(stats.aiAssets, id)
        end
    end
    for _, entry in ipairs(Builder.MeshFit()) do
        fit(entry.id, entry.cf, entry.size, entry.stretch)
    end

    return cockpit
end

-- Mesh placement table (Torso frame), tuned against the generated meshes' measured bounding boxes. The procedural
-- cockpit never depends on it; with no assets replicated nothing here is placed.
function Builder.MeshFit()
    local eye = Config.EYE_OFFSET
    local function facing(position: Vector3, lookTarget: Vector3?)
        return CFrame.lookAt(position, lookTarget or V(position.X * 0.2, position.Y, eye.Z)) -- asset front (-Z) toward the pilot
    end
    local entries = {
        -- dash cowl over the MFD bank; model front faces forward so it keeps its natural orientation
        { id = "CPT_001", cf = C(0, 3.7, -3.3), size = V(3.4, 0.4, 0.9), stretch = 0.5 },
        -- control sticks replace the procedural stick pieces
        { id = "CPT_003", cf = facing(V(-1.4, 3.3, -1.25), V(0, 3.3, eye.Z)), size = V(0.45, 1.0, 0.7) },
        { id = "CPT_003", cf = facing(V(1.4, 3.3, -1.25), V(0, 3.3, eye.Z)), size = V(0.45, 1.0, 0.7) },
    }
    for _, s in ipairs({ -1, 1 }) do
        -- cabinets under the wing-console screens, and the overhead equipment boxes flanking the overhead display
        table.insert(entries, { id = "CPT_002", cf = facing(V(s * 2.0, 2.78, -1.45), V(s * 0.2, 2.78, eye.Z)), size = V(1.05, 1.05, 0.62) })
        table.insert(entries, { id = "CPT_004", cf = facing(V(s * 1.78, 5.3, -1.9), V(s * 0.2, 4.6, eye.Z)), size = V(1.2, 0.64, 1.36) })
    end
    return entries
end

-- Moves the whole interior to the pilot's torso frame (one PivotTo per frame).
function Builder.Place(cockpit: Cockpit, torsoCF: CFrame)
    cockpit.model:PivotTo(torsoCF)
end

-- Illumination level 0..1: scales lights and neon strips (indicator LEDs are driven individually by the boot sequence).
function Builder.SetLevel(cockpit: Cockpit, level: number)
    for _, entry in ipairs(cockpit.lights) do
        entry.light.Brightness = entry.brightness * level
    end
    for _, entry in ipairs(cockpit.glowParts) do
        entry.part.Color = entry.offColor:Lerp(entry.onColor, level)
    end
end

-- Critical-warning pulse (0 = normal): indicators and cabin lights shift to red. Only the evacuation warning uses red.
function Builder.SetAlert(cockpit: Cockpit, amount: number)
    for _, entry in ipairs(cockpit.indicators) do
        if amount > 0 then
            entry.part.Color = COLORS.red:Lerp(DARK, 0.5 * (1 - amount))
        else
            entry.part.Color = entry.onColor
        end
    end
    for _, entry in ipairs(cockpit.lights) do
        entry.light.Color = if amount > 0 then entry.baseColor:Lerp(COLORS.red, 0.6 * amount) else entry.baseColor
    end
end

function Builder.SetIndicator(entry, on: number)
    entry.part.Color = entry.offColor:Lerp(entry.onColor, math.clamp(on, 0, 1))
end

return Builder
