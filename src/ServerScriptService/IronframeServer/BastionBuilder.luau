-- IF-42 Bastion procedural hard-surface model. Parts are authored in JOINT frames defined by
-- RigSpec (see header there). Any named part can be swapped for an imported MeshPart via
-- PartKit's ServerStorage/IronframeAssets hook without changing the rig (see ASSET_PIPELINE.md).
--
-- Material language (kept consistent on every part):
--   armor  -> SmoothPlastic "paint" in the preset's primary/secondary colours (PartKit default)
--   frame, joints, pipes, standoffs -> Metal in near-black gunmetal (reads as machinery, not paint)
--   rods, collars, fasteners -> Metal in light steel
--   glow   -> Neon, used sparingly (visor, canopy, reactor, coils, warhead tips)
-- Armor is mounted on standoffs with a visible gap over the dark frame beneath.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local WeaponModules = require(script.Parent.WeaponModules)

local Bastion = {}

local V, C, A = Vector3.new, CFrame.new, CFrame.Angles
local SIDES = { { "L", -1 }, { "R", 1 } }
local METAL = Enum.Material.Metal

-- Paint schemes per loadout; unknown IDs fall back to BALANCED. Values are deliberately mid-tone
-- so the showroom lights never clip them to white.
local PALETTES = {
    BALANCED = {
        primary = Color3.fromRGB(84, 98, 108), secondary = Color3.fromRGB(56, 68, 80),
        dark = Color3.fromRGB(34, 40, 47), ring = Color3.fromRGB(70, 78, 86), steel = Color3.fromRGB(112, 120, 128),
        accent = Color3.fromRGB(226, 150, 48), glow = Color3.fromRGB(255, 160, 60), beam = Color3.fromRGB(80, 210, 235),
        visor = Color3.fromRGB(80, 210, 235),
    },
    ENERGY = {
        primary = Color3.fromRGB(110, 126, 138), secondary = Color3.fromRGB(30, 66, 82),
        dark = Color3.fromRGB(28, 38, 46), ring = Color3.fromRGB(62, 76, 86), steel = Color3.fromRGB(104, 118, 128),
        accent = Color3.fromRGB(50, 205, 235), glow = Color3.fromRGB(60, 215, 245), beam = Color3.fromRGB(70, 220, 245),
        visor = Color3.fromRGB(100, 240, 215),
    },
    MISSILE = {
        primary = Color3.fromRGB(96, 104, 66), secondary = Color3.fromRGB(62, 68, 48),
        dark = Color3.fromRGB(34, 36, 29), ring = Color3.fromRGB(70, 72, 62), steel = Color3.fromRGB(110, 110, 98),
        accent = Color3.fromRGB(240, 124, 28), glow = Color3.fromRGB(255, 104, 36), beam = Color3.fromRGB(255, 140, 56),
        visor = Color3.fromRGB(255, 130, 44),
    },
}

function Bastion.Palette(presetId)
    return PALETTES[presetId] or PALETTES.BALANCED
end

-- ---------------------------------------------------------------------------------------------
-- Detail helpers
-- ---------------------------------------------------------------------------------------------

-- Armor plate floating off the frame on two diagonal standoffs. `inner` names the plate face that
-- looks at the frame: "z+" (front plates), "z-" (rear plates), "x+"/"x-" (side plates), "y-" (hanging).
local function plate(kit, p, name, joint, size, cf, color, inner)
    local part = kit:box(name, joint, size, cf, color, "armor")
    if inner then
        local axis, sign = string.sub(inner, 1, 1), if string.sub(inner, 2, 2) == "+" then 1 else -1
        local half = (if axis == "x" then size.X elseif axis == "y" then size.Y else size.Z) / 2 + 0.1
        for i, k in ipairs({ 1, -1 }) do
            local pos
            if axis == "z" then
                pos = V(size.X * 0.3 * k, size.Y * 0.3 * k, sign * half)
            elseif axis == "x" then
                pos = V(sign * half, size.Y * 0.3 * k, size.Z * 0.3 * k)
            else
                pos = V(size.X * 0.3 * k, sign * half, size.Z * 0.3 * k)
            end
            kit:box(name .. "_Standoff" .. i, joint, V(0.3, 0.3, 0.3), cf * C(pos), p.dark, "frame", METAL)
        end
    end
    return part
end

-- A row of fasteners (bolt heads) along local X or Y of `cf`, facing -Z.
local function bolts(kit, p, name, joint, cf, count, spacing, along)
    for i = 1, count do
        local offset = (i - (count + 1) / 2) * spacing
        local placed = if along == "y" then C(0, offset, 0) else C(offset, 0, 0)
        kit:cylZ(name .. i, joint, 0.14, 0.24, cf * placed, p.steel, "detail", METAL)
    end
end

-- Stack of thin louvre slats (vents). Slats step along local Y of `cf`.
local function vents(kit, p, name, joint, cf, count, step, slat, color)
    for i = 1, count do
        kit:box(name .. i, joint, slat, cf * C(0, (i - (count + 1) / 2) * step, 0), color or p.dark, "detail", METAL)
    end
end

-- Weapon hard-point structure, built for every socket (even empty ones) in the socket frame, so
-- weapons always seat into a real mount. Weapons grow along -Z from this frame.
local function socketMount(kit, p, socketName)
    local socket = RigSpec.Sockets[socketName]
    local frame = RigSpec.SocketLocalCF(socketName)
    local j = socket.joint
    local function nm(part) return "Mount_" .. socketName .. "_" .. part end
    if string.find(socketName, "arm") then
        kit:cylZ(nm("Sleeve"), j, 1.0, 2.0, frame * C(0, 0, 0.2), p.dark, "frame", METAL)
        kit:cylZ(nm("Ring"), j, 0.3, 2.3, frame * C(0, 0, -0.35), p.ring, "joint", METAL)
        for i = 0, 3 do
            local a = i * math.pi / 2 + math.pi / 4
            kit:cylZ(nm("Bolt" .. i), j, 0.16, 0.28, frame * C(math.cos(a) * 0.98, math.sin(a) * 0.98, -0.55), p.accent, "detail", METAL)
        end
    elseif string.find(socketName, "shoulder") then
        kit:box(nm("Cradle"), j, V(2.7, 0.45, 2.6), frame * C(0, -1.0, -0.6), p.dark, "frame", METAL)
        for _, s in ipairs({ -1, 1 }) do
            kit:box(nm("Strut" .. (s < 0 and "L" or "R")), j, V(0.3, 1.5, 2.2), frame * C(s * 1.28, -0.4, -0.5), p.secondary, "armor")
        end
        kit:box(nm("RearStop"), j, V(2.7, 1.9, 0.35), frame * C(0, 0, 1.15), p.dark, "frame", METAL)
    else
        kit:cylZ(nm("Collar"), j, 0.7, 1.45, frame * C(0, 0, 0.25), p.dark, "frame", METAL)
        kit:cylZ(nm("Ring"), j, 0.26, 1.7, frame * C(0, 0, -0.2), p.ring, "joint", METAL)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Regions
-- ---------------------------------------------------------------------------------------------

local function buildHip(kit, p)
    kit:box("PelvisCore", "Hip", V(5.0, 2.0, 3.6), C(0, 0, 0), p.dark, "frame", METAL)
    kit:box("PelvisSpine", "Hip", V(2.2, 1.4, 3.9), C(0, 0.5, 0), p.secondary, "frame", METAL)
    plate(kit, p, "PelvisFrontPlate", "Hip", V(4.2, 1.5, 0.5), C(0, -0.5, -2.2) * A(-0.22, 0, 0), p.primary, "z+")
    kit:box("PelvisFrontTrim", "Hip", V(3.4, 0.12, 0.2), C(0, -1.18, -2.5), p.accent, "armor")
    plate(kit, p, "PelvisRearPlate", "Hip", V(4.2, 1.5, 0.5), C(0, -0.4, 2.2) * A(0.2, 0, 0), p.secondary, "z-")
    bolts(kit, p, "PelvisBolt", "Hip", C(0, 0.1, -2.5), 5, 0.75, "x")
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:cylX("HipCollar" .. t, "Hip", 3.0, 2.3, C(s * 2.5, -0.5, 0), p.dark, "joint", METAL)
        kit:cylX("HipRing" .. t, "Hip", 0.3, 2.7, C(s * 3.9, -0.5, 0), p.ring, "joint", METAL)
        kit:cylX("HipRingInner" .. t, "Hip", 0.3, 2.7, C(s * 1.1, -0.5, 0), p.ring, "joint", METAL)
        -- three overlapping hip lames with air between them
        for i = 0, 2 do
            plate(kit, p, "HipLame" .. t .. i, "Hip", V(3.0 - i * 0.2, 0.32, 3.4 - i * 0.3),
                C(s * (2.9 + i * 0.12), 1.05 - i * 0.42, 0) * A(0, 0, -s * (0.2 + i * 0.1)), if i == 1 then p.secondary else p.primary, nil)
        end
        kit:box("HipLameSpine" .. t, "Hip", V(0.3, 1.5, 0.4), C(s * 2.2, 0.35, 1.4), p.dark, "frame", METAL)
        kit:box("HipLameSpineF" .. t, "Hip", V(0.3, 1.5, 0.4), C(s * 2.2, 0.35, -1.4), p.dark, "frame", METAL)
    end
end

local function buildTorso(kit, p, ctx)
    kit:cylY("WaistRing", "Torso", 1.1, 4.4, C(0, -0.35, 0), p.dark, "joint", METAL)
    for i = 0, 3 do
        local a = i * math.pi / 2
        kit:cylY("WaistRib" .. i, "Torso", 1.0, 0.35, C(math.cos(a) * 2.25, -0.35, math.sin(a) * 2.25), p.steel, "detail", METAL)
    end
    kit:box("Abdomen", "Torso", V(4.6, 1.5, 3.6), C(0, 0.55, 0), p.dark, "frame", METAL)
    kit:box("AbdomenHazard", "Torso", V(3.8, 0.35, 0.1), C(0, 0.55, -1.85), p.accent, "armor")
    kit:box("ChestFrame", "Torso", V(6.0, 3.8, 4.2), C(0, 3.1, 0), p.dark, "frame", METAL)
    kit:box("ChestSpine", "Torso", V(3.0, 4.2, 4.5), C(0, 3.1, 0.1), p.secondary, "frame", METAL)

    -- Front armor: lower plate + intakes, flanking wings, central prow ridge. All off the frame.
    plate(kit, p, "ChestLowerPlate", "Torso", V(5.4, 2.0, 0.55), C(0, 2.0, -2.5) * A(0.18, 0, 0), p.primary, "z+")
    kit:box("ChestLowerTrim", "Torso", V(5.0, 0.12, 0.2), C(0, 0.9, -2.6), p.accent, "armor")
    plate(kit, p, "ChestProw", "Torso", V(1.3, 2.3, 0.7), C(0, 2.0, -2.95) * A(0.18, 0, 0), p.secondary, "z+")
    bolts(kit, p, "ChestBolt", "Torso", C(0, 1.15, -2.8), 5, 1.0, "x")
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        vents(kit, p, "ChestIntake" .. t, "Torso", C(s * 1.9, 2.0, -2.82) * A(0.18, 0, 0), 4, 0.36, V(1.1, 0.14, 0.12))
        plate(kit, p, "ChestWing" .. t, "Torso", V(1.9, 1.7, 0.6), C(s * 2.15, 3.95, -2.65) * A(0.12, s * -0.28, 0), p.primary, "z+")
        plate(kit, p, "ChestWingLayer" .. t, "Torso", V(1.3, 1.0, 0.25), C(s * 2.3, 3.95, -3.08) * A(0.12, s * -0.28, 0), p.secondary, nil)
        kit:box("CockpitPillar" .. t, "Torso", V(0.28, 1.7, 0.6), C(s * 1.5, 4.0, -2.55), p.steel, "armor", METAL)
        kit:box("FlankBracket" .. t, "Torso", V(1.3, 1.3, 1.2), C(s * 2.9, 1.9, -2.2), p.dark, "frame", METAL)
        -- side flank vents and rib plates
        vents(kit, p, "FlankVent" .. t, "Torso", C(s * 3.08, 3.2, 0.4), 5, 0.4, V(0.1, 0.18, 2.0))
        plate(kit, p, "FlankPlate" .. t, "Torso", V(0.4, 3.0, 3.4), C(s * 3.5, 3.1, 0.2), p.secondary, if s > 0 then "x-" else "x+")
    end

    -- Recessed cockpit: dark well, seat headrest visible through the canopy, bezel, brow hood.
    kit:box("CockpitWell", "Torso", V(2.7, 1.6, 0.55), C(0, 4.0, -2.2), p.dark, "frame", METAL)
    kit:box("CockpitHeadrest", "Torso", V(0.9, 0.9, 0.35), C(0, 4.0, -2.0), p.secondary, "frame")
    local glass = kit:glow("CockpitCanopy", "Torso", V(2.4, 1.2, 0.1), C(0, 4.0, -2.5) * A(0.12, 0, 0), p.visor, "glow")
    glass.Transparency = 0.5
    kit:box("CockpitSill", "Torso", V(3.0, 0.25, 0.7), C(0, 3.2, -2.6), p.steel, "armor", METAL)
    kit:box("CockpitHood", "Torso", V(3.3, 0.38, 1.1), C(0, 4.95, -2.55) * A(-0.25, 0, 0), p.secondary, "armor")
    for _, side in ipairs(SIDES) do
        kit:glow("CockpitLamp" .. side[1], "Torso", V(0.18, 0.18, 0.12), C(side[2] * 1.7, 4.55, -2.9), p.accent, "glow")
    end
    kit:box("ChestDeck", "Torso", V(5.0, 0.4, 3.4), C(0, 5.15, 0.2), p.primary, "armor")
    vents(kit, p, "DeckVent", "Torso", C(0, 5.4, 0.9), 4, 0.4, V(2.6, 0.1, 0.18))

    -- Reactor backpack: mount plate, ribbed housing, radial heat fins, coolant pipework.
    kit:box("ReactorMount", "Torso", V(4.4, 3.2, 0.4), C(0, 3.2, 2.3), p.dark, "frame", METAL)
    kit:cylZ("ReactorHousing", "Torso", 1.8, 3.2, C(0, 3.2, 3.3), p.secondary, "reactor", METAL)
    kit:cylZ("ReactorBandA", "Torso", 0.28, 3.55, C(0, 3.2, 2.7), p.accent, "reactor", METAL)
    kit:cylZ("ReactorBandB", "Torso", 0.28, 3.55, C(0, 3.2, 3.9), p.accent, "reactor", METAL)
    kit:cylZ("ReactorCap", "Torso", 0.2, 2.7, C(0, 3.2, 4.25), p.steel, "reactor", METAL)
    for i = 0, 7 do
        local a = i * math.pi / 4
        kit:box("ReactorGrille" .. i, "Torso", V(0.16, 0.5, 0.2), C(math.cos(a) * 1.15, 3.2 + math.sin(a) * 1.15, 4.42) * A(0, 0, a), p.dark, "detail", METAL)
    end
    local core = kit:glowCylZ("ReactorCore", "Torso", 0.28, 1.5, C(0, 3.2, 4.45), p.glow)
    local light = Instance.new("PointLight")
    light.Color = p.glow
    light.Range = 14
    light.Brightness = 0.9
    light.Parent = core
    for i = 0, 6 do
        kit:box("CoolingFin" .. i, "Torso", V(0.16, 1.7, 1.4), C(-2.1 + i * 0.7, 1.15, 2.7), p.steel, "reactor", METAL)
    end
    kit:cylX("CoolantManifold", "Torso", 4.6, 0.4, C(0, 5.0, 2.3), p.dark, "detail", METAL)
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:cylY("CoolantDrop" .. t, "Torso", 1.4, 0.34, C(s * 1.5, 4.2, 2.3), p.dark, "detail", METAL)
        -- exhaust stack: base, ribbed barrel, heat shield, grille cap
        kit:box("ExhaustBase" .. t, "Torso", V(1.5, 0.8, 1.5), C(s * 2.3, 4.6, 2.9), p.dark, "reactor", METAL)
        kit:cylY("ExhaustStack" .. t, "Torso", 2.6, 0.95, C(s * 2.3, 6.0, 2.9), p.secondary, "reactor", METAL)
        for i = 0, 2 do
            kit:cylY("ExhaustRib" .. t .. i, "Torso", 0.18, 1.18, C(s * 2.3, 5.0 + i * 0.85, 2.9), p.steel, "reactor", METAL)
        end
        kit:box("ExhaustShield" .. t, "Torso", V(0.16, 2.0, 1.3), C(s * 2.95, 5.9, 2.9), p.primary, "armor")
        kit:cylY("ExhaustRim" .. t, "Torso", 0.25, 1.25, C(s * 2.3, 7.3, 2.9), p.accent, "reactor", METAL)
        kit:cylY("ExhaustGlow" .. t, "Torso", 0.1, 0.7, C(s * 2.3, 7.4, 2.9), p.glow, "glow", Enum.Material.Neon)

        -- Pauldron assembly: base, two floating shells, front/rear guards, hanging lames, pylon.
        kit:box("PauldronBase" .. t, "Torso", V(4.0, 0.9, 4.8), C(s * 5.2, 5.2, 0.1), p.dark, "frame", METAL)
        plate(kit, p, "PauldronShell" .. t, "Torso", V(3.8, 0.8, 5.0), C(s * 5.3, 5.95, 0.1) * A(0, 0, -s * 0.2), p.primary, "y-")
        plate(kit, p, "PauldronCap" .. t, "Torso", V(2.8, 0.45, 3.4), C(s * 5.3, 6.75, 0.0) * A(0, 0, -s * 0.2), p.secondary, "y-")
        plate(kit, p, "PauldronFront" .. t, "Torso", V(3.6, 1.4, 0.5), C(s * 5.2, 5.3, -2.75) * A(0.25, 0, 0), p.secondary, "z+")
        plate(kit, p, "PauldronRear" .. t, "Torso", V(3.6, 1.1, 0.5), C(s * 5.2, 5.3, 2.75), p.secondary, "z-")
        kit:box("PauldronStripe" .. t, "Torso", V(3.2, 0.1, 1.2), C(s * 5.3, 6.4, -1.3) * A(0, 0, -s * 0.2), p.accent, "armor")
        bolts(kit, p, "PauldronBolt" .. t, "Torso", C(s * 5.2, 5.3, -3.05), 3, 1.1, "x")
        for i = 0, 2 do
            plate(kit, p, "ShoulderLame" .. t .. i, "Torso", V(0.4, 0.95, 3.6 - i * 0.2),
                C(s * (7.2 + i * 0.12), 4.5 - i * 0.85, 0.1) * A(0, 0, s * 0.12), if i == 1 then p.secondary else p.primary, nil)
        end
        kit:box("ShoulderLameRail" .. t, "Torso", V(0.3, 2.6, 0.35), C(s * 6.85, 3.5, 2.0), p.dark, "frame", METAL)
        kit:cylY("PodPylon" .. t, "Torso", 1.0, 0.95, C(s * 5.1, 6.9, 0.9), p.dark, "frame", METAL)
    end
    if ctx.reinforced then
        kit:box("ReinforcedChestPlate", "Torso", V(5.0, 1.6, 0.4), C(0, 2.2, -3.55) * A(0.18, 0, 0), p.steel, "armor")
        for _, side in ipairs(SIDES) do
            kit:box("ReinforcedPauldron" .. side[1], "Torso", V(2.4, 0.4, 3.6), C(side[2] * 5.3, 7.1, 0.1) * A(0, 0, -side[2] * 0.2), p.steel, "armor")
        end
    end
end

local function buildHead(kit, p)
    kit:cylY("Neck", "Head", 1.0, 1.8, C(0, -0.7, 0), p.dark, "joint", METAL)
    kit:cylY("NeckRing", "Head", 0.2, 2.3, C(0, -0.25, 0), p.ring, "joint", METAL)
    kit:box("HeadBlock", "Head", V(2.6, 1.6, 2.8), C(0, 0.2, 0), p.secondary, "frame", METAL)
    plate(kit, p, "HeadCrown", "Head", V(2.8, 0.4, 3.0), C(0, 1.25, 0.1) * A(0.1, 0, 0), p.primary, "y-")
    kit:box("HeadCrest", "Head", V(0.45, 0.45, 2.2), C(0, 1.65, 0.2) * A(0.1, 0, 0), p.accent, "armor")
    plate(kit, p, "HeadChin", "Head", V(2.0, 0.5, 0.9), C(0, -0.45, -1.4) * A(-0.3, 0, 0), p.primary, "z+")
    kit:glow("SensorVisor", "Head", V(2.2, 0.32, 0.15), C(0, 0.3, -1.45), p.visor, "glow")
    kit:box("VisorHood", "Head", V(2.6, 0.3, 0.6), C(0, 0.62, -1.5) * A(-0.3, 0, 0), p.dark, "armor", METAL)
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:cylZ("SensorLens" .. t, "Head", 0.25, 0.55, C(s * 0.85, -0.15, -1.45), p.dark, "joint", METAL)
        plate(kit, p, "HeadCheek" .. t, "Head", V(0.35, 1.2, 2.0), C(s * 1.6, 0.1, 0.2), p.primary, if s > 0 then "x-" else "x+")
        kit:cylX("SensorPod" .. t, "Head", 0.5, 0.7, C(s * 2.05, 0.3, -0.6), p.dark, "detail", METAL)
        kit:glow("SensorPodLens" .. t, "Head", V(0.1, 0.35, 0.35), C(s * 2.35, 0.3, -0.6), p.visor, "glow")
    end
    kit:cylY("Antenna", "Head", 2.2, 0.12, C(0.9, 2.1, 0.9), p.steel, "detail", METAL)
    kit:cylY("AntennaB", "Head", 1.4, 0.1, C(-1.0, 1.8, 1.0), p.steel, "detail", METAL)
end

local function buildArm(kit, p, side)
    local s, t = side[2], side[1]
    local sh, el = "Shoulder" .. t, "Elbow" .. t
    kit:cylX("ShoulderBall" .. t, sh, 3.0, 2.6, C(0, 0, 0), p.dark, "joint", METAL)
    kit:cylX("ShoulderRing" .. t, sh, 0.3, 2.9, C(s * 1.7, 0, 0), p.ring, "joint", METAL)
    kit:cylX("ShoulderRingIn" .. t, sh, 0.3, 2.9, C(s * -1.7, 0, 0), p.ring, "joint", METAL)
    kit:box("UpperArmFrame" .. t, sh, V(2.0, 3.0, 2.2), C(0, -1.9, 0), p.dark, "frame", METAL)
    plate(kit, p, "UpperArmShell" .. t, sh, V(2.6, 2.4, 0.5), C(0, -1.7, -1.6), p.primary, "z+")
    plate(kit, p, "UpperArmRear" .. t, sh, V(2.4, 2.0, 0.4), C(0, -1.7, 1.5), p.secondary, "z-")
    plate(kit, p, "UpperArmShield" .. t, sh, V(0.45, 3.0, 3.4), C(s * 1.75, -1.5, 0.1), p.secondary, if s > 0 then "x-" else "x+")
    kit:box("UpperArmStripe" .. t, sh, V(0.1, 0.35, 3.0), C(s * 2.0, -0.5, 0.1), p.accent, "armor")
    bolts(kit, p, "UpperArmBolt" .. t, sh, C(0, -2.4, -1.9), 3, 0.7, "x")

    kit:cylX("ElbowBall" .. t, el, 2.8, 1.9, C(0, 0, 0), p.dark, "joint", METAL)
    kit:cylX("ElbowRing" .. t, el, 0.25, 2.2, C(s * 1.5, 0, 0), p.ring, "joint", METAL)
    kit:cylX("ElbowRingIn" .. t, el, 0.25, 2.2, C(s * -1.5, 0, 0), p.ring, "joint", METAL)
    kit:box("ForearmFrame" .. t, el, V(2.0, 2.8, 2.4), C(0, -1.7, 0), p.dark, "frame", METAL)
    plate(kit, p, "ForearmShell" .. t, el, V(2.5, 2.0, 0.45), C(0, -1.5, 1.55) * A(-0.08, 0, 0), p.primary, "z-")
    plate(kit, p, "ForearmLayer" .. t, el, V(2.1, 1.3, 0.35), C(0, -1.3, -1.7), p.secondary, "z+")
    plate(kit, p, "ForearmSide" .. t, el, V(0.35, 2.0, 2.2), C(s * 1.45, -1.6, 0), p.secondary, if s > 0 then "x-" else "x+")
    kit:box("Gauntlet" .. t, el, V(2.6, 1.3, 2.8), C(0, -3.2, 0), p.dark, "frame", METAL)
    kit:box("GauntletCap" .. t, el, V(2.7, 0.3, 2.9), C(0, -2.6, 0), p.accent, "armor")
end

local function buildLeg(kit, p, side, ctx)
    local s, t = side[2], side[1]
    local th, kn, an = "Thigh" .. t, "Knee" .. t, "Ankle" .. t
    -- Upper leg: frame cage + front / side plates with gaps.
    kit:box("ThighFrame" .. t, th, V(2.1, 3.2, 2.2), C(0, -1.9, 0), p.dark, "frame", METAL)
    plate(kit, p, "ThighFront" .. t, th, V(2.6, 2.9, 0.5), C(0, -1.8, -1.55) * A(0.1, 0, 0), p.primary, "z+")
    plate(kit, p, "ThighSide" .. t, th, V(0.45, 2.7, 2.6), C(s * 1.55, -1.7, 0), p.secondary, if s > 0 then "x-" else "x+")
    plate(kit, p, "ThighInner" .. t, th, V(0.35, 2.2, 2.0), C(s * -1.4, -1.8, 0), p.secondary, if s > 0 then "x+" else "x-")
    kit:box("ThighStripe" .. t, th, V(0.1, 0.3, 2.4), C(s * 1.82, -0.7, 0), p.accent, "armor")
    bolts(kit, p, "ThighBolt" .. t, th, C(0, -3.0, -1.85), 3, 0.8, "x")

    -- Knee: exposed collar + two-layer kneepad.
    kit:cylX("KneeJoint" .. t, kn, 3.2, 1.9, C(0, 0, 0), p.dark, "joint", METAL)
    kit:cylX("KneeRing" .. t, kn, 0.3, 2.3, C(s * 1.8, 0, 0), p.ring, "joint", METAL)
    kit:cylX("KneeRingIn" .. t, kn, 0.3, 2.3, C(s * -1.8, 0, 0), p.ring, "joint", METAL)
    plate(kit, p, "KneePad" .. t, kn, V(2.4, 1.6, 0.9), C(0, 0.1, -1.5) * A(-0.2, 0, 0), p.primary, "z+")
    kit:box("KneePadLayer" .. t, kn, V(1.8, 1.0, 0.4), C(0, 0.1, -2.1) * A(-0.2, 0, 0), p.secondary, "armor")
    kit:box("KneePadTrim" .. t, kn, V(2.0, 0.14, 0.2), C(0, 0.95, -2.0), p.accent, "armor")

    -- Lower leg: greave, side plates, rear calf pod with vent.
    kit:box("ShinFrame" .. t, kn, V(1.9, 3.2, 2.0), C(0, -1.9, 0), p.dark, "frame", METAL)
    plate(kit, p, "ShinFront" .. t, kn, V(2.6, 3.0, 0.55), C(0, -1.9, -1.45) * A(-0.12, 0, 0), p.primary, "z+")
    plate(kit, p, "ShinSide" .. t, kn, V(0.4, 2.4, 2.2), C(s * 1.5, -1.9, 0.1), p.secondary, if s > 0 then "x-" else "x+")
    kit:box("CalfPod" .. t, kn, V(2.2, 2.2, 1.3), C(0, -1.4, 1.4), p.secondary, "armor")
    vents(kit, p, "CalfVent" .. t, kn, C(0, -1.4, 2.08), 4, 0.36, V(1.5, 0.12, 0.1))
    bolts(kit, p, "ShinBolt" .. t, kn, C(0, -3.2, -1.78), 3, 0.8, "x")

    -- Ankle + foot.
    kit:cylX("AnkleJoint" .. t, an, 2.8, 1.3, C(0, 0, 0), p.dark, "joint", METAL)
    kit:cylX("AnkleRing" .. t, an, 0.25, 1.8, C(s * 1.45, 0, 0), p.ring, "joint", METAL)
    kit:cylX("AnkleRingIn" .. t, an, 0.25, 1.8, C(s * -1.45, 0, 0), p.ring, "joint", METAL)
    kit:box("FootBase" .. t, an, V(3.0, 0.9, 4.0), C(0, -0.25, -0.9), p.dark, "frame", Enum.Material.DiamondPlate)
    plate(kit, p, "FootArmor" .. t, an, V(2.7, 0.35, 2.6), C(0, 0.35, -1.1) * A(0.06, 0, 0), p.primary, "y-")
    plate(kit, p, "AnkleGuard" .. t, an, V(0.4, 1.2, 1.8), C(s * 1.65, 0.2, -0.3), p.secondary, if s > 0 then "x-" else "x+")
    kit:box("ToePlate" .. t, an, V(2.8, 0.5, 1.3), C(0, -0.2, -3.0) * A(0.15, 0, 0), p.secondary, "armor")
    kit:box("ToeSplitL" .. t, an, V(0.15, 0.55, 1.35), C(-0.7, -0.2, -3.05) * A(0.15, 0, 0), p.dark, "detail", METAL)
    kit:box("ToeSplitR" .. t, an, V(0.15, 0.55, 1.35), C(0.7, -0.2, -3.05) * A(0.15, 0, 0), p.dark, "detail", METAL)
    kit:box("HeelBlock" .. t, an, V(2.4, 0.9, 1.2), C(0, -0.3, 1.3), p.secondary, "armor")
    if ctx.variant == "ENERGY" then
        kit:glow("ShinGlow" .. t, kn, V(0.1, 2.2, 0.15), C(s * 1.05, -1.9, -1.8), p.beam, "glow")
    end
end

local function buildVariantExtras(kit, p, ctx)
    if ctx.variant == "ENERGY" then
        for _, side in ipairs(SIDES) do
            local s, t = side[2], side[1]
            kit:cylY("CapacitorSpire" .. t, "Torso", 2.8, 0.7, C(s * 0.95, 6.5, 3.0), p.dark, "reactor", METAL)
            for i = 0, 2 do
                kit:cylY("SpireCoil" .. t .. i, "Torso", 0.16, 1.0, C(s * 0.95, 5.6 + i * 0.8, 3.0), p.beam, "glow", Enum.Material.Neon)
            end
            kit:glow("PauldronCoil" .. t, "Torso", V(0.12, 0.5, 3.4), C(s * 7.55, 3.7, 0.1), p.beam, "glow")
        end
    elseif ctx.variant == "MISSILE" then
        for _, side in ipairs(SIDES) do
            local s, t = side[2], side[1]
            kit:box("AmmoBin" .. t, "Torso", V(1.8, 2.6, 1.8), C(s * 2.9, 2.0, 3.0), p.secondary, "armor")
            kit:box("AmmoBinStripe" .. t, "Torso", V(1.6, 0.25, 0.1), C(s * 2.9, 2.9, 3.95), p.accent, "armor")
            kit:box("AmmoBinStripeB" .. t, "Torso", V(1.6, 0.25, 0.1), C(s * 2.9, 1.9, 3.95), p.accent, "armor")
            plate(kit, p, "PauldronSkirt" .. t, "Torso", V(0.5, 2.0, 4.0), C(s * 8.0, 5.0, 0.1), p.primary, if s > 0 then "x-" else "x+")
        end
        kit:cylZ("TargetingDish", "Head", 0.3, 0.9, C(-1.6, 0.9, -0.4), p.steel, "joint", METAL)
        kit:box("BrowGuard", "Head", V(3.0, 0.3, 1.0), C(0, 0.85, -1.6) * A(0.35, 0, 0), p.primary, "armor")
    else
        kit:box("CommMast", "Torso", V(0.15, 2.2, 0.15), C(-1.5, 6.5, 2.4), p.steel, "detail", METAL)
        for _, side in ipairs(SIDES) do
            kit:box("ShoulderMarker" .. side[1], "Torso", V(1.0, 0.1, 1.0), C(side[2] * 5.3, 7.0, 1.9) * A(0, 0, -side[2] * 0.2), p.accent, "armor")
        end
    end
end

-- ctx: { presetId, variant, reinforced, loadout }
function Bastion.Build(kit, ctx)
    local p = Bastion.Palette(ctx.presetId)

    -- Invisible root so the model has a stable PrimaryPart.
    local root = kit:box("RigRoot", "Root", V(1, 1, 1), CFrame.identity, p.dark, "frame")
    root.Transparency = 1

    buildHip(kit, p)
    buildTorso(kit, p, ctx)
    buildHead(kit, p)
    for _, side in ipairs(SIDES) do
        buildArm(kit, p, side)
        buildLeg(kit, p, side, ctx)
    end
    buildVariantExtras(kit, p, ctx)
    kit:addLinks(p.dark, p.steel)

    for _, socketName in ipairs(RigSpec.SocketOrder) do
        socketMount(kit, p, socketName)
    end
    for socketName, weaponId in pairs(ctx.loadout.mounts) do
        local socket = RigSpec.Sockets[socketName]
        if socket then
            WeaponModules.Build(kit, weaponId, socketName, socket.joint, RigSpec.SocketLocalCF(socketName), p)
        end
    end
end

return Bastion
