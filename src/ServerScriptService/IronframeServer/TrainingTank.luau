-- Unmanned armored training tank (M10A). A reusable machine target: five damageable components, deterministic hit geometry,
-- a staged damage presentation and (optionally) a predefined patrol route. No crew, no weapons fire, no AI beyond "follow the
-- route and wait for a mech to clear the lane".
--
-- Component  -> parts that carry its hit geometry (queryable)        -> what its loss does
--   HULL       lower/upper hull, glacis, rear plate                    -> VEHICLE DESTROYED (everything stops, turret thrown off)
--   TURRET     turret body, mantlet, barrel, bustle                    -> TURRET DISABLED (barrel droops, scan stops)
--   TRACK_L/R  track body, skirt                                       -> IMMOBILIZED (patrol stops, track visibly breaks)
--   ENGINE     engine deck                                             -> IMMOBILIZED + engine fire
--
-- Assembly: one anchored invisible root; every other part is an unanchored part welded (Weld, explicit C0) to it or to the
-- turret root. Moving the patrol tank therefore replicates ONE CFrame; the turret scan replicates ONE weld offset.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Unit = require(Shared:WaitForChild("DestructibleState"))
local Rules = require(Shared:WaitForChild("ComponentRules"))
local Destructibles = require(script.Parent.Destructibles)
local AssetLibrary = require(script.Parent.AssetLibrary)

local TrainingTank = {}

local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local METAL, PLATE, SMOOTH = Enum.Material.Metal, Enum.Material.DiamondPlate, Enum.Material.SmoothPlastic
local SOOT = Color3.fromRGB(22, 22, 24)

TrainingTank.PALETTES = {
    OLIVE = { hull = Color3.fromRGB(70, 80, 54), trim = Color3.fromRGB(46, 52, 38), steel = Color3.fromRGB(52, 56, 58), mark = Color3.fromRGB(214, 120, 36) },
    SAND = { hull = Color3.fromRGB(132, 114, 82), trim = Color3.fromRGB(96, 82, 58), steel = Color3.fromRGB(58, 58, 56), mark = Color3.fromRGB(190, 52, 40) },
    SLATE = { hull = Color3.fromRGB(70, 82, 98), trim = Color3.fromRGB(44, 52, 62), steel = Color3.fromRGB(46, 52, 58), mark = Color3.fromRGB(226, 176, 40) },
}

-- Assembly helpers ---------------------------------------------------------------------------------------------------------
local function weld(parent: BasePart, child: BasePart, c0: CFrame): Weld
    local w = Instance.new("Weld")
    w.Name = "Joint"
    w.Part0, w.Part1 = parent, child
    w.C0 = c0
    w.Parent = child
    return w
end

local function newBuild(d, tank)
    local b = { d = d, tank = tank, parts = {}, base = {}, groups = {}, skin = {}, skinned = false, tracks = {} }
    local model = Instance.new("Model")
    model.Name = "TrainingTank_" .. tank.id
    model:SetAttribute("TrainingVehicle", true)
    model:SetAttribute("Unmanned", true)
    model:SetAttribute("VehicleId", tank.id)
    b.model = model
    local root = Instance.new("Part")
    root.Name = "TankRoot"
    root.Size = V3(1, 1, 1)
    root.Transparency = 1
    root.Anchored = true
    root.CanCollide, root.CanQuery, root.CanTouch, root.CastShadow = false, false, false, false
    root.CFrame = tank.spawnCF
    root.Parent = model
    b.root = root
    model.PrimaryPart = root
    return b
end

-- Adds a welded part. opts: query (registers hit geometry for `comp`), comp, parent (turret root), shape, transparency, cast.
local function add(b, name, size, localCF, color, material, opts)
    opts = opts or {}
    local parent = opts.parent or b.root
    local p = Instance.new(opts.class or "Part")
    p.Name = name
    p.Size = size
    p.Anchored = false
    p.Massless = true
    p.CanCollide = opts.query == true
    p.CanQuery = opts.query == true
    p.CanTouch = false
    p.CastShadow = opts.cast ~= false and size.Magnitude > 2
    p.Material = material or METAL
    p.Color = color
    p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    if opts.shape then
        p.Shape = opts.shape
    end
    if opts.transparency then
        p.Transparency = opts.transparency
    end
    p.CFrame = parent.CFrame * localCF
    p.Parent = b.model
    local w = weld(parent, p, localCF)
    b.base[p] = color
    if opts.comp then
        b.groups[opts.comp] = b.groups[opts.comp] or { hit = {}, visual = {} }
        table.insert(b.groups[opts.comp].visual, p)
        if opts.query then
            table.insert(b.groups[opts.comp].hit, p)
        end
    end
    table.insert(b.parts, p)
    return p, w
end

local function cylX(b, name, length, diameter, cf, color, material, opts)
    opts = opts or {}
    opts.shape = Enum.PartType.Cylinder
    return add(b, name, V3(length, diameter, diameter), cf, color, material, opts)
end

-- Cylinder whose long axis follows local Z.
local function cylZ(b, name, length, diameter, cf, color, material, opts)
    return cylX(b, name, length, diameter, cf * ANG(0, math.pi / 2, 0), color, material, opts)
end

local function wedge(b, name, size, cf, color, material, opts)
    opts = opts or {}
    opts.class = "WedgePart"
    return add(b, name, size, cf, color, material, opts)
end

local function plate(b, tank, text, size, cf, parent, face)
    local p = add(b, "NumberPlate", size, cf, Color3.fromRGB(226, 226, 220), SMOOTH, { parent = parent, comp = "TURRET", cast = false })
    local gui = Instance.new("SurfaceGui")
    gui.Face, gui.SizingMode, gui.PixelsPerStud, gui.LightInfluence = face or Enum.NormalId.Front, Enum.SurfaceGuiSizingMode.PixelsPerStud, 28, 0.5
    gui.Parent = p
    local label = Instance.new("TextLabel")
    label.Size, label.BackgroundTransparency, label.Text = UDim2.fromScale(1, 1), 1, text
    label.TextColor3, label.Font, label.TextScaled = Color3.fromRGB(26, 28, 30), Enum.Font.GothamBlack, true
    label.Parent = gui
    return p
end

-- Geometry -------------------------------------------------------------------------------------------------------------
local function buildProcedural(b, tank)
    local pal = tank.palette
    local hullC, trim, steel, mark = pal.hull, pal.trim, pal.steel, pal.mark

    -- Tracks and running gear ---------------------------------------------------------------------------------------------
    b.tracks = {}
    for _, side in ipairs({ { "L", -1 }, { "R", 1 } }) do
        local tag, s = side[1], side[2]
        local comp = "TRACK_" .. tag
        local x = s * 6.6
        local body = add(b, "TrackBody" .. tag, V3(4.0, 4.4, 23), CF(x, 2.2, 0), steel, METAL, { comp = comp, query = true })
        cylX(b, "TrackFront" .. tag, 4.0, 4.4, CF(x, 2.2, -11.5), steel, METAL, { comp = comp, query = true })
        local rear = cylX(b, "TrackRear" .. tag, 4.0, 4.4, CF(x, 2.2, 11.5), steel, METAL, { comp = comp, query = true })
        -- Tread cleats along both runs (cosmetic ridges, one part per cleat row keeps the count low).
        for i = -4, 4 do
            add(b, "Cleat" .. tag, V3(4.3, 0.35, 1.0), CF(x, 4.5, i * 2.6), trim, METAL, { comp = comp, cast = false })
            add(b, "CleatLow" .. tag, V3(4.3, 0.35, 1.0), CF(x, 0.0, i * 2.6), trim, METAL, { comp = comp, cast = false })
        end
        local wheels = {}
        for i = -2, 2 do
            table.insert(wheels, (cylX(b, "RoadWheel" .. tag, 0.7, 3.2, CF(x + s * 2.15, 1.9, i * 4.4), trim, METAL, { comp = comp })))
        end
        for _, z in ipairs({ -11.5, 11.5 }) do
            cylX(b, "Sprocket" .. tag, 0.9, 3.4, CF(x + s * 2.2, 2.2, z), Color3.fromRGB(34, 36, 38), METAL, { comp = comp })
        end
        local skirt = add(b, "Skirt" .. tag, V3(0.6, 2.5, 20.5), CF(s * 8.9, 4.1, 0), hullC, PLATE, { comp = comp, query = true })
        add(b, "SkirtStripe" .. tag, V3(0.65, 0.5, 20.5), CF(s * 8.9, 5.1, 0), mark, SMOOTH, { comp = comp, cast = false })
        add(b, "Fender" .. tag, V3(3.6, 0.5, 24), CF(s * 7.6, 5.0, 0), hullC, METAL, { comp = comp })
        b.tracks[tag] = { body = body, rear = rear, wheels = wheels, skirt = skirt, x = x, s = s }
    end

    -- Hull ---------------------------------------------------------------------------------------------------------------------
    add(b, "HullLower", V3(9.0, 3.2, 25), CF(0, 4.0, 0), hullC, PLATE, { comp = "HULL", query = true })
    add(b, "HullUpper", V3(11.4, 2.0, 21), CF(0, 6.4, 1.2), hullC, METAL, { comp = "HULL", query = true })
    wedge(b, "Glacis", V3(11.4, 2.0, 3.4), CF(0, 6.4, -11.0), hullC, METAL, { comp = "HULL", query = true })
    add(b, "GlacisLower", V3(9.0, 3.2, 0.7), CF(0, 4.0, -12.85) * ANG(math.rad(-14), 0, 0), hullC, PLATE, { comp = "HULL", query = true })
    add(b, "RearPlate", V3(9.4, 3.4, 0.8), CF(0, 4.4, 12.8), trim, PLATE, { comp = "HULL", query = true })
    add(b, "TowCableA", V3(0.25, 0.25, 9), CF(-3.2, 5.3, -9.6), Color3.fromRGB(30, 30, 30), METAL, { comp = "HULL", cast = false })
    add(b, "TowCableB", V3(0.25, 0.25, 9), CF(3.2, 5.3, -9.6), Color3.fromRGB(30, 30, 30), METAL, { comp = "HULL", cast = false })
    for _, x in ipairs({ -3.6, 3.6 }) do
        add(b, "Headlight", V3(1.1, 0.8, 0.6), CF(x, 7.0, -12.3), Color3.fromRGB(40, 42, 44), METAL, { comp = "HULL", cast = false })
        add(b, "HeadlightLens", V3(0.7, 0.5, 0.25), CF(x, 7.0, -12.65), Color3.fromRGB(255, 226, 150), Enum.Material.Neon, { comp = "HULL", cast = false })
    end
    add(b, "DriverHatch", V3(2.4, 0.5, 2.6), CF(-3.0, 7.65, -5.0), trim, METAL, { comp = "HULL", cast = false })
    add(b, "HullStripe", V3(11.6, 0.4, 1.4), CF(0, 7.45, 6.0), mark, SMOOTH, { comp = "HULL", cast = false })
    -- Rear fuel drums and stowage rack.
    for i, x in ipairs({ -4, 0, 4 }) do
        cylX(b, "FuelDrum", 3.6, 1.8, CF(x, 8.6, 11.0) * ANG(0, 0, math.pi / 2), if i == 2 then mark else trim, METAL, { comp = "HULL", cast = false })
    end

    -- Engine deck -------------------------------------------------------------------------------------------------------------
    add(b, "EngineDeck", V3(9.2, 1.4, 7.2), CF(0, 7.9, 7.4), steel, METAL, { comp = "ENGINE", query = true })
    for i = -2, 2 do
        add(b, "Louver", V3(7.8, 0.18, 0.5), CF(0, 8.68, 7.4 + i * 1.3), Color3.fromRGB(14, 14, 15), METAL, { comp = "ENGINE", cast = false })
    end
    for _, x in ipairs({ -3.6, 3.6 }) do
        cylX(b, "ExhaustStack", 2.4, 0.9, CF(x, 8.9, 10.6) * ANG(0, 0, math.pi / 2), Color3.fromRGB(34, 34, 36), METAL, { comp = "ENGINE", cast = false })
    end

    -- Turret (welded to its own invisible root so the whole assembly yaws with one weld offset) -------------------------------------
    local pivotCF = CF(0, 7.4, -1.2)
    local turretRoot, turretWeld = add(b, "TurretRoot", V3(1, 1, 1), pivotCF, hullC, METAL, { transparency = 1 })
    turretRoot.CanCollide = false
    b.turretRoot, b.turretWeld, b.turretBase = turretRoot, turretWeld, pivotCF
    local function t(name, size, cf, color, material, opts)
        opts = opts or {}
        opts.parent, opts.comp = turretRoot, "TURRET"
        return add(b, name, size, cf, color, material, opts)
    end
    cylX(b, "TurretRing", 0.8, 7.4, ANG(0, 0, math.pi / 2), trim, METAL, { parent = turretRoot, comp = "TURRET" })
    t("TurretBody", V3(8.0, 2.8, 9.6), CF(0, 1.6, 0.6), hullC, METAL, { query = true })
    t("CheekL", V3(1.4, 2.6, 4.6), CF(-4.4, 1.5, -2.1) * ANG(0, math.rad(-18), 0), hullC, PLATE, { query = true })
    t("CheekR", V3(1.4, 2.6, 4.6), CF(4.4, 1.5, -2.1) * ANG(0, math.rad(18), 0), hullC, PLATE, { query = true })
    t("TurretRoof", V3(7.4, 0.5, 8.4), CF(0, 3.2, 0.9), trim, METAL)
    t("Bustle", V3(7.0, 2.2, 3.8), CF(0, 1.3, 6.2), hullC, METAL, { query = true })
    t("BustleStripe", V3(7.1, 0.5, 3.9), CF(0, 2.3, 6.2), mark, SMOOTH, { cast = false })
    t("Mantlet", V3(3.8, 2.6, 1.8), CF(0, 1.7, -4.9), steel, METAL, { query = true })
    t("MantletShroud", V3(2.0, 2.0, 1.2), CF(0, 1.7, -6.1), Color3.fromRGB(36, 38, 40), METAL, { query = true })
    local barrel = cylZ(b, "Barrel", 15.5, 0.95, CF(0, 1.7, -14.0), Color3.fromRGB(44, 46, 48), METAL, { parent = turretRoot, comp = "TURRET", query = true })
    cylZ(b, "BoreEvacuator", 3.2, 1.3, CF(0, 1.7, -11.0), Color3.fromRGB(52, 54, 56), METAL, { parent = turretRoot, comp = "TURRET" })
    local brake = cylZ(b, "MuzzleBrake", 1.5, 1.45, CF(0, 1.7, -21.2), Color3.fromRGB(34, 36, 38), METAL, { parent = turretRoot, comp = "TURRET", query = true })
    b.barrel, b.brake = barrel, brake
    cylX(b, "Cupola", 0.9, 2.5, CF(2.2, 3.9, 2.0) * ANG(0, 0, math.pi / 2), trim, METAL, { parent = turretRoot, comp = "TURRET" })
    t("Hatch", V3(1.8, 0.35, 1.8), CF(-2.0, 3.6, 2.4), steel, METAL, { cast = false })
    t("SightBox", V3(1.3, 1.1, 1.6), CF(-2.4, 3.55, -2.4), Color3.fromRGB(34, 36, 38), METAL, { cast = false })
    t("SightLens", V3(0.8, 0.5, 0.2), CF(-2.4, 3.6, -3.25), Color3.fromRGB(110, 210, 255), Enum.Material.Neon, { cast = false })
    for _, s in ipairs({ -1, 1 }) do
        for i = 0, 2 do
            cylX(b, "SmokeLauncher", 1.1, 0.5, CF(s * 4.5, 2.3, 1.8 + i * 0.9) * ANG(0, 0, math.pi / 2 + s * 0.3), Color3.fromRGB(30, 32, 34), METAL, { parent = turretRoot, comp = "TURRET", cast = false })
        end
    end
    t("Antenna", V3(0.14, 8.0, 0.14), CF(-3.2, 7.0, 6.6), Color3.fromRGB(20, 20, 20), METAL, { cast = false })
    t("StowageBin", V3(2.2, 1.2, 2.6), CF(2.6, 2.7, 6.2), trim, METAL, { cast = false })
    plate(b, tank, tank.id, V3(2.6, 1.3, 0.12), CF(-4.2, 1.9, 1.2) * ANG(0, math.rad(90), 0), turretRoot, Enum.NormalId.Front)
    plate(b, tank, tank.id, V3(2.6, 1.3, 0.12), CF(4.2, 1.9, 1.2) * ANG(0, math.rad(-90), 0), turretRoot, Enum.NormalId.Front)
    -- Training-target beacon (amber, unarmed vehicle marker) on the rear deck.
    local beacon = add(b, "TrainingBeacon", V3(0.9, 0.9, 0.9), CF(0, 9.2, 5.2), Color3.fromRGB(255, 168, 58), Enum.Material.Neon, { comp = "HULL", cast = false })
    b.beacon = beacon
end

-- Skinned build (AI-generated, segmented tank mesh TNK_001: hull / turret+gun / left track / right track) --------------------
-- Visual only. Hit geometry is a fixed set of invisible boxes (numbers measured against the scaled mesh in Studio), so hit
-- detection, component rules and attachment points are identical to the procedural tank and never depend on mesh topology.
local SKIN_ID = "TNK_001"
local SKIN_SCALE = 1.5
-- Mesh part centres in the template's bounding-box frame (studs, unscaled) and the ring pivot in root space (ground at y = 0).
local SKIN = {
    hull = { match = "hull", center = V3(0.034, -0.972, 1.465) },
    turret = { match = "turret", center = V3(0.026, 2.557, -0.834) },
    left = { match = "left track", center = V3(-4.271, -2.567, 1.454) },
    right = { match = "right track", center = V3(4.342, -2.567, 1.448) },
}
local SKIN_GROUND = 4.5 -- template bounding box half height: the mesh bottom sits at y = -4.5 in its own frame
local SKIN_PIVOT = V3(0, 8.2, 2.4)

local function skinPart(b, template: MeshPart, localCF: CFrame, comp: string, parent: BasePart?)
    local p = template:Clone()
    p.Anchored, p.Massless = false, true
    p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
    p.CastShadow = true
    p.Size = template.Size * SKIN_SCALE
    local host = parent or b.root
    p.CFrame = host.CFrame * localCF
    p.Parent = b.model
    weld(host, p, localCF)
    b.skin[p] = true
    b.groups[comp] = b.groups[comp] or { hit = {}, visual = {} }
    table.insert(b.groups[comp].visual, p)
    table.insert(b.parts, p)
    return p
end

local function findMesh(template: Model, fragment: string): MeshPart?
    for _, d in ipairs(template:GetDescendants()) do
        if d:IsA("MeshPart") and string.find(string.lower(d.Name), fragment, 1, true) then
            return d
        end
    end
    return nil
end

local function buildSkinned(b, tank, template: Model): boolean
    local meshes = {}
    for key, spec in pairs(SKIN) do
        meshes[key] = findMesh(template, spec.match)
        if not meshes[key] then
            return false
        end
    end
    local pal = tank.palette
    local steel = pal.steel
    local function rootCF(center: Vector3): CFrame
        return CF(center.X * SKIN_SCALE, (center.Y + SKIN_GROUND) * SKIN_SCALE, center.Z * SKIN_SCALE)
    end
    b.skinned = true
    skinPart(b, meshes.hull, rootCF(SKIN.hull.center), "HULL")
    -- Hit boxes (invisible, queryable): fixed deterministic geometry.
    local function hitbox(name, size, cf, comp, parent)
        return (add(b, name, size, cf, steel, METAL, { comp = comp, query = true, transparency = 1, cast = false, parent = parent }))
    end
    hitbox("HullHit", V3(15.5, 5.2, 19), CF(0.05, 5.29, 2.2), "HULL")
    hitbox("EngineHit", V3(10, 2.0, 7), CF(0, 7.3, 9.0), "ENGINE")
    for _, side in ipairs({ { "L", "left", -1, V3(-6.4, 2.9, 2.18) }, { "R", "right", 1, V3(6.5, 2.9, 2.17) } }) do
        local tag, key, s, at = side[1], side[2], side[3], side[4]
        local skin = skinPart(b, meshes[key], rootCF(SKIN[key].center), "TRACK_" .. tag)
        local hit = hitbox("TrackHit" .. tag, V3(3.2, 5.8, 19.5), CF(at), "TRACK_" .. tag)
        b.tracks[tag] = { body = skin, hit = hit, shrink = { skin, hit }, wheels = {}, x = at.X, s = s }
    end
    -- Turret: ring pivot welded to the hull; mesh and hit boxes welded to the pivot so one weld offset yaws everything.
    local pivotCF = CF(SKIN_PIVOT)
    local turretRoot, turretWeld = add(b, "TurretRoot", V3(1, 1, 1), pivotCF, pal.hull, METAL, { transparency = 1 })
    turretRoot.CanCollide = false
    b.turretRoot, b.turretWeld, b.turretBase = turretRoot, turretWeld, pivotCF
    local meshCenter = rootCF(SKIN.turret.center).Position
    skinPart(b, meshes.turret, CF(meshCenter - SKIN_PIVOT), "TURRET", turretRoot)
    hitbox("TurretHit", V3(11.5, 5.4, 15.5), CF(0, 2.6, 0), "TURRET", turretRoot)
    b.barrel = hitbox("BarrelHit", V3(1.8, 1.8, 8.6), CF(0, 2.8, -10.9), "TURRET", turretRoot)
    plate(b, tank, tank.id, V3(2.6, 1.3, 0.2), CF(-6.5, 2.4, 1.6) * ANG(0, math.rad(90), 0), turretRoot, Enum.NormalId.Front)
    plate(b, tank, tank.id, V3(2.6, 1.3, 0.2), CF(6.5, 2.4, 1.6) * ANG(0, math.rad(-90), 0), turretRoot, Enum.NormalId.Front)
    b.beacon = add(b, "TrainingBeacon", V3(0.9, 0.9, 0.9), CF(0, 9.4, 9.5), Color3.fromRGB(255, 168, 58), Enum.Material.Neon, { comp = "HULL", cast = false })
    return true
end

local function buildGeometry(b, tank)
    local template = AssetLibrary.Template(SKIN_ID)
    if template and buildSkinned(b, tank, template) then
        return
    end
    -- Fallback (assets unavailable, tests, Edit mode): discard any partial skin build and build the procedural tank.
    for _, p in ipairs(b.parts) do
        p:Destroy()
    end
    b.parts, b.groups, b.base, b.skin, b.skinned, b.tracks = {}, {}, {}, {}, false, {}
    buildProcedural(b, tank)
end

-- State presentation -----------------------------------------------------------------------------------------------------
local function tint(b, parts, amount: number)
    for _, p in ipairs(parts) do
        if p.Parent then
            if b.skin[p] then
                -- A baked texture cannot be tinted by MeshPart.Color (see assets/README.md): heavy damage strips the texture and
                -- chars the part; light damage is shown by scorch discs (see mark()).
                if amount >= 0.45 then
                    p.TextureID = ""
                    p.Color = b.tank.palette.hull:Lerp(SOOT, amount)
                end
            else
                p.Color = (b.base[p] or p.Color):Lerp(SOOT, amount)
            end
        end
    end
end

local function hide(b, p: BasePart, d)
    if not p or not p.Parent then
        return
    end
    Destructibles.Emit(d, { t = "x", f = "metal", k = "break", cf = p.CFrame, s = p.Size, c = b.base[p] or p.Color, mat = p.Material, e = 0.6 }, true)
    p:Destroy()
end

local function sparkEmitter(part: BasePart, rate: number)
    local a = Instance.new("Attachment")
    a.Name = "SparkPoint"
    a.Parent = part
    local e = Instance.new("ParticleEmitter")
    e.Name = "DamageSparks"
    e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    e.Color = ColorSequence.new(Color3.fromRGB(255, 220, 140), Color3.fromRGB(255, 120, 40))
    e.LightEmission, e.Rate = 1, rate
    e.Lifetime = NumberRange.new(0.25, 0.6)
    e.Speed, e.SpreadAngle = NumberRange.new(6, 16), Vector2.new(90, 90)
    e.Acceleration = Vector3.new(0, -40, 0)
    e.EmissionDirection = Enum.NormalId.Top
    e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0) })
    e.Parent = a
    return a
end

local function wreckLight(part: BasePart)
    local light = Instance.new("PointLight")
    light.Name = "WreckGlow"
    light.Color, light.Range, light.Brightness, light.Shadows = Color3.fromRGB(255, 130, 50), 22, 2.2, false
    light.Parent = part
    return light
end

local function updateStatus(d, tank)
    local status = Rules.Tank(tank.units)
    local previous = tank.status
    tank.status = status
    tank.model:SetAttribute("Status", status.status)
    tank.model:SetAttribute("Mobile", status.mobile)
    tank.model:SetAttribute("TurretOperational", status.turretOperational)
    return status, previous
end

local NOTICE = {
    HULL = "VEHICLE DESTROYED", TURRET = "TURRET DISABLED", TRACK_L = "LEFT TRACK DISABLED - IMMOBILIZED",
    TRACK_R = "RIGHT TRACK DISABLED - IMMOBILIZED", ENGINE = "ENGINE DISABLED - IMMOBILIZED",
}

local function breakTrack(d, tank, tag: string)
    local b = tank.build
    local t = b.tracks[tag]
    if not t or t.broken then
        return
    end
    t.broken = true
    local body = t.body
    for _, part in ipairs(t.shrink or { body }) do
        local weldJoint = part:FindFirstChildOfClass("Weld")
        local length = part.Size.Z
        local newLength = length * 0.58
        local shift = (length - newLength) / 2
        part.Size = V3(part.Size.X, part.Size.Y, newLength)
        weldJoint.C0 = weldJoint.C0 * CF(0, -0.3, -shift) * ANG(0, 0, t.s * math.rad(5))
    end
    if t.rear then
        hide(b, t.rear, d)
    end
    for i, wheel in ipairs(t.wheels) do
        if i >= 4 then
            hide(b, wheel, d)
        end
    end
    -- A length of broken tread lies behind the vehicle.
    local strand = Instance.new("Part")
    strand.Name = "BrokenTread"
    strand.Size = V3(3.6, 0.25, 10)
    strand.Anchored, strand.CanCollide, strand.CanQuery, strand.CanTouch, strand.CastShadow = false, false, false, false, false
    strand.Material, strand.Color = METAL, Color3.fromRGB(32, 32, 34)
    local localCF = CF(t.x + t.s * 0.5, 0.15, if b.skinned then 17 else 19) * ANG(0, t.s * math.rad(11), math.rad(2))
    strand.CFrame = b.root.CFrame * localCF
    strand.Parent = b.model
    weld(b.root, strand, localCF)
    table.insert(b.parts, strand)
    tint(b, b.groups["TRACK_" .. tag].visual, 0.55)
    table.insert(tank.emitters, sparkEmitter(body, 6))
    Destructibles.Emit(d, { t = "x", f = "metal", k = "wreck", cf = body.CFrame, s = body.Size, c = Color3.fromRGB(60, 62, 64), mat = METAL, e = 1.1 }, true)
end

local function disableTurret(d, tank)
    local b = tank.build
    tank.scan = false
    b.turretWeld.C0 = b.turretBase * ANG(0, tank.turretYaw or 0, 0) * CF(0, -0.15, 0.2) * ANG(math.rad(if b.skinned then -8 else 4), 0, math.rad(-3))
    if b.barrel and b.barrel.Parent and not b.skinned then
        local barrelWeld = b.barrel:FindFirstChildOfClass("Weld")
        local pivot = CF(0, 1.7, -5.9)
        -- Drooping, bent barrel: rotate about the mantlet.
        barrelWeld.C0 = pivot * ANG(math.rad(-17), 0, math.rad(4)) * pivot:Inverse() * barrelWeld.C0
        local brakeWeld = b.brake and b.brake:FindFirstChildOfClass("Weld")
        if brakeWeld then
            brakeWeld.C0 = pivot * ANG(math.rad(-17), 0, math.rad(4)) * pivot:Inverse() * brakeWeld.C0
        end
    end
    tint(b, b.groups.TURRET.visual, 0.5)
    table.insert(tank.emitters, sparkEmitter(b.turretRoot, 5))
    table.insert(tank.emitters, Destructibles.SmokeEmitter(b.turretRoot, 7, 2.2, 20))
    Destructibles.Emit(d, { t = "x", f = "machine", k = "explosion", cf = b.turretRoot.CFrame, s = V3(8, 3, 9), c = Color3.fromRGB(70, 70, 70), mat = METAL, e = 1.4 }, true)
end

local function destroyHull(d, tank)
    local b = tank.build
    tank.scan = false
    tank.moving = false
    tint(b, b.parts, 0.62)
    if b.beacon.Parent then
        b.beacon.Color = Color3.fromRGB(40, 20, 12)
        b.beacon.Material = METAL
    end
    -- The turret is flung up and off its ring and settles tilted on the hull.
    b.turretWeld.C0 = b.turretBase * ANG(0, (tank.turretYaw or 0) + math.rad(35), 0) * CF(2.4, 1.6, 1.4) * ANG(math.rad(-12), 0, math.rad(16))
    local hull = b.groups.HULL.hit[1]
    table.insert(tank.emitters, Destructibles.SmokeEmitter(hull, 14, 4.5, 26))
    local fireHost = b.groups.ENGINE.hit[1] or hull
    table.insert(tank.emitters, Destructibles.FireEmitter(fireHost, 22, 3.2))
    table.insert(tank.emitters, Destructibles.SmokeEmitter(b.turretRoot, 8, 3, 24))
    wreckLight(fireHost)
    Destructibles.Emit(d, { t = "x", f = "machine", k = "explosion", cf = hull.CFrame * CF(0, 4, 0), s = V3(11, 5, 22), c = Color3.fromRGB(70, 70, 70), mat = METAL, e = 3.0 }, true)
    for _, tag in ipairs({ "L", "R" }) do
        if b.tracks[tag] and not b.tracks[tag].broken then
            tint(b, b.groups["TRACK_" .. tag].visual, 0.6)
        end
    end
end

local function engineFire(d, tank)
    local b = tank.build
    local deck = b.groups.ENGINE.hit[1]
    tint(b, b.groups.ENGINE.visual, 0.6)
    table.insert(tank.emitters, Destructibles.SmokeEmitter(deck, 12, 3.4, 26))
    table.insert(tank.emitters, Destructibles.FireEmitter(deck, 14, 2.4))
    Destructibles.Emit(d, { t = "x", f = "machine", k = "explosion", cf = deck.CFrame, s = deck.Size, c = Color3.fromRGB(70, 70, 70), mat = METAL, e = 1.6 }, true)
end

-- Progressive damage: a dark scorch disc where the hull was struck (welded, so it travels with the vehicle), bounded per tank.
local MAX_MARKS = 14
local function mark(tank, comp: string, position: Vector3, normal: Vector3, class: string)
    local b = tank.build
    if #tank.marks >= MAX_MARKS or os.clock() - tank.lastMark < 0.18 then
        return
    end
    tank.lastMark = os.clock()
    local host = if comp == "TURRET" then b.turretRoot else b.root
    local diameter = if class == "HEAVY" then 2.6 elseif class == "LASER" then 1.4 else 0.8
    local disc = Instance.new("Part")
    disc.Name = "Scorch"
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = V3(0.08, diameter, diameter)
    local cf = CFrame.lookAt(position + normal * 0.06, position + normal * 2) * ANG(0, math.pi / 2, 0)
    disc.CFrame = cf
    disc.Anchored, disc.CanCollide, disc.CanQuery, disc.CanTouch, disc.CastShadow = false, false, false, false, false
    disc.Massless = true
    disc.Material, disc.Color = Enum.Material.Slate, Color3.fromRGB(16, 15, 14)
    disc.Parent = b.model
    weld(host, disc, host.CFrame:ToObjectSpace(cf))
    table.insert(tank.marks, disc)
end

local function onStage(d, tank, comp: string, old: string, new: string, position: Vector3, normal: Vector3, class: string)
    local b = tank.build
    local group = b.groups[comp]
    if tank.status.destroyed and comp ~= "HULL" then
        return -- a wreck keeps absorbing damage (counted) but no further component effects
    end
    if new == "DAMAGED" then
        tint(b, group.visual, 0.22)
        local host = group.hit[1]
        if comp == "HULL" then
            table.insert(tank.emitters, Destructibles.SmokeEmitter(host, 4, 1.8, 10))
        elseif comp == "ENGINE" then
            table.insert(tank.emitters, Destructibles.SmokeEmitter(host, 6, 2.2, 18))
        else
            table.insert(tank.emitters, sparkEmitter(host, 2))
        end
        Destructibles.Emit(d, { t = "s", f = "metal", p = position, n = normal, w = class, e = 1 }, true)
        return
    end
    if new ~= "DESTROYED" then
        return
    end
    Destructibles.NoteComponentLost(d)
    if comp == "TRACK_L" then
        breakTrack(d, tank, "L")
    elseif comp == "TRACK_R" then
        breakTrack(d, tank, "R")
    elseif comp == "TURRET" then
        disableTurret(d, tank)
    elseif comp == "ENGINE" then
        engineFire(d, tank)
    elseif comp == "HULL" then
        destroyHull(d, tank)
    end
    local status, previous = updateStatus(d, tank)
    Destructibles.Notice(d, string.format("TRAINING ARMOR %s - %s", tank.id, NOTICE[comp]), nil)
    if previous and not previous.destroyed and status.destroyed then
        Destructibles.NoteTargetDisabled(d, true)
    end
    if not status.mobile then
        tank.moving = false
    end
end

-- Patrol ------------------------------------------------------------------------------------------------------------------
local mechParams = RaycastParams.new()
mechParams.FilterType = Enum.RaycastFilterType.Include

local function laneBlocked(tank): boolean
    local mechs = workspace:FindFirstChild("IronframeMechs")
    if not mechs then
        return false
    end
    mechParams.FilterDescendantsInstances = { mechs }
    local cf = tank.root.CFrame * CF(0, 7, -16)
    local hit = workspace:Blockcast(cf, V3(16, 14, 4), tank.root.CFrame.LookVector * 24, mechParams)
    return hit ~= nil
end

local function update(d, tank, dt: number, t: number)
    local status = tank.status
    local b = tank.build
    if not b or not b.model.Parent then
        return
    end
    -- Dust follows motion; both emitters toggle only on change.
    local moving = false
    if status.mobile and tank.patrol and not d.resetting then
        local points = tank.patrol.points
        local target = points[tank.patrol.index]
        local position = tank.position
        local delta = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
        local distance = delta.Magnitude
        if distance < 1.5 then
            tank.patrol.index += tank.patrol.step
            if tank.patrol.index > #points or tank.patrol.index < 1 then
                tank.patrol.step = -tank.patrol.step
                tank.patrol.index += 2 * tank.patrol.step
            end
        elseif not laneBlocked(tank) then
            local desired = math.atan2(-delta.X, -delta.Z)
            local diff = (desired - tank.yaw + math.pi) % (2 * math.pi) - math.pi
            local maxTurn = tank.patrol.turnRate * dt
            if math.abs(diff) > math.rad(2.5) then
                tank.yaw += math.clamp(diff, -maxTurn, maxTurn)
                moving = true
            else
                tank.yaw += math.clamp(diff, -maxTurn, maxTurn)
                local step = math.min(tank.patrol.speed * dt, distance)
                tank.position = position + delta.Unit * step
                moving = true
            end
            b.root.CFrame = CF(tank.position) * ANG(0, tank.yaw, 0)
        end
    end
    if moving ~= tank.moving then
        tank.moving = moving
        for _, host in pairs(b.dust or {}) do
            host.Enabled = moving
        end
    end
    -- Slow turret scan while the turret is operational (one weld offset at ~10 Hz).
    if tank.scan and status.turretOperational and t - tank.scanAt >= 0.1 then
        tank.scanAt = t
        tank.turretYaw = math.sin(t * tank.scanRate + tank.scanPhase) * math.rad(34) + tank.turretBias
        b.turretWeld.C0 = b.turretBase * ANG(0, tank.turretYaw, 0)
    end
end

local function dustEmitters(b)
    b.dust = {}
    for tag, t in pairs(b.tracks) do
        local a = Instance.new("Attachment")
        a.Name = "DustPoint"
        a.Position = V3(0, -2.0, 10)
        a.Parent = t.body
        local e = Instance.new("ParticleEmitter")
        e.Name = "TrackDust"
        e.Texture = "rbxasset://textures/particles/smoke_main.dds"
        e.Color = ColorSequence.new(Color3.fromRGB(150, 140, 120))
        e.Rate, e.Lifetime = 18, NumberRange.new(1.2, 2.2)
        e.Speed, e.SpreadAngle = NumberRange.new(2, 5), Vector2.new(30, 30)
        e.EmissionDirection = Enum.NormalId.Top
        e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 4) })
        e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
        e.Enabled = false
        e.Parent = a
        b.dust[tag] = e
    end
end

-- Build / respawn --------------------------------------------------------------------------------------------------------------
local function construct(d, tank)
    local b = newBuild(d, tank)
    tank.build, tank.model, tank.root = b, b.model, b.root
    buildGeometry(b, tank)
    dustEmitters(b)
    tank.units = {
        HULL = Unit.New({ material = "VEHICLE_HULL" }),
        TURRET = Unit.New({ material = "VEHICLE_TURRET" }),
        TRACK_L = Unit.New({ material = "VEHICLE_TRACK" }),
        TRACK_R = Unit.New({ material = "VEHICLE_TRACK" }),
        ENGINE = Unit.New({ material = "VEHICLE_ENGINE" }),
    }
    tank.comps = {}
    for name, unit in pairs(tank.units) do
        tank.comps[name] = { unit = unit }
        for _, part in ipairs(b.groups[name].hit) do
            Destructibles.IndexPart(d, tank, name, part)
        end
    end
    tank.emitters, tank.marks, tank.lastMark = {}, {}, -100
    tank.position, tank.yaw = tank.spawnCF.Position, math.atan2(-tank.spawnCF.LookVector.X, -tank.spawnCF.LookVector.Z)
    tank.turretYaw = tank.turretBias
    b.turretWeld.C0 = b.turretBase * ANG(0, tank.turretBias, 0)
    tank.scan = tank.scanRate > 0
    tank.scanAt = 0
    tank.moving = false
    if tank.patrol then
        tank.patrol.index, tank.patrol.step = 1, 1
    end
    tank.status = Rules.Tank(tank.units)
    tank.model:SetAttribute("Status", tank.status.status)
    tank.model:SetAttribute("Mobile", true)
    tank.model:SetAttribute("TurretOperational", true)
    tank.model.Parent = d.folder
end

local function respawn(d, tank)
    Destructibles.UnindexObject(tank)
    if tank.model then
        tank.model:Destroy()
    end
    construct(d, tank)
    tank.root.CFrame = tank.spawnCF
end

-- spec: id, cf (ground-level, faces -Z of the CFrame), palette ("OLIVE"|"SAND"|"SLATE"), turretYaw?, scan? (rate rad/s),
-- patrol? { points = {Vector3...}, speed, turnRate }
function TrainingTank.Create(d, spec)
    local tank = {
        kind = "vehicle", id = spec.id, spawnCF = spec.cf, palette = TrainingTank.PALETTES[spec.palette or "OLIVE"],
        turretBias = math.rad(spec.turretYaw or 0), scanRate = spec.scan or 0, scanPhase = math.random() * 6,
        patrol = if spec.patrol then { points = spec.patrol.points, speed = spec.patrol.speed or 5, turnRate = spec.patrol.turnRate or math.rad(22), index = 1, step = 1 } else nil,
        onStage = onStage, onHit = function(_, tank, comp, position, normal, class) mark(tank, comp, position, normal, class) end,
        update = update, respawn = respawn, parts = {}, marks = {}, lastMark = -100,
    }
    construct(d, tank)
    table.insert(d.objects, tank)
    table.insert(d.vehicles, tank)
    d.totals.vehicles += 1
    d.totals.targets += 1
    return tank
end

function TrainingTank.Describe(tank)
    local b = tank.build
    return { parts = #b.parts, components = 5, status = tank.status.status, emitters = #tank.emitters }
end

return TrainingTank
