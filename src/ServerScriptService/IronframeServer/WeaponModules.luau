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

function WeaponModules.Build(kit, weaponId, socketName, joint, mountCF, palette)
    local builder = builders[weaponId] or fallback
    local module = { palette = palette }
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
