-- Pure per-weapon impact recipes for armoured machines (M11B). No Roblox types: offline tests load this file.
--
-- A recipe says WHAT an armour hit looks and sounds like; the client (DestructionFx) decides HOW (pooled emitters, fragments, lights). Keeping the numbers
-- here lets the tests state the intent of the milestone directly: the three weapons must produce visibly and audibly different damage, a machine-gun
-- round must not look like artillery, and every effect count is bounded.
--
--   MG       rapid, small: a few directional metal sparks and a bright pin-point, almost no smoke or debris, a short high "tick"
--   LASER    concentrated energy: a hot white-orange flash that lingers as a glowing, molten spot, a fine fast spark spray, a wisp of smoke, an energy sizzle
--   HEAVY    the Mauler: a hard flash and pressure ring, a heavy spark burst, plate chips and dark fragments, dust, a low thud with a lasting light
--
-- Component modifiers: tracks kick up dirt at the ground, turrets ring with sparks, the engine / machinery arcs electrically, reactors vent steam.

local Profile = {}

Profile.Classes = { "MG", "LASER", "HEAVY" }

-- Hard bounds on what one impact may spawn (the client pools are sized from these).
Profile.Limits = { sparks = 40, chips = 16, dust = 14, smoke = 4, fragments = 5, arcs = 12 }

local BASE = {
    MG = {
        flash = 0.9, sparks = 5, sparkSize = 0.2, sparkSpeed = 1.0, directional = true, chips = 0, dust = 0, smoke = 0, fragments = 0, shock = 0,
        light = { color = { 255, 214, 150 }, brightness = 0.9, range = 5, decay = 14 },
        mark = nil, glow = false, shake = 0,
        sound = { name = "metalHit", volume = 0.38, pitch = 1.55 },
    },
    LASER = {
        flash = 2.4, sparks = 11, sparkSize = 0.17, sparkSpeed = 1.5, directional = false, chips = 0, dust = 0, smoke = 1, fragments = 0, shock = 0,
        light = { color = { 255, 170, 80 }, brightness = 1.8, range = 9, decay = 3.2 }, -- lingers: the metal glows
        mark = 1.2, glow = true, shake = 0,
        sound = { name = "laserSizzle", volume = 0.7, pitch = 1.0 },
        sound2 = { name = "zap", volume = 0.25, pitch = 1.6 },
    },
    HEAVY = {
        flash = 6.5, sparks = 24, sparkSize = 0.4, sparkSpeed = 1.2, directional = false, chips = 12, dust = 6, smoke = 2, fragments = 4, shock = 9,
        light = { color = { 255, 200, 120 }, brightness = 3.4, range = 17, decay = 12 },
        mark = 3.0, glow = false, shake = 0.5,
        sound = { name = "metalHit", volume = 1.0, pitch = 0.62 },
        sound2 = { name = "explosion", volume = 0.35, pitch = 1.5 },
    },
}

-- component family -> modifier: multiplicative on counts, plus additions.
local FAMILY = {
    HULL = {},
    TURRET = { sparks = 1.25, ring = true },
    TRACK = { chips = 0.6, dust = 1, dustSize = 2.4, sparks = 0.85 },
    ENGINE = { arcs = 5, smoke = 1, sparkColor = { 150, 220, 255 }, sparks = 0.9 },
    -- Mech regions (Bastion / ROOK)
    CORE = {},
    ARM = { arcs = 3, sparkColor = { 150, 220, 255 }, sparks = 0.9 },
    LEG = { dust = 1, dustSize = 2.0, arcs = 2, sparks = 0.9 },
    REACTOR = { arcs = 8, smoke = 1, steam = true, sparkColor = { 170, 230, 255 }, sparks = 0.8 },
}

local function familyOf(comp: string?): string
    if not comp then
        return "HULL"
    end
    if comp == "TRACK_L" or comp == "TRACK_R" then
        return "TRACK"
    end
    local mech = string.match(comp, "^(%u+)_[LR]$")
    if mech == "ARM" or mech == "LEG" then
        return mech
    end
    return if FAMILY[comp] then comp else "HULL"
end
Profile.FamilyOf = familyOf

local function clamp(n: number, hi: number): number
    return if n > hi then hi else n
end

-- class: "MG" | "LASER" | "HEAVY" (anything else is treated as MG); comp: logical component or nil; returns a fresh recipe.
function Profile.For(class: string, comp: string?)
    local base = BASE[class] or BASE.MG
    local fam = FAMILY[familyOf(comp)]
    local r = {}
    for k, v in pairs(base) do
        r[k] = v
    end
    r.class = if BASE[class] then class else "MG"
    r.family = familyOf(comp)
    r.sparks = clamp(math.floor(base.sparks * (fam.sparks or 1) + 0.5), Profile.Limits.sparks)
    r.chips = clamp(math.floor(base.chips * (fam.chips or 1) + 0.5), Profile.Limits.chips)
    r.dust = clamp(base.dust + (fam.dust or 0) * (if r.class == "MG" then 1 else 3), Profile.Limits.dust)
    r.smoke = clamp(base.smoke + (fam.smoke or 0), Profile.Limits.smoke)
    r.arcs = clamp((fam.arcs or 0) * (if r.class == "MG" then 0.4 elseif r.class == "LASER" then 1.2 else 1), Profile.Limits.arcs)
    r.arcs = math.floor(r.arcs + 0.5)
    r.dustSize = fam.dustSize or 1.4
    r.sparkColor = fam.sparkColor or (if r.class == "LASER" then { 255, 190, 100 } else { 255, 196, 96 })
    r.ring = fam.ring == true
    r.steam = fam.steam == true
    r.fragments = clamp(base.fragments, Profile.Limits.fragments)
    -- Visual / audible weight: a scalar the tests compare. Counts and sizes, not volume alone.
    r.weight = r.flash * 0.35 + r.sparks * r.sparkSize * 0.5 + r.chips * 0.12 + r.fragments * 0.5 + r.shock * 0.15 + r.smoke * 0.3 + (if r.mark then r.mark * 0.2 else 0)
    return r
end

-- Persistent surface mark class used by the server (TrainingTank.mark) and the client scorch pool.
function Profile.MarkClass(class: string): string
    if class == "HEAVY" then
        return "crater"
    elseif class == "LASER" then
        return "burn"
    end
    return "pit"
end

-- Reflection of an incoming direction about a surface normal (both unit, plain tables {x,y,z}): where metal sparks go for a glancing round.
function Profile.Reflect(dx: number, dy: number, dz: number, nx: number, ny: number, nz: number): (number, number, number)
    local dot = dx * nx + dy * ny + dz * nz
    return dx - 2 * dot * nx, dy - 2 * dot * ny, dz - 2 * dot * nz
end

return Profile
