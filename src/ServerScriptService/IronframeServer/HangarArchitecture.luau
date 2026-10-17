-- Procedural hangar shell for one bay: floor with service trenches, maintenance platform, walls, armored
-- doors, columns, truss, gantry crane and catwalks. Coordinates are bay-local: the Bastion stands at the
-- origin facing -Z, the camera sees it from the front-right, the armored doors are the +Z backdrop.
-- Interior: x in [-62, 62], z in [-58, 58], ceiling at y = 44.

local HangarKit = require(script.Parent.HangarKit)
local Architecture = {}

local part, cyl, glow, ibeam, hazard, sign = HangarKit.part, HangarKit.cyl, HangarKit.glow, HangarKit.ibeam, HangarKit.hazard, HangarKit.sign
local COLOR = HangarKit.COLOR
local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local STRUCT = { query = true, collide = false }
local FLOOR = { query = true, collide = true }
local PLATE = Enum.Material.DiamondPlate
local CONCRETE = Enum.Material.Concrete
local METAL = Enum.Material.Metal

Architecture.HALF_X, Architecture.HALF_Z, Architecture.HEIGHT = 62, 58, 44

local function floor(b, at)
    -- Slabs are 3 studs deep so the two service trenches (x = +-20..24) are real recesses.
    part(b, "SlabCenter", V3(40, 3, 116), at(0, -1.5, 0), COLOR.concreteDark, PLATE, FLOOR)
    part(b, "SlabEast", V3(38, 3, 116), at(43, -1.5, 0), COLOR.concrete, CONCRETE, FLOOR)
    part(b, "SlabWest", V3(38, 3, 116), at(-43, -1.5, 0), COLOR.concrete, CONCRETE, FLOOR)
    for _, s in ipairs({ -1, 1 }) do
        local tag = if s < 0 then "W" else "E"
        part(b, "TrenchFloor" .. tag, V3(4, 0.5, 116), at(s * 22, -3.25, 0), COLOR.black, METAL, FLOOR)
        glow(b, "TrenchGlowA" .. tag, V3(0.3, 0.2, 116), at(s * 20.6, -2.9, 0), COLOR.amber)
        glow(b, "TrenchGlowB" .. tag, V3(0.3, 0.2, 116), at(s * 23.4, -2.9, 0), COLOR.amber)
        for _, z in ipairs({ -46, -22, 22, 46 }) do
            part(b, "TrenchGrate" .. tag, V3(4.6, 0.4, 5), at(s * 22, -0.2, z), COLOR.steel, PLATE, FLOOR)
        end
        for i = 0, 5 do
            part(b, "TrenchPipe" .. tag .. i, V3(0.5, 0.5, 8), at(s * 22 + (i % 2 == 0 and -1 or 1), -2.5, -40 + i * 16), COLOR.gunmetal, METAL)
        end
    end
    -- plate seams and expansion joints
    for z = -56, 56, 8 do
        part(b, "PlateSeam", V3(40, 0.06, 0.18), at(0, 0.02, z), COLOR.black, METAL)
    end
    for z = -50, 50, 20 do
        for _, s in ipairs({ -1, 1 }) do
            part(b, "ExpansionJoint", V3(38, 0.06, 0.3), at(s * 43, 0.02, z), COLOR.black, METAL)
        end
    end
    -- directional guide lines: amber approach lanes toward the platform, kept dim
    for _, s in ipairs({ -1, 1 }) do
        glow(b, "GuideLane", V3(0.35, 0.08, 30), at(s * 15, 0.05, -40), COLOR.amber)
        glow(b, "GuideLaneRear", V3(0.35, 0.08, 24), at(s * 15, 0.05, 42), COLOR.amber)
    end
end

local function platform(b, at)
    -- Top surface at y = 0.4 (the Bastion's feet rest at 0.45).
    part(b, "PlatformStep", V3(44, 0.3, 42), at(0, 0.15, 0), COLOR.steel, PLATE, FLOOR)
    part(b, "PlatformDeck", V3(38, 0.4, 36), at(0, 0.2, 0), COLOR.concreteDark, PLATE, FLOOR)
    part(b, "MechPad", V3(22, 0.05, 20), at(0, 0.41, 0), COLOR.black, METAL)
    -- hazard borders on the deck edge
    hazard(b, "HazardFront", V3(38, 0.06, 1.4), at(0, 0.42, -17.2), Enum.NormalId.Top, 9)
    hazard(b, "HazardBack", V3(38, 0.06, 1.4), at(0, 0.42, 17.2), Enum.NormalId.Top, 9)
    hazard(b, "HazardLeft", V3(1.4, 0.06, 34), at(-18.2, 0.42, 0), Enum.NormalId.Top, 9)
    hazard(b, "HazardRight", V3(1.4, 0.06, 34), at(18.2, 0.42, 0), Enum.NormalId.Top, 9)
    -- amber docking beacons around the pad and corner clamps
    for _, x in ipairs({ -14, 0, 14 }) do
        for _, z in ipairs({ -11.4, 11.4 }) do
            glow(b, "PadLight", V3(1.2, 0.12, 0.4), at(x, 0.46, z), COLOR.amber)
        end
    end
    for _, x in ipairs({ -19, 19 }) do
        for _, z in ipairs({ -17, 17 }) do
            part(b, "ClampBase", V3(2.2, 1.2, 2.2), at(x, 0.9, z), COLOR.gunmetal, METAL)
            cyl(b, "ClampPost", "Y", 2.4, 1.2, at(x, 2.4, z), COLOR.steel, METAL)
            glow(b, "ClampBeacon", V3(0.8, 0.5, 0.8), at(x, 3.8, z), COLOR.amber)
        end
    end
    sign(b, "PadLabel", "IF-42 BASTION  /  MAINTENANCE BAY", V3(14, 0.05, 1.6), at(0, 0.42, -15.2), Enum.NormalId.Top, COLOR.black, COLOR.hazardYellow)
end

local function walls(b, at)
    local H = Architecture.HEIGHT
    -- long side walls: concrete shell, steel cladding, vertical ribs, clerestory light slits
    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "W" else "E"
        part(b, "Wall" .. t, V3(2.5, H, 118), at(s * 63.25, H / 2, 0), COLOR.concrete, CONCRETE, STRUCT)
        part(b, "Cladding" .. t, V3(0.6, 15, 116), at(s * 61.7, 7.5, 0), COLOR.steel, METAL, STRUCT)
        part(b, "CladdingCap" .. t, V3(1.0, 0.6, 116), at(s * 61.6, 15.2, 0), COLOR.gunmetal, METAL)
        for z = -54, 54, 9 do
            part(b, "WallRib" .. t, V3(1.0, 15, 1.4), at(s * 61.2, 7.5, z), COLOR.gunmetal, METAL)
        end
        -- upper wall: pilasters and glowing clerestory slits
        for z = -54, 54, 18 do
            part(b, "Pilaster" .. t, V3(1.6, 28, 2.4), at(s * 61.4, 30, z), COLOR.concreteDark, CONCRETE)
        end
        for z = -45, 45, 18 do
            glow(b, "Clerestory" .. t, V3(0.25, 4, 12), at(s * 61.9, 31, z), COLOR.cool, { transparency = 0.15 })
        end
        part(b, "WallBandUpper" .. t, V3(0.8, 1.2, 116), at(s * 61.6, 24.5, 0), COLOR.oliveDark, METAL)
    end
    -- south wall with an operations gallery window (behind the default camera)
    part(b, "WallSouth", V3(126, H, 2.5), at(0, H / 2, -59.25), COLOR.concrete, CONCRETE, STRUCT)
    part(b, "GalleryBox", V3(44, 10, 6), at(0, 24, -55.5), COLOR.steel, METAL)
    part(b, "GalleryGlass", V3(40, 5, 0.3), at(0, 24.5, -52.6), COLOR.cool, Enum.Material.Glass, { transparency = 0.55 })
    glow(b, "GalleryStrip", V3(40, 0.25, 0.3), at(0, 21.4, -52.5), COLOR.amber)
    sign(b, "GallerySign", "OPERATIONS  /  BAY 01", V3(14, 2.2, 0.3), at(0, 31, -57.9), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
end

local function doors(b, at)
    local H = Architecture.HEIGHT
    -- north wall pieces either side of the opening (x in [-22, 22], y in [0, 34])
    for _, s in ipairs({ -1, 1 }) do
        part(b, "WallNorth" .. (s < 0 and "W" or "E"), V3(40, H, 2.5), at(s * 42, H / 2, 59.25), COLOR.concrete, CONCRETE, STRUCT)
    end
    part(b, "WallNorthHeader", V3(44, 10, 2.5), at(0, 39, 59.25), COLOR.concrete, CONCRETE, STRUCT)
    -- frame
    for _, s in ipairs({ -1, 1 }) do
        part(b, "DoorJamb", V3(3, 34, 4), at(s * 23.5, 17, 57.6), COLOR.steel, METAL, STRUCT)
        part(b, "DoorJambPlate", V3(1, 34, 5.2), at(s * 25.2, 17, 57.6), COLOR.oliveDark, METAL)
    end
    part(b, "DoorLintel", V3(50, 3, 4.4), at(0, 35.5, 57.6), COLOR.steel, METAL, STRUCT)
    -- two heavy leaves with ribbing, hazard kick bands and a glowing centre seam
    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "L" else "R"
        local cx = s * 10.95
        part(b, "DoorLeaf" .. t, V3(21.3, 33.5, 2.2), at(cx, 16.75, 55.6), COLOR.gunmetal, METAL, STRUCT)
        for i = 1, 7 do
            part(b, "DoorRib" .. t .. i, V3(20.4, 0.9, 0.7), at(cx, 4 + i * 4, 54.3), COLOR.steel, METAL)
        end
        for _, x in ipairs({ -8.5, 0, 8.5 }) do
            part(b, "DoorStile" .. t, V3(1.0, 33, 0.8), at(cx + x, 16.75, 54.2), COLOR.oliveDark, METAL)
        end
        hazard(b, "DoorHazard" .. t, V3(21.3, 4, 0.2), at(cx, 2, 54.45), Enum.NormalId.Front, 9)
        part(b, "DoorTrack" .. t, V3(21.3, 0.5, 1.4), at(cx, 0.25, 55.6), COLOR.steel, PLATE)
    end
    glow(b, "DoorSeamLeak", V3(0.3, 32, 0.4), at(0, 17, 54.3), COLOR.cool, { transparency = 0.55 })
    -- header beacons and lamps
    for i, x in ipairs({ -16, -8, 8, 16 }) do
        part(b, "BeaconBase" .. i, V3(2.2, 1, 1.6), at(x, 37.2, 54.2), COLOR.black, METAL)
        glow(b, "Beacon" .. i, V3(1.6, 1.0, 0.8), at(x, 37.2, 53.6), if i % 2 == 0 then COLOR.amber else COLOR.red)
    end
    sign(b, "DoorSign", "BAY EXIT 01  -  CLEAR PATH", V3(16, 2.4, 0.3), at(0, 38.5, 54.0), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    -- floor chevron lane leading to the doors
    hazard(b, "DoorApronA", V3(44, 0.06, 1.6), at(0, 0.03, 49), Enum.NormalId.Top, 9)
end

local function ceiling(b, at)
    local H = Architecture.HEIGHT
    part(b, "Ceiling", V3(126, 1, 118), at(0, H + 0.5, 0), COLOR.steel, METAL, STRUCT)
    for _, z in ipairs({ -48, -24, 0, 24, 48 }) do
        ibeam(b, "TrussX", 124, 3.4, 1.8, at(0, H - 2.2, z), COLOR.gunmetal)
    end
    for _, x in ipairs({ -32, 0, 32 }) do
        ibeam(b, "PurlinZ", 116, 2.2, 1.2, at(x, H - 4.8, 0) * ANG(0, math.pi / 2, 0), COLOR.steel, nil)
    end
    for _, z in ipairs({ -36, -12, 12, 36 }) do
        for _, x in ipairs({ -40, -14, 14, 40 }) do
            glow(b, "CeilingPanel", V3(10, 0.2, 5), at(x, H - 0.3, z), COLOR.cool, { transparency = 0.45 })
        end
    end
end

local function columns(b, at)
    local H = Architecture.HEIGHT
    for _, s in ipairs({ -1, 1 }) do
        for _, z in ipairs({ -44, -15, 15, 44 }) do
            local x = s * 50
            part(b, "ColumnBase", V3(4.6, 0.7, 4.6), at(x, 0.35, z), COLOR.steel, PLATE, STRUCT)
            part(b, "ColumnShaft", V3(2.4, H, 2.4), at(x, H / 2, z), COLOR.gunmetal, METAL, STRUCT)
            part(b, "ColumnFlangeA", V3(0.6, H - 1, 3.4), at(x - 1.5, H / 2 + 0.5, z), COLOR.steel, METAL)
            part(b, "ColumnFlangeB", V3(0.6, H - 1, 3.4), at(x + 1.5, H / 2 + 0.5, z), COLOR.steel, METAL)
            for i = 0, 3 do
                part(b, "ColumnHazard", V3(2.9, 0.9, 2.9), at(x, 1.2 + i * 0.9, z), if i % 2 == 0 then COLOR.hazardYellow else COLOR.black, METAL)
            end
            part(b, "ColumnBand", V3(2.7, 1.2, 2.7), at(x, 26, z), COLOR.olive, METAL)
            part(b, "CorbelBracket", V3(3.4, 1.4, 3.0), at(x - s * 2.6, 35, z), COLOR.steel, METAL)
        end
        -- tie beams between columns
        for _, y in ipairs({ 21, 31 }) do
            for _, zz in ipairs({ -29.5, 0, 29.5 }) do
                part(b, "TieBeam", V3(1.4, 1.6, 26.6), at(s * 50, y, zz), COLOR.steel, METAL)
            end
        end
    end
end

local function crane(b, at)
    -- runway beams, bridge, trolley, hoist and a hanging hook block over the Bastion
    for _, s in ipairs({ -1, 1 }) do
        ibeam(b, "Runway", 116, 3.2, 1.8, at(s * 46, 36, 0) * ANG(0, math.pi / 2, 0), COLOR.gunmetal)
        part(b, "EndTruck", V3(5, 3.6, 9), at(s * 46, 33.2, 6), COLOR.olive, METAL)
        cyl(b, "TruckWheel", "X", 0.8, 2.6, at(s * 46, 34.4, 3), COLOR.black, METAL)
        cyl(b, "TruckWheel", "X", 0.8, 2.6, at(s * 46, 34.4, 9), COLOR.black, METAL)
    end
    for _, dz in ipairs({ 3.4, 8.6 }) do
        ibeam(b, "BridgeGirder", 92, 3.6, 1.6, at(0, 32.6, dz), COLOR.gunmetal)
    end
    part(b, "BridgeWalk", V3(92, 0.3, 2.2), at(0, 34.5, 11.2), COLOR.steel, PLATE)
    part(b, "Trolley", V3(8, 2.4, 6.4), at(0, 30.2, 6), COLOR.olive, METAL)
    cyl(b, "HoistDrum", "Z", 5.2, 2.6, at(0, 28.6, 6), COLOR.black, METAL)
    cyl(b, "HoistWire", "Y", 12, 0.35, at(0, 22.4, 6), COLOR.black, METAL)
    part(b, "HookBlock", V3(3.2, 3, 2.4), at(0, 16.2, 6), COLOR.gunmetal, METAL)
    part(b, "HookBlockStripe", V3(3.3, 0.6, 2.5), at(0, 17.2, 6), COLOR.hazardYellow, METAL)
    cyl(b, "HookShank", "Y", 2.6, 0.9, at(0, 13.9, 6), COLOR.steel, METAL)
    part(b, "HookBody", V3(1.2, 1.4, 0.9), at(0, 12.4, 6), COLOR.steel, METAL)
    part(b, "HookTip", V3(0.8, 0.6, 0.8), at(0.7, 11.6, 6), COLOR.steel, METAL)
    glow(b, "CraneBeacon", V3(1, 0.8, 1), at(-3.5, 31.8, 6), COLOR.amber)
end

local function catwalks(b, at)
    local Y = 14
    for _, s in ipairs({ -1, 1 }) do
        local t = if s < 0 then "W" else "E"
        local x = s * 56
        part(b, "CatwalkDeck" .. t, V3(6, 0.5, 80), at(x, Y, -9), COLOR.steel, PLATE, STRUCT)
        part(b, "CatwalkKick" .. t, V3(0.3, 0.5, 80), at(s * 53.1, Y + 0.5, -9), COLOR.black, METAL)
        -- handrails on the room side
        for z = -48, 30, 6 do
            part(b, "RailPost" .. t, V3(0.3, 3.4, 0.3), at(s * 53, Y + 1.7, z), COLOR.hazardYellow, METAL)
        end
        cyl(b, "RailTop" .. t, "Z", 78, 0.3, at(s * 53, Y + 3.3, -9), COLOR.hazardYellow, METAL)
        cyl(b, "RailMid" .. t, "Z", 78, 0.25, at(s * 53, Y + 2.0, -9), COLOR.hazardYellow, METAL)
        -- wall brackets with braces
        for z = -46, 28, 12 do
            part(b, "CatwalkBracket" .. t, V3(6, 0.6, 0.8), at(x, Y - 0.6, z), COLOR.gunmetal, METAL)
            part(b, "CatwalkBrace" .. t, V3(0.5, 8, 0.5), at(s * 58.8, Y - 3.6, z) * ANG(0, 0, s * 0.62), COLOR.gunmetal, METAL)
            -- under-catwalk warm cage lamp
            if (z + 46) % 24 == 0 then
                glow(b, "CatwalkLamp" .. t, V3(1.1, 0.5, 1.1), at(s * 53.5, Y - 1.2, z), COLOR.warm)
            end
        end
        -- stairs at the north end: 28 steps from the catwalk down to the floor
        for i = 0, 27 do
            part(b, "Stair" .. t, V3(6, 0.4, 0.95), at(x, Y - 0.5 - i * 0.5, 32 + i * 0.86), COLOR.steel, PLATE, STRUCT)
        end
        for _, xo in ipairs({ -2.9, 2.9 }) do
            part(b, "StairStringer" .. t, V3(0.3, 1.6, 27.8), at(x + xo, 6.6, 44) * ANG(0.53, 0, 0), COLOR.gunmetal, METAL)
        end
    end
end

function Architecture.Build(bay, origin)
    local function at(x, y, z)
        return CF(origin + V3(x, y, z))
    end
    floor(bay, at)
    platform(bay, at)
    walls(bay, at)
    doors(bay, at)
    ceiling(bay, at)
    columns(bay, at)
    crane(bay, at)
    catwalks(bay, at)
end

return Architecture
