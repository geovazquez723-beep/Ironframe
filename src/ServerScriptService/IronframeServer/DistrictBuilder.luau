-- Builds the M10A Destruction Testing District beyond the proving ground's far gate. Bay-local coordinates (like
-- ProvingGround): +Z leads away from the hangar, the hangar door is at z = 55..60, the existing proving ground ends at z = 320.
--
--   z  321..335  district gate plaza (the former far wall is opened along the road)
--   z  335..360  RANGE CONTROL tower (west) + reset station
--   z  366       entry chicane: six reinforced-concrete barriers either side of a 28-wide passage
--   z  392..408  tank traps + defensive barricade line (cover in front of the stationary armor)
--   z  395..540  CENTRAL VEHICLE TESTING FIELD: stationary tanks T-01 / T-02, ARMORED VEHICLE TESTING LANE (east, x 33..67) with the
--                patrolling tank T-03 between armored fence lines
--   z  496..520  fuel point (explosive tanks, machinery)       (west)
--   z  524..568  STATIONARY TRAINING MECH pad M-01              (west)
--   z  552..600  container yard: 9 containers, two tiers        (east)
--   z  578..602  gantry shed: columns, beams, roof panels       (west, partial-collapse demo)
--   z  614..654  Warehouse A (west) and Bunker B (east), breachable wall grids and collapsible roofs
--   z  692..700  RESERVED duel-arena gate: the logical expansion direction (+Z); nothing is built beyond it
--
-- The road continues along x = 0 (44 wide) so the Bastion (14 wide) always has a clear route. Everything destructible is
-- created through Destructibles.AddModule; everything else (ground, perimeter, tower, signs) is protected infrastructure.

local Destructibles = require(script.Parent.Destructibles)
local TrainingTank = require(script.Parent.TrainingTank)
local TrainingMech = require(script.Parent.TrainingMech)
local HangarKit = require(script.Parent.HangarKit)

local DistrictBuilder = {}

local part, cyl, glow, sign = HangarKit.part, HangarKit.cyl, HangarKit.glow, HangarKit.sign
local COLOR = HangarKit.COLOR
local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local SOLID = { query = true, collide = true }
local METAL, PLATE, CONCRETE, CORRUGATED = Enum.Material.Metal, Enum.Material.DiamondPlate, Enum.Material.Concrete, Enum.Material.Metal
local GLASS = Enum.Material.Glass
local UP = V3(0, 1, 0)

DistrictBuilder.ZONE_MIN_Z = 322 -- bay-local z where the district (and weapon-enabled destruction range) begins
DistrictBuilder.HALF_WIDTH = 68
DistrictBuilder.END_Z = 700
DistrictBuilder.EXPANSION = "+Z" -- reserved direction for the future duel arena

local GROUND = Color3.fromRGB(78, 76, 66)
local PAD = Color3.fromRGB(56, 58, 60)
local ASPHALT = Color3.fromRGB(34, 36, 39)
local LINE_WHITE = Color3.fromRGB(190, 192, 188)
local rng = Random.new(2210)

local function jitter(color: Color3, amount: number): Color3
    local f = 1 + rng:NextNumber(-amount, amount)
    return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

-- Wall grid ------------------------------------------------------------------------------------------------------------------
-- o: group, label, a/b (Vector2 x,z bay-local), thick, rows = {{ h, material, surface, color, hp?, resist?, transparency? }}, panelW,
--    gaps = {{from, to}} distances along the line left open in every row, skip(row, col) -> bool for window-like holes.
-- Each module is supported by the module directly beneath it: lose the lower course and the upper one comes down.
local function wallGrid(ctx, o)
    local origin, d = ctx.origin, ctx.d
    local delta = o.b - o.a
    local length = delta.Magnitude
    local dir = V3(delta.X, 0, delta.Y) / length
    local cols = math.max(1, math.round(length / (o.panelW or 8)))
    local w = length / cols
    local grid = {}
    local y0 = 0
    for row, spec in ipairs(o.rows) do
        grid[row] = {}
        for col = 1, cols do
            local t0, t1 = (col - 1) * w, col * w
            local gap = false
            for _, g in ipairs(o.gaps or {}) do
                if t0 >= g[1] - 0.01 and t1 <= g[2] + 0.01 then
                    gap = true
                end
            end
            if not gap and not (o.skip and o.skip(row, col)) then
                local center = origin + V3(o.a.X, 0, o.a.Y) + dir * (t0 + w / 2) + V3(0, y0 + spec.h / 2, 0)
                local supports
                if row > 1 and grid[row - 1][col] then
                    supports = { grid[row - 1][col] }
                end
                local module = Destructibles.AddModule(d, {
                    name = string.format("%s_R%dC%d", o.group, row, col), group = o.group, groupKind = "wall", label = o.label,
                    size = V3(w - 0.06, spec.h - 0.06, o.thick), cf = CFrame.fromMatrix(center, dir, UP),
                    material = spec.material, surface = spec.surface, color = jitter(spec.color, 0.05), hp = spec.hp, resist = spec.resist,
                    transparency = spec.transparency, supports = supports, parent = o.parent,
                })
                grid[row][col] = module
            end
        end
        y0 += spec.h
    end
    return grid, y0, cols
end

-- Mixed-height container: static frame + destructible shell panels --------------------------------------------------------------
local CONTAINER_COLORS = { Color3.fromRGB(86, 96, 66), Color3.fromRGB(122, 94, 52), Color3.fromRGB(70, 84, 100), Color3.fromRGB(112, 62, 50), Color3.fromRGB(96, 98, 92) }

local function container(ctx, id, center: Vector3, yaw: number, color: Color3)
    local d = ctx.d
    local base = CF(ctx.origin + center) * ANG(0, yaw, 0)
    local parent = Instance.new("Model")
    parent.Name = id
    parent.Parent = d.folder
    local frameColor = color:Lerp(Color3.new(0, 0, 0), 0.35)
    -- Static frame: floor, back end, corner posts. Always present, so an opened container keeps its footprint.
    part(parent, "Floor", V3(9, 0.7, 22), base * CF(0, -4.05, 0), frameColor, PLATE, SOLID)
    part(parent, "BackEnd", V3(9, 8.4, 0.6), base * CF(0, 0, 10.7), color, CORRUGATED, SOLID)
    for _, x in ipairs({ -4.3, 4.3 }) do
        for _, z in ipairs({ -10.6, 10.6 }) do
            part(parent, "Post", V3(0.9, 9, 0.9), base * CF(x, 0, z), frameColor, METAL, SOLID)
        end
    end
    part(parent, "Cargo", V3(5.5, 3.2, 7), base * CF(1, -2.0, 1.5), Color3.fromRGB(110, 88, 56), Enum.Material.Wood, { shadow = false })
    part(parent, "CargoB", V3(3.4, 2.6, 4.6), base * CF(-1.6, -2.3, -4.2), Color3.fromRGB(82, 90, 70), Enum.Material.Wood, { shadow = false })
    local group = id
    local function shell(name, size, cf, material, hp)
        return Destructibles.AddModule(d, {
            name = id .. "_" .. name, group = group, groupKind = "container", label = "Container " .. id, parent = parent,
            size = size, cf = cf, material = material or "ARMOR", surface = CORRUGATED, color = color, hp = hp,
        })
    end
    local roof = shell("Roof", V3(9, 0.5, 22), base * CF(0, 4.35, 0), "ARMOR", 340)
    shell("SideA", V3(0.5, 8.2, 21.2), base * CF(4.5, 0, 0), "ARMOR", 300)
    shell("SideB", V3(0.5, 8.2, 21.2), base * CF(-4.5, 0, 0), "ARMOR", 300)
    shell("Doors", V3(8.4, 8.2, 0.5), base * CF(0, 0, -10.95), "ARMOR", 260)
    return roof
end

-- Machinery -----------------------------------------------------------------------------------------------------------------
local function generator(ctx, id, at: Vector3, yaw: number, parent)
    local base = CF(ctx.origin + at) * ANG(0, yaw, 0)
    Destructibles.AddModule(ctx.d, {
        name = id, group = id, groupKind = "machine", label = "Generator " .. id, parent = parent, material = "MACHINERY", wreck = true,
        size = V3(6, 5, 10), cf = base * CF(0, 2.5, 0), surface = METAL, color = Color3.fromRGB(176, 128, 36), hp = 190,
        decor = function(holder, body)
            part(holder, "Exhaust", V3(0.9, 3, 0.9), body.CFrame * CF(2, 3.9, 3.5), Color3.fromRGB(34, 34, 36), METAL)
            part(holder, "Vent", V3(5.6, 2.4, 0.2), body.CFrame * CF(0, 0.2, -5.1), Color3.fromRGB(18, 18, 20), METAL)
            part(holder, "Stripe", V3(6.1, 0.5, 10.1), body.CFrame * CF(0, 1.4, 0), COLOR.hazardYellow, METAL)
            glow(holder, "Lamp", V3(0.6, 0.6, 0.3), body.CFrame * CF(2.2, 1.4, -5.15), COLOR.green)
        end,
    })
end

local function transformer(ctx, id, at: Vector3, parent)
    local base = CF(ctx.origin + at)
    Destructibles.AddModule(ctx.d, {
        name = id, group = id, groupKind = "machine", label = "Transformer " .. id, parent = parent, material = "MACHINERY", wreck = true,
        size = V3(5, 6, 4), cf = base * CF(0, 3, 0), surface = METAL, color = Color3.fromRGB(84, 92, 98), hp = 170,
        decor = function(holder, body)
            for i = -1, 1 do
                cyl(holder, "Insulator", "Y", 2.4, 0.9, body.CFrame * CF(i * 1.5, 4.2, 0), Color3.fromRGB(190, 176, 150), Enum.Material.SmoothPlastic)
            end
            part(holder, "Fins", V3(5.4, 4.2, 0.4), body.CFrame * CF(0, -0.2, 2.15), Color3.fromRGB(52, 58, 62), METAL)
        end,
    })
end

local function fuelTank(ctx, id, at: Vector3, parent)
    Destructibles.AddModule(ctx.d, {
        name = id, group = id, groupKind = "machine", label = "Fuel tank " .. id, parent = parent, material = "MACHINERY", wreck = true,
        size = V3(14, 6.4, 6.4), cf = CF(ctx.origin + at + V3(0, 3.3, 0)), surface = METAL, color = Color3.fromRGB(150, 54, 40), hp = 230,
        shape = Enum.PartType.Cylinder, explosive = { radius = 15, damage = 130 },
        decor = function(holder, body)
            part(holder, "CradleA", V3(1.4, 1.2, 7), body.CFrame * CF(-4, -3.0, 0), COLOR.gunmetal, METAL)
            part(holder, "CradleB", V3(1.4, 1.2, 7), body.CFrame * CF(4, -3.0, 0), COLOR.gunmetal, METAL)
            glow(holder, "Warning", V3(0.2, 1.2, 1.2), body.CFrame * CF(0, 3.25, 0), COLOR.amber)
        end,
    })
end

-- Concrete barrier (jersey profile approximated by a base slab) -------------------------------------------------------------------
local function barrier(ctx, group, label, name, size: Vector3, at: Vector3, yaw: number, hp: number?, parent)
    local base = CF(ctx.origin + at) * ANG(0, yaw, 0)
    return Destructibles.AddModule(ctx.d, {
        name = name, group = group, groupKind = "barrier", label = label, parent = parent, material = "CONCRETE", surface = CONCRETE,
        size = size, cf = base * CF(0, size.Y / 2, 0), color = jitter(COLOR.concrete:Lerp(Color3.new(1, 1, 1), 0.22), 0.06), hp = hp,
        decor = function(holder, body)
            part(holder, "Footing", V3(size.X + 0.3, 1.0, size.Z + 1.4), base * CF(0, 0.5, 0), COLOR.concreteDark:Lerp(Color3.new(1, 1, 1), 0.15), CONCRETE)
            part(holder, "Stripe", V3(size.X + 0.05, 0.7, size.Z + 0.05), base * CF(0, size.Y - 1.6, 0), COLOR.hazardYellow, METAL, { shadow = false })
        end,
    })
end

local function fenceSegment(ctx, group, label, name, a: Vector3, b: Vector3, parent)
    local delta = b - a
    local length = delta.Magnitude
    local dir = delta / length
    local center = ctx.origin + (a + b) / 2 + V3(0, 3.5, 0)
    return Destructibles.AddModule(ctx.d, {
        name = name, group = group, groupKind = "fence", label = label, parent = parent, material = "ARMOR", surface = CORRUGATED, hp = 230,
        size = V3(length - 1.2, 6.6, 0.45), cf = CFrame.fromMatrix(center, dir, UP), color = Color3.fromRGB(70, 76, 80), transparency = 0.18,
    })
end

local function post(ctx, parent, at: Vector3)
    part(parent, "FencePost", V3(0.9, 8, 0.9), CF(ctx.origin + at + V3(0, 4, 0)), COLOR.gunmetal, METAL, SOLID)
    part(parent, "FencePostCap", V3(1.2, 0.4, 1.2), CF(ctx.origin + at + V3(0, 8.2, 0)), COLOR.hazardYellow, METAL)
end

-- Static infrastructure ---------------------------------------------------------------------------------------------------------------
local function infrastructure(ctx, g)
    local at = ctx.at
    local HW, Z0, Z1 = DistrictBuilder.HALF_WIDTH, DistrictBuilder.ZONE_MIN_Z - 1, DistrictBuilder.END_Z
    local len = Z1 - Z0
    part(g, "DistrictField", V3(HW * 2, 4, len), at(0, -2.1, Z0 + len / 2), GROUND, Enum.Material.Ground, SOLID)
    local roadEnd = Z1 - 8
    part(g, "DistrictRoad", V3(44, 3, roadEnd - 320), at(0, -1.5, 320 + (roadEnd - 320) / 2), ASPHALT, Enum.Material.Asphalt, SOLID)
    for _, s in ipairs({ -1, 1 }) do
        part(g, "RoadEdgeLine", V3(0.7, 0.05, roadEnd - 320), at(s * 20.6, 0.03, 320 + (roadEnd - 320) / 2), COLOR.hazardYellow, Enum.Material.SmoothPlastic, { shadow = false })
    end
    for z = 328, roadEnd - 4, 12 do
        part(g, "RoadDash", V3(0.6, 0.05, 5), at(0, 0.03, z), LINE_WHITE, Enum.Material.SmoothPlastic, { shadow = false })
    end
    -- Test pads: central field, armored lane, mech pad, container yard, buildings' aprons.
    part(g, "FieldPad", V3(60, 0.4, 130), at(-34, 0.0, 462), PAD, CONCRETE, SOLID)
    part(g, "LanePad", V3(34, 0.4, 150), at(50, 0.0, 468), COLOR.concreteDark, CONCRETE, SOLID)
    for z = 402, 536, 14 do
        part(g, "LaneChevron", V3(10, 0.05, 1.2), at(50, 0.25, z), COLOR.hazardYellow, Enum.Material.SmoothPlastic, { shadow = false })
    end
    part(g, "MechPad", V3(42, 0.4, 46), at(-42, 0.0, 546), COLOR.concreteDark, CONCRETE, SOLID)
    part(g, "YardPad", V3(44, 0.4, 56), at(46, 0.0, 578), PAD, CONCRETE, SOLID)
    part(g, "WarehouseApron", V3(44, 0.4, 14), at(-46, 0.0, 606), PAD, CONCRETE, SOLID)
    part(g, "BunkerApron", V3(40, 0.4, 14), at(44, 0.0, 608), PAD, CONCRETE, SOLID)
    -- Range boundary: tall protected concrete (the district cannot be left or shot away).
    for _, s in ipairs({ -1, 1 }) do
        part(g, "DistrictWall", V3(2, 14, len), at(s * (HW + 1), 7, Z0 + len / 2), COLOR.concrete, CONCRETE, SOLID)
        part(g, "DistrictWallCap", V3(2.4, 0.6, len), at(s * (HW + 1), 14.3, Z0 + len / 2), COLOR.hazardYellow, METAL)
    end
    part(g, "DistrictFarWall", V3(HW * 2 + 4, 16, 2), at(0, 8, Z1 + 1), COLOR.concrete, CONCRETE, SOLID)
    -- Reserved duel-arena gate (sealed): the logical expansion direction. Nothing is built beyond this wall.
    local gateZ = Z1 - 0.2
    for _, s in ipairs({ -1, 1 }) do
        part(g, "ArenaGatePylon", V3(5, 24, 4), at(s * 27, 12, gateZ), COLOR.gunmetal, METAL, SOLID)
        glow(g, "ArenaGateLamp", V3(0.8, 8, 0.8), at(s * 24.2, 14, gateZ - 2.1), COLOR.amber)
    end
    part(g, "ArenaGateShutter", V3(50, 18, 2), at(0, 9, gateZ), Color3.fromRGB(36, 40, 44), PLATE, SOLID)
    sign(g, "ArenaGateSign", "DUEL ARENA  -  SEALED\nRESERVED FOR FUTURE EXPANSION  >>  +Z", V3(40, 5, 0.3), at(0, 15, gateZ - 1.2), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    part(g, "ArenaGateBeam", V3(60, 3, 4), at(0, 22, gateZ), COLOR.gunmetal, METAL, SOLID)

    -- District gate plaza (the proving ground's far wall is opened along the road by ProvingGround).
    for _, s in ipairs({ -1, 1 }) do
        part(g, "DistrictGatePylon", V3(5, 30, 5), at(s * 30, 15, 322), COLOR.gunmetal, METAL, SOLID)
        part(g, "DistrictGateBase", V3(7, 1.2, 7), at(s * 30, 0.6, 322), COLOR.hazardYellow, METAL)
        glow(g, "DistrictGateLight", V3(0.5, 22, 0.5), at(s * 27.2, 15, 319.4), COLOR.amber)
    end
    part(g, "DistrictGateBeam", V3(66, 5, 4), at(0, 31, 322), COLOR.gunmetal, METAL, SOLID)
    sign(g, "DistrictGateSign", "RANGE 07  -  DESTRUCTION TESTING DISTRICT\nUNMANNED TARGETS ONLY  -  ALL PILOTS SAFE", V3(52, 4.2, 0.4), at(0, 31, 319.7), Enum.NormalId.Front, COLOR.black, COLOR.amber)
    sign(g, "DistrictGateSignReturn", "RETURN TO HANGAR BAY  <<  ROAD SOUTH", V3(40, 2.6, 0.4), at(0, 31, 324.4), Enum.NormalId.Back, COLOR.black, COLOR.hazardYellow)

    -- Range control tower (protected) with antenna and observation band.
    part(g, "RangeTower", V3(20, 28, 18), at(-48, 14, 344), COLOR.concrete, CONCRETE, SOLID)
    part(g, "RangeTowerBand", V3(20.4, 5, 18.4), at(-48, 24, 344), Color3.fromRGB(34, 44, 56), Enum.Material.Glass, { shadow = false, transparency = 0.3 })
    part(g, "RangeTowerRoof", V3(22, 1, 20), at(-48, 28.5, 344), COLOR.gunmetal, METAL)
    part(g, "RangeTowerMast", V3(0.5, 14, 0.5), at(-44, 36, 340), COLOR.gunmetal, METAL)
    glow(g, "RangeTowerBeacon", V3(1.2, 1.2, 1.2), at(-44, 43.4, 340), COLOR.red)
    sign(g, "RangeTowerSign", "RANGE CONTROL", V3(16, 3, 0.3), at(-48, 18, 334.8), Enum.NormalId.Front, COLOR.black, COLOR.amber)
    sign(g, "RangeTowerRules", "UNMANNED TARGETS ONLY\nWEAPONS FREE  -  DISTRICT ONLY\nRESET: RANGE PANEL / B", V3(16, 5, 0.3), at(-48, 10, 334.8), Enum.NormalId.Front, COLOR.black, COLOR.cool)
    -- Reset stations: a kiosk at the plaza and one at the far end of the road.
    for i, station in ipairs({ { -28, 354 }, { 26, 668 } }) do
        local sx, sz = station[1], station[2]
        part(g, "ResetStation", V3(4, 4.2, 2.6), at(sx, 2.1, sz), COLOR.gunmetal, METAL, SOLID)
        part(g, "ResetStationHood", V3(4.6, 0.5, 3.6), at(sx, 4.6, sz), COLOR.hazardYellow, METAL)
        sign(g, "ResetStationSign", "RESET STATION " .. string.char(64 + i) .. "\nB  /  RANGE PANEL", V3(7, 3, 0.3), at(sx, 7.6, sz), Enum.NormalId.Front, COLOR.black, COLOR.green)
        glow(g, "ResetStationLight", V3(1, 0.6, 1), at(sx, 5.2, sz), COLOR.green)
    end
    -- Distance boards along the road (continuing the hangar-door scale every 50 studs).
    for dist = 300, 650, 50 do
        local z = 58 + dist
        if z > 330 and z < 690 then
            for _, s in ipairs({ -1, 1 }) do
                part(g, "MarkerPost", V3(0.7, 7, 0.7), at(s * 25.5, 3.5, z), COLOR.gunmetal, METAL, SOLID)
                sign(g, "MarkerSign", string.format("%03d", dist), V3(5.2, 2.6, 0.3), at(s * 25.5, 7.6, z) * ANG(0, -s * math.pi / 2, 0), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
                glow(g, "MarkerLamp", V3(0.9, 0.5, 0.9), at(s * 25.5, 9.1, z), COLOR.amber)
            end
        end
    end
    -- Floodlight masts around the field (emissive heads, no extra light instances).
    for _, m in ipairs({ { -65.5, 396 }, { -65.5, 516 }, { -65.5, 596 }, { 65.5, 640 }, { 65.5, 600 } }) do
        part(g, "FloodMast", V3(1.2, 36, 1.2), at(m[1], 18, m[2]), COLOR.gunmetal, METAL, SOLID)
        glow(g, "FloodHead", V3(5, 1.4, 2), at(m[1], 36.5, m[2]), Color3.fromRGB(255, 240, 210))
    end
end

-- Structures ---------------------------------------------------------------------------------------------------------------------
local function entryAndCover(ctx)
    -- Entry chicane (z = 366): reinforced barriers either side of the road passage.
    for i, x in ipairs({ -44, -32, -20, 20, 32, 44 }) do
        barrier(ctx, "ENTRY_CHICANE", "Entry chicane", "Chicane" .. i, V3(11, 6, 3.6), V3(x, 0, 366 + (if i % 2 == 0 then 4 else 0)), 0, nil)
    end
    -- Tank traps: heavy structural blocks that need the Mauler (or patience).
    for i, x in ipairs({ -46, -34, -22, 22 }) do
        local at = V3(x, 0, 396)
        Destructibles.AddModule(ctx.d, {
            name = "TankTrap" .. i, group = "TANK_TRAPS", groupKind = "barrier", label = "Tank traps", material = "STRUCTURE", surface = CONCRETE,
            size = V3(5.6, 5.6, 5.6), cf = CF(ctx.origin + at + V3(0, 4.85, 0)) * ANG(0, math.rad(45), math.rad(35.264)), color = Color3.fromRGB(86, 88, 88), hp = 640,
        })
    end
    -- Defensive barricade line across the stationary-armor field.
    -- Two segments leave a 35-wide road passage in the middle; the rest of the line is cover to be shot away.
    for i, x in ipairs({ -56, -44.8, -33.6, -22.4, 22.4 }) do
        barrier(ctx, "BARRICADE_LINE", "Barricade line", "Barricade" .. i, V3(9.4, 7, 4), V3(x, 0, 410), 0, 520)
    end
end

local function armoredLane(ctx, g)
    local fences = Instance.new("Model")
    fences.Name = "LaneFencing"
    fences.Parent = ctx.d.folder
    for _, x in ipairs({ 32.5, 67 }) do
        for i = 0, 11 do
            local z0 = 398 + i * 12.2
            fenceSegment(ctx, "LANE_FENCE", "Lane fence", string.format("Fence_%d_%d", x, i), V3(x, 0, z0), V3(x, 0, z0 + 12.2), fences)
            if i == 0 then
                post(ctx, fences, V3(x, 0, z0))
            end
            post(ctx, fences, V3(x, 0, z0 + 12.2))
        end
    end
    sign(g, "LaneSign", "ARMORED VEHICLE TESTING LANE\nUNMANNED TRAINING ARMOR  -  T-03", V3(24, 4, 0.4), ctx.at(50, 11, 392), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    part(g, "LaneSignPostL", V3(0.8, 12, 0.8), ctx.at(38, 6, 392), COLOR.gunmetal, METAL, SOLID)
    part(g, "LaneSignPostR", V3(0.8, 12, 0.8), ctx.at(62, 6, 392), COLOR.gunmetal, METAL, SOLID)
end

local function mechArea(ctx, g)
    local fences = Instance.new("Model")
    fences.Name = "MechPadFencing"
    fences.Parent = ctx.d.folder
    for i = 0, 3 do
        local z0 = 526 + i * 11.5
        fenceSegment(ctx, "MECH_FENCE", "Mech pad fence", "MechFence" .. i, V3(-64.5, 0, z0), V3(-64.5, 0, z0 + 11.5), fences)
        post(ctx, fences, V3(-64.5, 0, z0))
    end
    post(ctx, fences, V3(-64.5, 0, 572))
    sign(g, "MechPadSign", "STATIONARY TRAINING MECH  M-01\nUNMANNED  -  COMPONENT DAMAGE", V3(26, 4, 0.4), ctx.at(-42, 24, 523), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
    part(g, "MechPadSignPostL", V3(0.8, 24, 0.8), ctx.at(-54, 12, 523), COLOR.gunmetal, METAL, SOLID)
    part(g, "MechPadSignPostR", V3(0.8, 24, 0.8), ctx.at(-30, 12, 523), COLOR.gunmetal, METAL, SOLID)
    part(g, "FiringLine", V3(40, 0.05, 0.8), ctx.at(-42, 0.25, 500), COLOR.hazardYellow, Enum.Material.SmoothPlastic, { shadow = false })
end

local function fuelPoint(ctx, g)
    local parent = Instance.new("Model")
    parent.Name = "FuelPoint"
    parent.Parent = ctx.d.folder
    fuelTank(ctx, "FuelTankA", V3(-56, 0, 500), parent)
    fuelTank(ctx, "FuelTankB", V3(-56, 0, 509), parent)
    fuelTank(ctx, "FuelTankC", V3(-42, 0, 504), parent)
    transformer(ctx, "TransformerA", V3(-28, 0, 512), parent)
    generator(ctx, "GeneratorA", V3(-30, 0, 498), 0, parent)
    sign(g, "FuelSign", "FUEL POINT  -  EXPLOSIVE", V3(14, 2.4, 0.3), ctx.at(-48, 7, 494), Enum.NormalId.Front, COLOR.black, COLOR.red)
    part(g, "FuelSignPost", V3(0.6, 7, 0.6), ctx.at(-48, 3.5, 494), COLOR.gunmetal, METAL, SOLID)
end

local function containerYard(ctx)
    local layout = {
        { "CTR-01", 30, 0, 566 }, { "CTR-02", 41, 0, 566 }, { "CTR-03", 52, 0, 566 }, { "CTR-04", 63, 0, 566 },
        { "CTR-05", 41, 9, 566 }, { "CTR-06", 63, 9, 566 },
        { "CTR-07", 30, 0, 590 }, { "CTR-08", 52, 0, 590 }, { "CTR-09", 63, 0, 590 },
    }
    for i, c in ipairs(layout) do
        container(ctx, c[1], V3(c[2], c[3] + 4.55, c[4]), math.rad(if i == 3 then 1.5 elseif i == 8 then -2 else 0), CONTAINER_COLORS[(i - 1) % #CONTAINER_COLORS + 1])
    end
    local parent = Instance.new("Model")
    parent.Name = "YardMachinery"
    parent.Parent = ctx.d.folder
    generator(ctx, "GeneratorB", V3(40, 0, 603), math.rad(90), parent)
    generator(ctx, "GeneratorC", V3(55, 0, 604), math.rad(-90), parent)
end

local function gantryShed(ctx, g)
    local d = ctx.d
    local parent = Instance.new("Model")
    parent.Name = "GantryShed"
    parent.Parent = d.folder
    local cols, beams = {}, {}
    local xs, zs = { -60, -30 }, { 582, 598 }
    for _, x in ipairs(xs) do
        for _, z in ipairs(zs) do
            local m = Destructibles.AddModule(d, {
                name = string.format("ShedColumn_%d_%d", x, z), group = "GANTRY_SHED", groupKind = "column", label = "Gantry shed", parent = parent,
                material = "STRUCTURE", surface = METAL, size = V3(3, 17, 3), cf = CF(ctx.origin + V3(x, 8.5, z)), color = Color3.fromRGB(150, 118, 40), hp = 620,
                decor = function(holder, body)
                    part(holder, "Base", V3(4.6, 0.8, 4.6), body.CFrame * CF(0, -8.1, 0), COLOR.gunmetal, METAL)
                    part(holder, "Capital", V3(4.2, 0.8, 4.2), body.CFrame * CF(0, 8.1, 0), COLOR.gunmetal, METAL)
                end,
            })
            cols[x .. ":" .. z] = m
        end
    end
    for _, z in ipairs(zs) do
        beams[z] = Destructibles.AddModule(d, {
            name = "ShedBeam_" .. z, group = "GANTRY_SHED", groupKind = "column", label = "Gantry shed", parent = parent,
            material = "STRUCTURE", surface = METAL, size = V3(34, 1.8, 2.6), cf = CF(ctx.origin + V3(-45, 17.9, z)), color = Color3.fromRGB(130, 104, 38), hp = 520,
            supports = { cols["-60:" .. z], cols["-30:" .. z] },
        })
    end
    for i = 0, 2 do
        for zi, z in ipairs(zs) do
            Destructibles.AddModule(d, {
                name = string.format("ShedRoof_%d_%d", i, zi), group = "GANTRY_SHED", groupKind = "roof", label = "Gantry shed", parent = parent,
                material = "PANEL", surface = CORRUGATED, size = V3(11.2, 0.8, 16), cf = CF(ctx.origin + V3(-56.4 + i * 11.2, 19.2, z)),
                color = jitter(Color3.fromRGB(110, 118, 122), 0.05), supports = { beams[z] },
            })
        end
    end
    local machinery = Instance.new("Model")
    machinery.Name = "ShedMachinery"
    machinery.Parent = d.folder
    generator(ctx, "GeneratorD", V3(-52, 0, 590), 0, machinery)
    transformer(ctx, "TransformerB", V3(-38, 0, 590), machinery)
    sign(g, "ShedSign", "SERVICE GANTRY  -  STRUCTURAL TEST", V3(18, 2.6, 0.3), ctx.at(-45, 4, 577.6), Enum.NormalId.Front, COLOR.black, COLOR.hazardYellow)
end

local function warehouse(ctx)
    local d = ctx.d
    local z0, z1, x0, x1 = 614, 654, -66, -26
    local rows = {
        { h = 5.5, material = "CONCRETE", surface = CONCRETE, color = Color3.fromRGB(104, 106, 106) },
        { h = 7, material = "PANEL", surface = CORRUGATED, color = Color3.fromRGB(116, 124, 126) },
        { h = 7, material = "PANEL", surface = GLASS, color = Color3.fromRGB(120, 156, 176), transparency = 0.42 },
    }
    local parent = Instance.new("Model")
    parent.Name = "WarehouseA"
    parent.Parent = d.folder
    local function w(group, label, a, b, gaps)
        wallGrid(ctx, { group = group, label = label, a = a, b = b, thick = 1.6, rows = rows, panelW = 8, gaps = gaps, parent = parent })
    end
    w("WH_FRONT", "Warehouse A front wall", Vector2.new(x0, z0), Vector2.new(x1, z0), { { 8, 32 } })
    w("WH_BACK", "Warehouse A rear wall", Vector2.new(x0, z1), Vector2.new(x1, z1))
    w("WH_WEST", "Warehouse A west wall", Vector2.new(x0, z0), Vector2.new(x0, z1))
    w("WH_EAST", "Warehouse A east wall", Vector2.new(x1, z0), Vector2.new(x1, z1))
    local cols, beams = {}, {}
    local cx, cz = { -56, -36 }, { 626, 642 }
    for _, x in ipairs(cx) do
        for _, z in ipairs(cz) do
            cols[x .. ":" .. z] = Destructibles.AddModule(d, {
                name = string.format("WHColumn_%d_%d", x, z), group = "WH_FRAME", groupKind = "column", label = "Warehouse A roof frame", parent = parent,
                material = "STRUCTURE", surface = CONCRETE, size = V3(3.2, 19, 3.2), cf = CF(ctx.origin + V3(x, 9.5, z)), color = Color3.fromRGB(96, 98, 100), hp = 680,
            })
        end
    end
    for _, z in ipairs(cz) do
        beams[z] = Destructibles.AddModule(d, {
            name = "WHBeam_" .. z, group = "WH_FRAME", groupKind = "column", label = "Warehouse A roof frame", parent = parent,
            material = "STRUCTURE", surface = METAL, size = V3(34, 1.8, 2.4), cf = CF(ctx.origin + V3(-46, 18.6, z)), color = Color3.fromRGB(70, 74, 80), hp = 520,
            supports = { cols["-56:" .. z], cols["-36:" .. z] },
        })
    end
    for i = 0, 3 do
        for zi, z in ipairs(cz) do
            Destructibles.AddModule(d, {
                name = string.format("WHRoof_%d_%d", i, zi), group = "WH_ROOF", groupKind = "roof", label = "Warehouse A roof", parent = parent,
                material = "PANEL", surface = CORRUGATED, size = V3(10.2, 0.8, 20), cf = CF(ctx.origin + V3(x0 + 5 + i * 10, 19.9, if zi == 1 then z0 + 10 else z1 - 10)),
                color = jitter(Color3.fromRGB(96, 104, 108), 0.05), supports = { beams[z] },
            })
        end
    end
    local machinery = Instance.new("Model")
    machinery.Name = "WarehouseContents"
    machinery.Parent = d.folder
    generator(ctx, "GeneratorE", V3(-60, 0, 646), math.rad(90), machinery)
    generator(ctx, "GeneratorF", V3(-33, 0, 648), math.rad(-90), machinery)
    transformer(ctx, "TransformerC", V3(-46, 0, 650), machinery)
    fuelTank(ctx, "FuelTankD", V3(-46, 0, 636), machinery)
end

local function bunker(ctx)
    local d = ctx.d
    local x0, x1, z0, z1 = 26, 62, 618, 646
    local rows = {
        { h = 6, material = "CONCRETE", surface = CONCRETE, color = Color3.fromRGB(96, 98, 98), hp = 480 },
        { h = 6.5, material = "CONCRETE", surface = CONCRETE, color = Color3.fromRGB(108, 110, 108), hp = 440 },
    }
    local parent = Instance.new("Model")
    parent.Name = "BunkerB"
    parent.Parent = d.folder
    local frontGrid = wallGrid(ctx, { group = "BK_FRONT", label = "Bunker B front wall", a = Vector2.new(x0, z0), b = Vector2.new(x1, z0), thick = 2.4, rows = rows, panelW = 9, gaps = { { 9, 27 } }, parent = parent })
    local backGrid = wallGrid(ctx, { group = "BK_BACK", label = "Bunker B rear wall", a = Vector2.new(x0, z1), b = Vector2.new(x1, z1), thick = 2.4, rows = rows, panelW = 9, parent = parent })
    wallGrid(ctx, { group = "BK_WEST", label = "Bunker B west wall", a = Vector2.new(x0, z0), b = Vector2.new(x0, z1), thick = 2.4, rows = rows, panelW = 9.3, parent = parent })
    wallGrid(ctx, { group = "BK_EAST", label = "Bunker B east wall", a = Vector2.new(x1, z0), b = Vector2.new(x1, z1), thick = 2.4, rows = rows, panelW = 9.3, parent = parent })
    -- Roof slabs rest on the top course of the front and rear walls: lose one and that slab comes down.
    for i = 1, 4 do
        local supports = {}
        if frontGrid[2][i] then table.insert(supports, frontGrid[2][i]) end
        if backGrid[2][i] then table.insert(supports, backGrid[2][i]) end
        Destructibles.AddModule(d, {
            name = "BunkerRoof" .. i, group = "BK_ROOF", groupKind = "roof", label = "Bunker B roof", parent = parent,
            material = "STRUCTURE", surface = CONCRETE, size = V3(8.9, 2, z1 - z0 + 3), cf = CF(ctx.origin + V3(x0 + 4.5 + (i - 1) * 9, 13.5, (z0 + z1) / 2)),
            color = Color3.fromRGB(88, 90, 92), hp = 700, supports = if #supports > 0 then supports else nil,
        })
    end
    local machinery = Instance.new("Model")
    machinery.Name = "BunkerContents"
    machinery.Parent = d.folder
    transformer(ctx, "TransformerD", V3(34, 0, 636), machinery)
    generator(ctx, "GeneratorG", V3(52, 0, 634), math.rad(90), machinery)
end

local function trainingMachines(ctx)
    local d = ctx.d
    local at = function(x, z) return ctx.origin + V3(x, 0, z) end
    TrainingTank.Create(d, { id = "T-01", cf = CF(at(-38, 438)), palette = "OLIVE", turretYaw = 24, scan = 0 })
    TrainingTank.Create(d, { id = "T-02", cf = CF(at(14, 478)), palette = "SAND", turretYaw = -18, scan = 0 })
    TrainingTank.Create(d, {
        id = "T-03", cf = CF(at(50, 404)), palette = "SLATE", scan = 0.55,
        patrol = { points = { at(50, 404), at(50, 530) }, speed = 5.5, turnRate = math.rad(24) },
    })
    TrainingMech.Create(d, { id = "M-01", position = at(-42, 548), yaw = 0 })
end

-- Entry point ------------------------------------------------------------------------------------------------------------------------
function DistrictBuilder.Build(bay: Model, origin: Vector3, parent: Instance)
    local d = Destructibles.NewDistrict(bay, origin, parent)
    local ctx = { d = d, origin = origin, at = function(x, y, z) return CF(origin + V3(x, y, z)) end }
    d.folder:SetAttribute("ExpansionDirection", DistrictBuilder.EXPANSION)
    d.folder:SetAttribute("ZoneMinZ", origin.Z + DistrictBuilder.ZONE_MIN_Z)
    d.folder:SetAttribute("ZoneMaxZ", origin.Z + DistrictBuilder.END_Z)
    d.folder:SetAttribute("ZoneHalfWidth", DistrictBuilder.HALF_WIDTH)
    d.folder:SetAttribute("SafeZoneNote", "Hangar and staging range are protected; only registered district modules take damage")
    local g = Instance.new("Model")
    g.Name = "DistrictInfrastructure"
    g.Parent = d.folder
    infrastructure(ctx, g)
    entryAndCover(ctx)
    armoredLane(ctx, g)
    mechArea(ctx, g)
    fuelPoint(ctx, g)
    containerYard(ctx)
    gantryShed(ctx, g)
    warehouse(ctx)
    bunker(ctx)
    trainingMachines(ctx)
    d.dirty = true
    return d
end

return DistrictBuilder
