-- Bounded outdoor proving ground behind the hangar exit (M07). Bay-local coordinates, like HangarArchitecture:
-- the hangar door is at z = 55..60, +Z is outward. Everything is plain Parts (query + collide) so the drive probe sees it
-- through ordinary raycasts/blockcasts; set dressing that cannot be walked into is CanQuery=false.
--
--   z   0..58   hangar interior (HangarArchitecture)
--   z  58..70   threshold apron
--   z  70..320  field, 136 wide (x = +-68; bays are 140 apart so neighbouring grounds never overlap)
--   road        44 wide, runs from the door to the far end of the field along x = 0
--
-- M10A: the far wall now has a 54-wide gate on the road leading into the Destruction Testing District (DistrictBuilder), which
-- continues this coordinate frame from z = 321 to z = 700.
-- Layout for evaluating the machine: a straight road (acceleration, braking, reversing), distance markers every 25 studs,
-- a road slalom, a container stack and tank farm (collision), a gantry arch to walk through, a low curb (step-over),
-- two raised areas with ramps (slope handling), and a lit return gate marked HANGAR.

local HangarKit = require(script.Parent.HangarKit)

local ProvingGround = {}

local part, cyl, glow, sign, light = HangarKit.part, HangarKit.cyl, HangarKit.glow, HangarKit.sign, HangarKit.light
local COLOR = HangarKit.COLOR
local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local SOLID = { query = true, collide = true }
local CONCRETE = Enum.Material.Concrete
local METAL = Enum.Material.Metal
local PLATE = Enum.Material.DiamondPlate

ProvingGround.FIELD_HALF_WIDTH = 68
ProvingGround.FIELD_START = 60.5
ProvingGround.FIELD_END = 320
ProvingGround.ROAD_HALF_WIDTH = 22

local ASPHALT = Color3.fromRGB(34, 36, 39)
local GROUND = Color3.fromRGB(70, 72, 62)
local GROUND_DARK = Color3.fromRGB(58, 60, 52)
local LINE_WHITE = Color3.fromRGB(190, 192, 188)
local CONTAINER_COLORS = { Color3.fromRGB(86, 96, 66), Color3.fromRGB(110, 88, 52), Color3.fromRGB(70, 82, 96), Color3.fromRGB(104, 62, 50) }

-- A wedge that rises toward `dir` (+Z in its own frame, verified against raycasts): width x rise x run, resting on y = base.
local function ramp(parent, name, at, x, base, z, width, rise, run, facing, color)
    local w = Instance.new("WedgePart")
    w.Name = name
    w.Size = V3(width, rise, run)
    w.CFrame = at(x, base + rise / 2, z) * (if facing < 0 then ANG(0, math.pi, 0) else CFrame.identity)
    w.Anchored = true
    w.CanCollide, w.CanQuery, w.CanTouch = true, true, false
    w.Material = CONCRETE
    w.Color = color or GROUND_DARK
    w.TopSurface, w.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    w.Parent = parent
    return w
end

local function container(parent, at, x, y, z, yaw, color)
    local cf = at(x, y, z) * ANG(0, yaw, 0)
    part(parent, "Container", V3(24, 9, 9.6), cf, color, METAL, SOLID)
    for i = -5, 5, 2 do -- corrugation ribs
        part(parent, "ContainerRib", V3(0.5, 8.4, 9.9), cf * CF(i * 2.1, 0, 0), color:Lerp(Color3.new(0, 0, 0), 0.25), METAL)
    end
    part(parent, "ContainerFrame", V3(24.4, 0.5, 10), cf * CF(0, 4.5, 0), COLOR.gunmetal, METAL)
    part(parent, "ContainerSill", V3(24.4, 0.5, 10), cf * CF(0, -4.5, 0), COLOR.gunmetal, METAL)
end

local function marker(parent, at, z, label, side)
    local x = side * 25.5
    part(parent, "MarkerPost", V3(0.7, 7, 0.7), at(x, 3.5, z), COLOR.gunmetal, METAL, SOLID)
    sign(parent, "MarkerSign", label, V3(5.2, 2.6, 0.3), at(x, 7.6, z) * ANG(0, -side * math.pi / 2, 0), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    glow(parent, "MarkerLamp", V3(0.9, 0.5, 0.9), at(x, 9.1, z), COLOR.amber)
end

function ProvingGround.Build(bay: Model, origin: Vector3)
    local function at(x, y, z)
        return CF(origin + V3(x, y, z))
    end
    local g = Instance.new("Model")
    g.Name = "ProvingGround"
    g.Parent = bay
    require(script.Parent.CombatTargets).Build(g, origin)
    local HW, Z0, Z1 = ProvingGround.FIELD_HALF_WIDTH, ProvingGround.FIELD_START, ProvingGround.FIELD_END
    part(g, "EnergyTestConsole", V3(4,4,2), at(54,2,108), COLOR.gunmetal, METAL)
    sign(g, "EnergyTestInstructions", "PULSE DEFENSE TEST RANGE\nH: SCHEDULE IMPACT / J: CATEGORY\nG: PULSE GUARD / K: WEAPON LOAD SIM\nDIAGNOSTIC DAMAGE ONLY", V3(13,6,0.2), at(54,7,108), Enum.NormalId.Front, COLOR.black, COLOR.cool, 22)
    local length = Z1 - Z0

    -- Ground, apron and road ---------------------------------------------------------------------------------------------
    part(g, "Field", V3(HW * 2, 4, length), at(0, -2.1, Z0 + length / 2), GROUND, Enum.Material.Ground, SOLID)
    part(g, "Apron", V3(2 * ProvingGround.ROAD_HALF_WIDTH, 3, 14), at(0, -1.5, 57.5 + 7), COLOR.concreteDark, PLATE, SOLID)
    local roadLength = Z1 - 64.5
    part(g, "Road", V3(2 * ProvingGround.ROAD_HALF_WIDTH, 3, roadLength), at(0, -1.5, 64.5 + roadLength / 2), ASPHALT, Enum.Material.Asphalt, SOLID)
    for _, s in ipairs({ -1, 1 }) do
        part(g, "RoadEdgeLine", V3(0.7, 0.05, roadLength), at(s * 20.6, 0.03, 64.5 + roadLength / 2), COLOR.hazardYellow, Enum.Material.SmoothPlastic, { shadow = false })
    end
    for z = 72, Z1 - 8, 12 do
        part(g, "RoadDash", V3(0.6, 0.05, 5), at(0, 0.03, z), LINE_WHITE, Enum.Material.SmoothPlastic, { shadow = false })
    end
    -- Door threshold: hazard-striped sill where the hangar floor meets the apron.
    part(g, "ThresholdPlate", V3(44, 0.12, 2.4), at(0, 0.04, 59.2), COLOR.black, METAL, { shadow = false })

    -- Distance markers (studs from the hangar door at z = 58) --------------------------------------------------------------
    for d = 25, 250, 25 do
        local z = 58 + d
        marker(g, at, z, string.format("%03d", d), -1)
        marker(g, at, z, string.format("%03d", d), 1)
    end
    for d = 50, 250, 50 do -- painted range lines across the whole field with a big ground label
        local z = 58 + d
        part(g, "RangeLine", V3(HW * 2 - 2, 0.05, 0.6), at(0, -0.05, z), LINE_WHITE, Enum.Material.SmoothPlastic, { shadow = false })
        for _, s in ipairs({ -1, 1 }) do
            sign(g, "RangeLabel", string.format("%d", d), V3(10, 0.05, 4), at(s * 46, -0.02, z - 2.8), Enum.NormalId.Top, GROUND, LINE_WHITE)
        end
    end

    -- Perimeter: concrete barrier wall with hazard cap and amber beacons ------------------------------------------------------
    local function wall(name, size, cf)
        part(g, name, size, cf, COLOR.concrete, CONCRETE, SOLID)
        local cap = part(g, name .. "Cap", V3(size.X + (if size.X > size.Z then 0 else 0.4), 0.5, size.Z + (if size.Z > size.X then 0 else 0.4)), cf * CF(0, size.Y / 2 + 0.25, 0), COLOR.hazardYellow, METAL)
        cap.CastShadow = false
    end
    local wallHeight = 10
    for _, s in ipairs({ -1, 1 }) do
        wall("PerimeterSide", V3(2, wallHeight, length), at(s * (HW + 1), wallHeight / 2, Z0 + length / 2))
    end
    -- M10A: the far wall is opened along the road (x = +-27) into the Destruction Testing District (DistrictBuilder).
    local gateHalf = 27
    local segment = HW + 2 - gateHalf
    for _, side in ipairs({ -1, 1 }) do
        wall("PerimeterFar", V3(segment, wallHeight, 2), at(side * (gateHalf + segment / 2), wallHeight / 2, Z1 + 1))
    end
    for z = Z0 + 20, Z1, 40 do
        for _, s in ipairs({ -1, 1 }) do
            glow(g, "WallBeacon", V3(0.8, 0.8, 0.8), at(s * (HW - 0.2), wallHeight + 1, z), COLOR.amber)
        end
    end
    sign(g, "FarSign", "STAGING RANGE END\nDISTRICT GATE: ROAD CENTRE", V3(36, 4, 0.3), at(-48, 6, Z1 - 0.2), Enum.NormalId.Back, COLOR.black, COLOR.hazardYellow)

    -- Return gate: gantry arch over the road with a sign facing the field ----------------------------------------------------------------
    local gateZ = 88
    for _, s in ipairs({ -1, 1 }) do
        part(g, "GatePillar", V3(3, 30, 3), at(s * 29, 15, gateZ), COLOR.gunmetal, METAL, SOLID)
        part(g, "GatePillarBase", V3(5, 1.2, 5), at(s * 29, 0.6, gateZ), COLOR.hazardYellow, METAL)
        glow(g, "GatePillarLight", V3(0.4, 24, 0.4), at(s * 27.4, 14, gateZ + 1.6), COLOR.amber)
    end
    part(g, "GateBeam", V3(62, 4, 3.2), at(0, 30, gateZ), COLOR.gunmetal, METAL, SOLID)
    sign(g, "GateSign", "HANGAR BAY 01   >>   RETURN", V3(40, 3, 0.4), at(0, 30, gateZ + 1.7), Enum.NormalId.Front, COLOR.black, COLOR.amber)
    glow(g, "GateStripe", V3(60, 0.3, 0.3), at(0, 27.7, gateZ + 1.7), COLOR.amber)
    sign(g, "FacadeSign", "IRONFRAME  /  BAY 01  -  RETURN", V3(30, 3.2, 0.4), at(0, 41, 61.0), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    for _, x in ipairs({ -20, 20 }) do
        glow(g, "FacadeBeacon", V3(1.6, 1.6, 1.6), at(x, 38, 61.2), COLOR.amber)
        light(g:FindFirstChild("FacadeBeacon"), "PointLight", COLOR.amber, 30, 1.2)
    end

    -- Obstacles ----------------------------------------------------------------------------------------------------------------
    -- Container stack west of the road: collision test with large flat faces.
    container(g, at, -46, 4.5, 135, 0, CONTAINER_COLORS[1])
    container(g, at, -46, 4.5, 145.5, 0, CONTAINER_COLORS[2])
    container(g, at, -46, 13.5, 140, math.rad(8), CONTAINER_COLORS[3])
    container(g, at, -40, 4.5, 118, math.rad(90), CONTAINER_COLORS[4])
    -- Tank farm east of the road with a pipe rack between the tanks.
    for i, z in ipairs({ 150, 186 }) do
        cyl(g, "Tank", "Y", 24, 22, at(46, 12, z), Color3.fromRGB(86, 90, 92), METAL, SOLID)
        cyl(g, "TankCap", "Y", 1.2, 22.8, at(46, 24.6, z), COLOR.hazardYellow, METAL)
        part(g, "TankLadder", V3(0.6, 24, 1.6), at(46 - 11.2, 12, z), COLOR.gunmetal, METAL)
        glow(g, "TankLamp", V3(1, 1, 1), at(46, 25.6, z), if i == 1 then COLOR.amber else COLOR.red)
    end
    part(g, "PipeRack", V3(1.2, 1.2, 28), at(46, 5, 168), COLOR.gunmetal, METAL, SOLID)
    for _, z in ipairs({ 156, 168, 180 }) do
        part(g, "PipeRackLeg", V3(1, 5, 1), at(46, 2.5, z), COLOR.gunmetal, METAL)
    end
    -- Gantry arch on the road: walk-through clearance test (23 studs wide, 28 high).
    local arch = 228
    for _, s in ipairs({ -1, 1 }) do
        part(g, "ArchPillar", V3(6, 34, 6), at(s * 17, 17, arch), COLOR.olive, METAL, SOLID)
        part(g, "ArchPillarBand", V3(6.4, 2, 6.4), at(s * 17, 2.2, arch), COLOR.hazardYellow, METAL)
    end
    part(g, "ArchBeam", V3(40, 5, 6), at(0, 31.5, arch), COLOR.olive, METAL, SOLID)
    sign(g, "ArchSign", "CLEARANCE 28", V3(16, 2.4, 0.3), at(0, 31.5, arch + 3.2), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    glow(g, "ArchStripe", V3(40, 0.3, 0.3), at(0, 28.8, arch + 3.2), COLOR.amber)
    -- Slalom on the road past the arch: staggered barriers 14 studs apart; the 17-stud gaps force a weave for a 14-wide hull.
    for i = 0, 4 do
        local x = if i % 2 == 0 then -14 else 14
        part(g, "SlalomBlock", V3(11, 7, 4), at(x, 3.5, 255 + i * 14), COLOR.concrete, CONCRETE, SOLID)
        part(g, "SlalomStripe", V3(11.2, 1, 4.2), at(x, 5.8, 255 + i * 14), COLOR.hazardYellow, METAL)
    end
    -- Low curb across the western field: 1.6 studs, below the step-up limit.
    part(g, "Curb", V3(36, 1.6, 4), at(-44, 0.8, 285), COLOR.concreteDark, CONCRETE, SOLID)
    -- Raised pad with ramps (west): up 5 studs over 30, plateau, down again.
    ramp(g, "RampUpWest", at, -44, -0.1, 188, 36, 5.1, 30, 1)
    part(g, "PlateauWest", V3(36, 5.1, 26), at(-44, 2.45, 216), GROUND_DARK, CONCRETE, SOLID)
    ramp(g, "RampDownWest", at, -44, -0.1, 244, 36, 5.1, 30, -1)
    -- Broad shallow hill (east): 3.5 studs over 40.
    ramp(g, "HillUpEast", at, 44, -0.1, 296 - 40, 40, 3.6, 40, 1)
    ramp(g, "HillDownEast", at, 44, -0.1, 296 + 0, 40, 3.6, 40, -1)

    -- M10A destructible testing district (server-authoritative; see DistrictBuilder / Destructibles).
    require(script.Parent.DistrictBuilder).Build(bay, origin, g)
end

return ProvingGround
