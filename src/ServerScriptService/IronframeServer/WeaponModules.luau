-- Procedural weapon modules. Each builder authors parts in the WEAPON frame (barrel along -Z,
-- origin at the breech / mount point) and the dispatcher re-parents them to the socket's joint
-- via `mountCF`, so a weapon stays glued to its socket however the rig moves.
-- Replace any builder with an imported MeshPart (see PartKit) without touching the rig.

local WeaponModules = {}

local V, C = Vector3.new, CFrame.new

local function circle(radius, count, phase)
    local points = {}
    for i = 0, count - 1 do
        local a = phase + i * (math.pi * 2 / count)
        table.insert(points, Vector3.new(math.cos(a) * radius, math.sin(a) * radius, 0))
    end
    return points
end

local builders = {}

builders.W_LASER_RIFLE = function(m)
    local p = m.palette
    m:box("Receiver", V(1.0, 1.1, 3.0), C(0, 0, -1.4), p.secondary, "weapon")
    m:box("TopRail", V(0.5, 0.2, 2.6), C(0, 0.65, -1.5), p.dark, "weapon")
    m:cylZ("Shroud", 3.2, 0.72, C(0, 0, -4.2), p.dark, "weapon")
    m:cylZ("InnerBarrel", 1.2, 0.34, C(0, 0, -5.9), p.steel, "weapon")
    for i, z in ipairs({ -3.2, -4.1, -5.0 }) do
        m:glowCylZ("FocusCoil" .. i, 0.16, 0.98, C(0, 0, z), p.beam)
    end
    m:glowCylZ("EmitterLens", 0.22, 0.46, C(0, 0, -6.5), p.beam)
    for i = 0, 3 do
        m:box("HeatFin" .. i, V(0.9, 0.1, 0.55), C(0, 0.78, -0.5 - i * 0.7), p.steel, "weapon")
    end
    for _, s in ipairs({ -1, 1 }) do
        m:box("PowerCell" .. (s < 0 and "L" or "R"), V(0.4, 0.6, 1.5), C(s * 0.7, -0.1, -1.2), p.dark, "weapon")
    end
end

builders.W_PLASMA_CANNON = function(m)
    local p = m.palette
    m:box("Housing", V(1.9, 1.9, 2.6), C(0, 0, -1.3), p.secondary, "weapon")
    m:box("HousingCap", V(1.5, 0.3, 2.0), C(0, 1.05, -1.3), p.primary, "weapon")
    m:cylZ("Barrel", 3.6, 1.3, C(0, 0, -4.4), p.dark, "weapon")
    for i, z in ipairs({ -3.2, -4.1, -5.0, -5.9 }) do
        m:glowCylZ("PlasmaCoil" .. i, 0.26, 1.85 - i * 0.05, C(0, 0, z), p.beam)
    end
    m:cylZ("MuzzleShroud", 0.7, 1.65, C(0, 0, -6.5), p.steel, "weapon")
    m:glowCylZ("MuzzleCore", 0.2, 1.0, C(0, 0, -6.88), p.beam)
    m:glow("CoreWindow", V(0.45, 0.4, 1.1), C(0, 1.0, -1.3), p.beam)
    for _, s in ipairs({ -1, 1 }) do
        local tag = s < 0 and "L" or "R"
        m:cylZ("Capacitor" .. tag, 2.2, 0.72, C(s * 1.25, 0.1, -1.6), p.dark, "weapon")
        m:glowCylZ("CapacitorBand" .. tag, 0.14, 0.8, C(s * 1.25, 0.1, -2.5), p.beam)
    end
end

builders.W_MACHINE_GUN = function(m)
    local p = m.palette
    m:box("Receiver", V(1.0, 1.1, 2.3), C(0, 0, -1.0), p.secondary, "weapon")
    m:box("FeedChute", V(0.5, 0.5, 0.9), C(0.6, -0.55, -0.7), p.dark, "weapon")
    m:box("AmmoBox", V(1.05, 1.0, 1.4), C(0.15, -1.05, -0.8), p.accent, "weapon")
    for i, point in ipairs(circle(0.3, 3, math.pi / 2)) do
        m:cylZ("Barrel" .. i, 3.4, 0.3, C(point.X, point.Y, -3.7), p.steel, "weapon")
    end
    m:cylZ("BarrelClampRear", 0.35, 1.1, C(0, 0, -2.7), p.dark, "weapon")
    m:cylZ("BarrelClampFront", 0.35, 1.1, C(0, 0, -4.7), p.dark, "weapon")
    m:cylZ("Muzzle", 0.5, 0.95, C(0, 0, -5.4), p.dark, "weapon")
end

builders.W_HMG_MAULER = function(m)
    local p, side = m.palette, m.side -- side: -1 left arm, +1 right arm; ejection port faces outward, feed faces inward
    -- Armored receiver with a stepped top cover and flank plates.
    m:box("Receiver", V(1.9, 1.8, 3.4), C(0, 0, -1.7), p.secondary, "weapon")
    m:box("ReceiverCover", V(1.5, 0.32, 2.7), C(0, 1.05, -1.9), p.primary, "weapon")
    m:box("CoverStep", V(1.1, 0.24, 1.2), C(0, 1.3, -1.3), p.dark, "weapon")
    -- Armor plate on the inboard flank only; the outboard flank stays open around the ejection port.
    m:box("FlankPlate", V(0.16, 1.5, 2.2), C(-side * 1.0, 0, -1.9), p.primary, "weapon")
    m:box("PortSurround", V(0.1, 1.1, 1.9), C(side * 0.98, 0.05, -1.5), p.primary, "weapon")
    -- Heavy mounting yoke and rear braces (the existing socket frame is untouched; this is weapon-side hardware).
    m:box("MountYoke", V(2.3, 2.1, 0.55), C(0, 0, 0.1), p.dark, "weapon")
    for _, s in ipairs({ -1, 1 }) do
        m:box("YokeBrace" .. (s < 0 and "L" or "R"), V(0.3, 0.3, 2.0), C(s * 0.8, -0.95, -0.7), p.steel, "weapon")
    end
    -- Recoil housing around the barrel root, with buffer rings.
    m:cylZ("RecoilHousing", 2.4, 1.4, C(0, 0, -4.4), p.dark, "weapon")
    for i, z in ipairs({ -3.4, -4.1, -4.8, -5.5 }) do
        m:cylZ("BufferRing" .. i, 0.18, 1.52, C(0, 0, z), p.steel, "weapon")
    end
    -- Fixed reinforced shroud, then the sliding barrel and muzzle brake (tagged so recoil slides them).
    m:cylZ("BarrelShroud", 1.8, 1.0, C(0, 0, -6.35), p.secondary, "weapon")
    for i, z in ipairs({ -5.8, -6.4, -7.0 }) do
        m:box("ShroudVent" .. i, V(1.06, 0.12, 0.34), C(0, 0.5, z), p.dark, "weapon")
    end
    local barrel = m:cylZ("HeavyBarrel", 3.2, 0.62, C(0, 0, -6.8), p.steel, "weapon")
    if barrel then barrel:SetAttribute("WeaponBarrel", true) end
    local brake = m:cylZ("MuzzleBrake", 0.95, 1.05, C(0, 0, -7.55), p.dark, "weapon")
    if brake then brake:SetAttribute("WeaponBarrel", true) end
    for _, s in ipairs({ -1, 1 }) do
        local fin = m:box("BrakeBaffle" .. (s < 0 and "L" or "R"), V(0.12, 0.8, 0.62), C(s * 0.58, 0, -7.55), p.steel, "weapon")
        if fin then fin:SetAttribute("WeaponBarrel", true) end
    end
    -- Visible ammunition feed: drum on the inboard flank with a curved chute into the receiver.
    m:box("AmmoDrum", V(1.1, 1.7, 1.7), C(-side * 1.55, -0.45, -1.6), p.accent, "weapon")
    m:box("DrumBand", V(1.16, 0.2, 1.76), C(-side * 1.55, 0.0, -1.6), p.dark, "weapon")
    m:box("FeedChute", V(0.7, 0.55, 0.9), C(-side * 1.05, 0.45, -2.3), p.dark, "weapon")
    m:box("FeedChuteArm", V(0.45, 0.4, 0.7), C(-side * 0.85, 0.7, -2.9), p.steel, "weapon")
    -- Large-caliber ejection port frame on the outboard flank.
    m:box("PortFrameTop", V(0.2, 0.14, 1.25), C(side * 1.06, 0.62, -1.5), p.steel, "weapon")
    m:box("PortFrameBottom", V(0.2, 0.14, 1.25), C(side * 1.06, -0.04, -1.5), p.steel, "weapon")
    m:box("PortShade", V(0.1, 0.5, 1.0), C(side * 1.03, 0.29, -1.5), p.dark, "weapon")
end

builders.W_MISSILE_POD = function(m)
    local p = m.palette
    m:box("PodBody", V(2.3, 1.9, 3.4), C(0, 0, -1.7), p.secondary, "weapon")
    m:box("PodTopPlate", V(2.0, 0.2, 2.8), C(0, 1.05, -1.7), p.primary, "weapon")
    m:box("FrontBezel", V(2.45, 2.05, 0.25), C(0, 0, -3.5), p.dark, "weapon")
    for col = -1, 1, 2 do
        for row = -1, 1 do
            local x, y = col * 0.55, row * 0.58
            m:cylZ(("Tube_%d_%d"):format(col, row), 0.3, 0.52, C(x, y, -3.66), p.dark, "weapon")
            m:glowCylZ(("Warhead_%d_%d"):format(col, row), 0.1, 0.3, C(x, y, -3.58), p.accent)
        end
    end
    for _, s in ipairs({ -1, 1 }) do
        local tag = s < 0 and "L" or "R"
        m:box("HazardStripe" .. tag, V(0.1, 1.1, 0.7), C(s * 1.2, 0, -0.8), p.accent, "weapon")
        m:box("SideBrace" .. tag, V(0.15, 1.6, 0.25), C(s * 1.2, 0, -2.6), p.dark, "weapon")
    end
    m:box("RearVent", V(1.4, 0.7, 0.15), C(0, 0, 0.05), p.dark, "weapon")
end

builders.W_MICRO_LASER = function(m)
    local p = m.palette
    m:box("Body", V(0.6, 0.65, 1.5), C(0, 0, -0.75), p.secondary, "weapon")
    m:cylZ("Barrel", 1.2, 0.3, C(0, 0, -2.1), p.dark, "weapon")
    m:glowCylZ("Coil", 0.12, 0.5, C(0, 0, -1.8), p.beam)
    m:glowCylZ("Lens", 0.15, 0.28, C(0, 0, -2.75), p.beam)
end

builders.W_MICRO_MG = function(m)
    local p = m.palette
    m:box("Body", V(0.6, 0.65, 1.2), C(0, 0, -0.6), p.secondary, "weapon")
    m:cylY("Drum", 0.5, 0.7, C(0, 0.5, -0.5), p.dark, "weapon")
    for _, s in ipairs({ -1, 1 }) do
        m:cylZ("Barrel" .. (s < 0 and "L" or "R"), 1.4, 0.2, C(s * 0.15, 0, -1.9), p.steel, "weapon")
    end
    m:cylZ("Clamp", 0.2, 0.62, C(0, 0, -1.6), p.dark, "weapon")
end

-- Shared fallback so an unknown weapon ID is still visible rather than silently missing.
local function fallback(m)
    m:box("Placeholder", V(0.8, 0.8, 2.0), C(0, 0, -1.0), m.palette.dark, "weapon")
end

-- M05 visual meshes. The LOGICAL weapon ids (cost, stats, socket rules) are untouched: this table only chooses which
-- generated asset draws a given id. `cf` places the mesh bounding-box centre in the weapon frame (breech at the
-- origin, muzzle toward -Z); `yaw` turns a mesh that was generated facing the other way. Missing assets fall back to
-- the procedural builders above, so the weapon never disappears.
WeaponModules.Meshes = {
    W_MACHINE_GUN = { asset = "WPN_010", cf = C(0, 0, -2.2), scale = 1.6, yaw = 0 },
    W_LASER_RIFLE = { asset = "WPN_011", cf = C(0, 0, -2.9), scale = 1.7, yaw = 0 },
    W_PLASMA_CANNON = { asset = "WPN_012", cf = C(0, 0, -3.0), scale = 1.2, yaw = 0 },
    W_MISSILE_POD = { asset = "WPN_013", cf = C(0, 0, -1.9), scale = 1.0, yaw = 0 },
}

function WeaponModules.Build(kit, weaponId, socketName, joint, mountCF, palette)
    local component = require(game.ReplicatedStorage.IronframeShared.ComponentRegistry)[weaponId]
    if component and component.combat then
        local muzzle = kit:box("Weapon_" .. socketName .. "_Emitter", joint, V(0.12,0.12,0.12),
            mountCF * C(0,0,-component.combat.muzzle), palette.beam, "weapon")
        muzzle.Transparency = 1
        muzzle:SetAttribute("WeaponMuzzle", true)
        -- Weapons whose recoil slides the barrel carry their flash/tracer origin with it (it is the barrel tip).
        local recoil = require(game.ReplicatedStorage.IronframeShared.WeaponPresentation).recoil[weaponId]
        if recoil and recoil.barrel then muzzle:SetAttribute("WeaponBarrel", true) end
    end
    local presentation = require(game.ReplicatedStorage.IronframeShared.WeaponPresentation)
    local fx = if weaponId == "W_MACHINE_GUN" then presentation.casing else presentation.casingProfiles[weaponId]
    if fx then
        local side = if string.sub(socketName,1,4) == "left" then -1 else 1
        local boltSize = fx.boltSize or { 0.08, 0.25, 0.52 }
        -- The carrier is rigged with the imported/procedural assembly. LookVector points OUT from the receiver.
        local portCF = mountCF * C(side*fx.portSide,fx.portY,fx.portZ) * CFrame.Angles(0,-side*math.pi/2,0)
        local carrier = kit:box("Weapon_"..socketName.."_EjectionPort",joint,V(0.12,0.12,0.12),portCF,palette.steel,"weapon")
        carrier.Transparency = 1
        local attachment = Instance.new("Attachment")
        attachment.Name,attachment.Parent = "EjectionPort",carrier
        -- Small visible bolt / port rim on the receiver, also retained when an imported mesh is used.
        local bolt = kit:box("Weapon_"..socketName.."_Bolt",joint,V(boltSize[1],boltSize[2],boltSize[3]),
            mountCF*C(side*(fx.portSide-0.08),fx.portY,fx.portZ),palette.steel,"weapon")
        bolt:SetAttribute("WeaponBolt",true)
    end
    local meshSpec = WeaponModules.Meshes[weaponId]
    if meshSpec and kit.useAssets ~= false then
        local placed = kit:mesh({
            asset = meshSpec.asset, name = "Weapon_" .. socketName .. "_Body", joint = joint,
            cf = mountCF * meshSpec.cf * CFrame.Angles(0, math.rad(meshSpec.yaw or 0), 0), scale = meshSpec.scale,
            color = palette.tint, group = "weapon",
        })
        if placed then
            return
        end
    end
    local builder = builders[weaponId] or fallback
    local module = { palette = palette, side = if string.sub(socketName,1,4) == "left" then -1 else 1 }
    local function name(part)
        return "Weapon_" .. socketName .. "_" .. part
    end
    function module:box(part, size, cf, color, group)
        return kit:box(name(part), joint, size, mountCF * cf, color, group)
    end
    function module:cylZ(part, length, diameter, cf, color, group)
        return kit:cylZ(name(part), joint, length, diameter, mountCF * cf, color, group)
    end
    function module:cylY(part, length, diameter, cf, color, group)
        return kit:cylY(name(part), joint, length, diameter, mountCF * cf, color, group)
    end
    function module:glow(part, size, cf, color)
        return kit:glow(name(part), joint, size, mountCF * cf, color, "glow")
    end
    function module:glowCylZ(part, length, diameter, cf, color)
        return kit:glowCylZ(name(part), joint, length, diameter, mountCF * cf, color)
    end
    builder(module)
end

WeaponModules.Known = builders

return WeaponModules
