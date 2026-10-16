-- IF-42 Bastion procedural hard-surface blockout. Parts are authored in JOINT frames defined by
-- RigSpec (see header there). This is a blockout: swap any named part for an imported mesh via
-- PartKit's ServerStorage/IronframeAssets hook without changing the rig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local WeaponModules = require(script.Parent.WeaponModules)

local Bastion = {}

local V, C, A = Vector3.new, CFrame.new, CFrame.Angles
local SIDES = { { "L", -1 }, { "R", 1 } }

-- Paint schemes per loadout; unknown IDs fall back to BALANCED.
local PALETTES = {
    BALANCED = {
        primary = Color3.fromRGB(128, 144, 156), secondary = Color3.fromRGB(84, 98, 112),
        dark = Color3.fromRGB(46, 54, 63), steel = Color3.fromRGB(158, 168, 176),
        accent = Color3.fromRGB(240, 166, 60), glow = Color3.fromRGB(255, 176, 70), beam = Color3.fromRGB(90, 222, 240),
        visor = Color3.fromRGB(90, 222, 240),
    },
    ENERGY = {
        primary = Color3.fromRGB(212, 222, 230), secondary = Color3.fromRGB(38, 88, 108),
        dark = Color3.fromRGB(38, 50, 60), steel = Color3.fromRGB(170, 190, 200),
        accent = Color3.fromRGB(60, 225, 255), glow = Color3.fromRGB(70, 230, 255), beam = Color3.fromRGB(80, 235, 255),
        visor = Color3.fromRGB(110, 255, 230),
    },
    MISSILE = {
        primary = Color3.fromRGB(124, 134, 84), secondary = Color3.fromRGB(78, 86, 58),
        dark = Color3.fromRGB(44, 48, 38), steel = Color3.fromRGB(150, 150, 130),
        accent = Color3.fromRGB(255, 136, 30), glow = Color3.fromRGB(255, 110, 40), beam = Color3.fromRGB(255, 150, 60),
        visor = Color3.fromRGB(255, 140, 50),
    },
}

function Bastion.Palette(presetId)
    return PALETTES[presetId] or PALETTES.BALANCED
end


local function buildHip(kit, p)
    kit:box("PelvisCore", "Hip", V(5.0, 2.0, 3.6), C(0, 0, 0), p.dark, "frame")
    kit:box("PelvisFrontPlate", "Hip", V(4.2, 1.5, 0.5), C(0, -0.45, -2.0) * A(-0.22, 0, 0), p.primary, "armor")
    kit:box("PelvisFrontTrim", "Hip", V(3.4, 0.12, 0.2), C(0, -1.05, -2.3), p.accent, "armor")
    kit:box("PelvisRearPlate", "Hip", V(4.2, 1.5, 0.5), C(0, -0.4, 2.0) * A(0.2, 0, 0), p.secondary, "armor")
    for _, side in ipairs(SIDES) do
        local s = side[2]
        local t = side[1]
        kit:cylX("HipCollar" .. t, "Hip", 3.0, 2.3, C(s * 2.5, -0.5, 0), p.dark, "joint")
        kit:cylX("HipCap" .. t, "Hip", 0.3, 2.6, C(s * 4.0, -0.5, 0), p.steel, "joint")
        kit:box("HipGuard" .. t, "Hip", V(3.4, 0.6, 3.4), C(s * 2.6, 0.95, 0) * A(0, 0, -s * 0.2), p.primary, "armor")
        kit:box("HipGuardLayer" .. t, "Hip", V(2.4, 0.3, 2.4), C(s * 2.8, 1.35, -0.1) * A(0, 0, -s * 0.2), p.secondary, "armor")
    end
end

local function buildTorso(kit, p, ctx)
    kit:cylY("WaistRing", "Torso", 1.1, 4.4, C(0, -0.35, 0), p.dark, "joint")
    kit:box("Abdomen", "Torso", V(4.6, 1.5, 3.6), C(0, 0.55, 0), p.dark, "frame")
    kit:box("ChestFrame", "Torso", V(6.0, 3.8, 4.2), C(0, 3.1, 0), p.dark, "frame")

    -- Layered front armor: lower plate, flanking wings, cockpit hood.
    kit:box("ChestLowerPlate", "Torso", V(5.4, 2.0, 0.55), C(0, 2.1, -2.35) * A(0.18, 0, 0), p.primary, "armor")
    kit:box("ChestLowerTrim", "Torso", V(5.0, 0.14, 0.2), C(0, 1.05, -2.5), p.accent, "armor")
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:box("ChestWing" .. t, "Torso", V(1.9, 1.7, 0.6), C(s * 2.15, 3.95, -2.45) * A(0.12, s * -0.28, 0), p.primary, "armor")
        kit:box("ChestWingLayer" .. t, "Torso", V(1.3, 1.0, 0.3), C(s * 2.3, 3.95, -2.85) * A(0.12, s * -0.28, 0), p.secondary, "armor")
        kit:box("CockpitPillar" .. t, "Torso", V(0.28, 1.6, 0.55), C(s * 1.45, 4.0, -2.4), p.steel, "armor")
        kit:box("FlankBracket" .. t, "Torso", V(1.3, 1.3, 1.2), C(s * 2.9, 1.9, -2.2), p.dark, "frame")
        kit:cylZ("FlankBracketRing" .. t, "Torso", 0.3, 1.1, C(s * 2.9, 1.9, -2.85), p.steel, "joint")
    end
    -- Recessed cockpit: dark well, canopy glass, bezel, brow hood.
    kit:box("CockpitWell", "Torso", V(2.7, 1.6, 0.5), C(0, 4.0, -2.15), p.dark, "frame")
    local glass = kit:glow("CockpitCanopy", "Torso", V(2.4, 1.2, 0.1), C(0, 4.0, -2.42) * A(0.12, 0, 0), p.visor, "glow")
    glass.Transparency = 0.25
    kit:box("CockpitSill", "Torso", V(2.9, 0.25, 0.6), C(0, 3.22, -2.5), p.steel, "armor")
    kit:box("CockpitHood", "Torso", V(3.1, 0.35, 0.95), C(0, 4.9, -2.45) * A(-0.25, 0, 0), p.secondary, "armor")
    kit:box("ChestDeck", "Torso", V(5.0, 0.4, 3.4), C(0, 5.15, 0.2), p.primary, "armor")
    for i = -1, 1 do
        kit:box("DeckVent" .. (i + 2), "Torso", V(0.9, 0.12, 1.4), C(i * 1.4, 5.38, 0.7), p.dark, "armor")
    end

    -- Reactor backpack + exhaust.
    kit:box("ReactorMount", "Torso", V(4.4, 3.2, 0.4), C(0, 3.2, 2.3), p.dark, "frame")
    kit:cylZ("ReactorHousing", "Torso", 1.8, 3.2, C(0, 3.2, 3.3), p.secondary, "reactor")
    kit:cylZ("ReactorBandA", "Torso", 0.28, 3.55, C(0, 3.2, 2.7), p.accent, "reactor")
    kit:cylZ("ReactorBandB", "Torso", 0.28, 3.55, C(0, 3.2, 3.9), p.accent, "reactor")
    kit:cylZ("ReactorCap", "Torso", 0.2, 2.6, C(0, 3.2, 4.25), p.steel, "reactor")
    local core = kit:glowCylZ("ReactorCore", "Torso", 0.3, 2.0, C(0, 3.2, 4.45), p.glow)
    core.Name = "ReactorCore"
    local light = Instance.new("PointLight")
    light.Color = p.glow
    light.Range = 16
    light.Brightness = 1.4
    light.Parent = core
    for i = 0, 6 do
        kit:box("CoolingFin" .. i, "Torso", V(0.16, 1.7, 1.4), C(-2.1 + i * 0.7, 1.15, 2.7), p.steel, "reactor")
    end
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:box("ExhaustBase" .. t, "Torso", V(1.4, 0.8, 1.4), C(s * 2.3, 4.6, 2.9), p.dark, "reactor")
        kit:cylY("ExhaustStack" .. t, "Torso", 2.6, 0.95, C(s * 2.3, 6.0, 2.9), p.secondary, "reactor")
        kit:cylY("ExhaustRim" .. t, "Torso", 0.25, 1.2, C(s * 2.3, 7.3, 2.9), p.accent, "reactor")
        kit:cylY("ExhaustGlow" .. t, "Torso", 0.1, 0.7, C(s * 2.3, 7.4, 2.9), p.glow, "glow", Enum.Material.Neon)

        -- Pauldron: base, tilted shell, front guard, stripe, rear cap, pod bracket.
        kit:box("PauldronBase" .. t, "Torso", V(3.4, 0.8, 4.4), C(s * 5.0, 5.2, 0.1), p.dark, "frame")
        kit:box("PauldronShell" .. t, "Torso", V(3.2, 0.9, 4.6), C(s * 5.1, 5.75, 0.1) * A(0, 0, -s * 0.2), p.primary, "armor")
        kit:box("PauldronFront" .. t, "Torso", V(3.0, 1.3, 0.5), C(s * 5.1, 5.2, -2.45) * A(0.25, 0, 0), p.secondary, "armor")
        kit:box("PauldronStripe" .. t, "Torso", V(2.6, 0.1, 1.2), C(s * 5.1, 6.25, -0.9) * A(0, 0, -s * 0.2), p.accent, "armor")
        kit:box("PauldronRear" .. t, "Torso", V(3.0, 1.0, 0.5), C(s * 5.1, 5.3, 2.5), p.secondary, "armor")
        kit:box("ShoulderPodBracket" .. t, "Torso", V(1.4, 0.5, 2.4), C(s * 5.1, 6.45, 0.8), p.dark, "frame")
    end
    if ctx.reinforced then
        kit:box("ReinforcedChestPlate", "Torso", V(5.0, 1.6, 0.4), C(0, 2.2, -2.85) * A(0.18, 0, 0), p.steel, "armor")
        for _, side in ipairs(SIDES) do
            kit:box("ReinforcedPauldron" .. side[1], "Torso", V(2.4, 0.4, 3.6), C(side[2] * 5.15, 6.35, 0.1) * A(0, 0, -side[2] * 0.2), p.steel, "armor")
        end
    end
end

local function buildHead(kit, p)
    kit:cylY("Neck", "Head", 1.0, 1.8, C(0, -0.7, 0), p.dark, "joint")
    kit:box("HeadBlock", "Head", V(2.6, 1.6, 2.8), C(0, 0.2, 0), p.secondary, "frame")
    kit:box("HeadCrown", "Head", V(2.8, 0.4, 3.0), C(0, 1.1, 0.1) * A(0.1, 0, 0), p.primary, "armor")
    kit:box("HeadChin", "Head", V(2.0, 0.5, 0.9), C(0, -0.45, -1.35) * A(-0.3, 0, 0), p.primary, "armor")
    kit:glow("SensorVisor", "Head", V(2.2, 0.35, 0.15), C(0, 0.3, -1.45), p.visor, "glow")
    for _, side in ipairs(SIDES) do
        local s, t = side[2], side[1]
        kit:cylZ("SensorLens" .. t, "Head", 0.25, 0.55, C(s * 0.85, -0.15, -1.45), p.dark, "joint")
        kit:box("HeadCheek" .. t, "Head", V(0.35, 1.2, 2.0), C(s * 1.45, 0.1, 0.2), p.primary, "armor")
    end
    kit:cylY("Antenna", "Head", 2.0, 0.12, C(0.9, 2.0, 0.9), p.steel, "frame")
end

local function buildArm(kit, p, side)
    local s, t = side[2], side[1]
    local sh, el = "Shoulder" .. t, "Elbow" .. t
    kit:cylX("ShoulderBall" .. t, sh, 3.0, 2.6, C(0, 0, 0), p.dark, "joint")
    kit:cylX("ShoulderCap" .. t, sh, 0.3, 2.2, C(s * 1.65, 0, 0), p.steel, "joint")
    kit:box("UpperArmFrame" .. t, sh, V(2.2, 3.0, 2.4), C(0, -1.9, 0), p.dark, "frame")
    kit:box("UpperArmShell" .. t, sh, V(2.6, 2.4, 2.9), C(s * 0.1, -1.6, 0), p.primary, "armor")
    kit:box("UpperArmShield" .. t, sh, V(0.4, 3.0, 3.4), C(s * 1.7, -1.5, 0.1), p.secondary, "armor")
    kit:box("UpperArmStripe" .. t, sh, V(0.1, 0.35, 3.0), C(s * 1.93, -0.5, 0.1), p.accent, "armor")

    kit:cylX("ElbowBall" .. t, el, 2.8, 1.9, C(0, 0, 0), p.dark, "joint")
    kit:cylX("ElbowCap" .. t, el, 0.25, 2.1, C(s * 1.45, 0, 0), p.steel, "joint")
    kit:box("ForearmFrame" .. t, el, V(2.2, 2.8, 2.6), C(0, -1.7, 0), p.dark, "frame")
    kit:box("ForearmShell" .. t, el, V(2.5, 2.0, 2.9), C(0, -1.4, 0.15) * A(-0.08, 0, 0), p.primary, "armor")
    kit:box("ForearmLayer" .. t, el, V(2.0, 1.2, 0.35), C(0, -1.2, -1.5), p.secondary, "armor")
    kit:box("Gauntlet" .. t, el, V(2.6, 1.3, 2.8), C(0, -3.2, 0), p.secondary, "armor")
    kit:box("GauntletTrim" .. t, el, V(2.7, 0.12, 2.9), C(0, -2.5, 0), p.accent, "armor")
end

local function buildLeg(kit, p, side, ctx)
    local s, t = side[2], side[1]
    local th, kn, an = "Thigh" .. t, "Knee" .. t, "Ankle" .. t
    kit:box("ThighFrame" .. t, th, V(2.2, 3.2, 2.4), C(0, -1.9, 0), p.dark, "frame")
    kit:box("ThighFront" .. t, th, V(2.4, 2.8, 0.5), C(0, -1.8, -1.4) * A(0.1, 0, 0), p.primary, "armor")
    kit:box("ThighSide" .. t, th, V(0.45, 2.6, 2.6), C(s * 1.45, -1.7, 0), p.secondary, "armor")
    kit:box("ThighStripe" .. t, th, V(0.1, 0.3, 2.4), C(s * 1.7, -0.7, 0), p.accent, "armor")

    kit:cylX("KneeJoint" .. t, kn, 3.2, 1.9, C(0, 0, 0), p.dark, "joint")
    kit:cylX("KneeCap" .. t, kn, 0.3, 2.2, C(s * 1.75, 0, 0), p.steel, "joint")
    kit:box("KneePad" .. t, kn, V(2.4, 1.6, 1.0), C(0, 0.1, -1.35) * A(-0.2, 0, 0), p.primary, "armor")
    kit:box("KneePadTrim" .. t, kn, V(2.0, 0.14, 0.2), C(0, 0.85, -1.9), p.accent, "armor")

    kit:box("ShinFrame" .. t, kn, V(2.0, 3.2, 2.2), C(0, -1.9, 0), p.dark, "frame")
    kit:box("ShinFront" .. t, kn, V(2.4, 2.8, 0.5), C(0, -1.9, -1.25) * A(-0.12, 0, 0), p.primary, "armor")
    kit:box("CalfPod" .. t, kn, V(2.2, 2.2, 1.2), C(0, -1.4, 1.3), p.secondary, "armor")
    kit:box("CalfVent" .. t, kn, V(1.4, 0.8, 0.12), C(0, -1.5, 1.95), p.dark, "armor")

    kit:cylX("AnkleJoint" .. t, an, 2.8, 1.3, C(0, 0, 0), p.dark, "joint")
    kit:box("FootBase" .. t, an, V(3.0, 0.9, 4.0), C(0, -0.25, -0.9), p.dark, "frame", Enum.Material.DiamondPlate)
    kit:box("FootArmor" .. t, an, V(2.7, 0.35, 2.6), C(0, 0.25, -1.1) * A(0.06, 0, 0), p.primary, "armor")
    kit:box("ToePlate" .. t, an, V(2.8, 0.5, 1.3), C(0, -0.2, -3.0) * A(0.15, 0, 0), p.secondary, "armor")
    kit:box("HeelBlock" .. t, an, V(2.4, 0.9, 1.2), C(0, -0.3, 1.3), p.secondary, "armor")
    if ctx.variant == "ENERGY" then
        kit:glow("ShinGlow" .. t, kn, V(0.1, 2.2, 0.15), C(s * 1.05, -1.9, -1.45), p.beam, "glow")
    end
end

local function buildVariantExtras(kit, p, ctx)
    if ctx.variant == "ENERGY" then
        for _, side in ipairs(SIDES) do
            local s, t = side[2], side[1]
            kit:cylY("CapacitorSpire" .. t, "Torso", 2.8, 0.7, C(s * 0.95, 6.5, 3.0), p.dark, "reactor")
            for i = 0, 2 do
                kit:cylY("SpireCoil" .. t .. i, "Torso", 0.16, 1.0, C(s * 0.95, 5.6 + i * 0.8, 3.0), p.beam, "glow", Enum.Material.Neon)
            end
            kit:glow("PauldronCoil" .. t, "Torso", V(0.12, 0.5, 3.4), C(s * 6.75, 5.45, 0.1), p.beam, "glow")
        end
    elseif ctx.variant == "MISSILE" then
        for _, side in ipairs(SIDES) do
            local s, t = side[2], side[1]
            kit:box("AmmoBin" .. t, "Torso", V(1.8, 2.6, 1.8), C(s * 2.9, 2.0, 3.0), p.secondary, "armor")
            kit:box("AmmoBinStripe" .. t, "Torso", V(1.6, 0.25, 0.1), C(s * 2.9, 2.9, 3.95), p.accent, "armor")
            kit:box("AmmoBinStripeB" .. t, "Torso", V(1.6, 0.25, 0.1), C(s * 2.9, 1.9, 3.95), p.accent, "armor")
            kit:box("PauldronSkirt" .. t, "Torso", V(0.5, 2.0, 3.8), C(s * 6.85, 4.9, 0.1), p.primary, "armor")
        end
        kit:cylZ("TargetingDish", "Head", 0.3, 0.9, C(-1.6, 0.9, -0.4), p.steel, "joint")
        kit:box("BrowGuard", "Head", V(3.0, 0.3, 1.0), C(0, 0.75, -1.5) * A(0.35, 0, 0), p.primary, "armor")
    else
        kit:box("CommMast", "Torso", V(0.15, 2.2, 0.15), C(-1.5, 6.5, 2.4), p.steel, "frame")
        for _, side in ipairs(SIDES) do
            kit:box("ShoulderMarker" .. side[1], "Torso", V(1.0, 0.1, 1.0), C(side[2] * 5.1, 6.28, 1.9), p.accent, "armor")
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

    for socketName, weaponId in pairs(ctx.loadout.mounts) do
        local socket = RigSpec.Sockets[socketName]
        if socket then
            WeaponModules.Build(kit, weaponId, socketName, socket.joint, RigSpec.SocketLocalCF(socketName), p)
        end
    end
end

return Bastion
