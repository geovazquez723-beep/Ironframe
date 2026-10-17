-- Data for the M10A destructible proving ground. Pure tables (no Roblox types), so offline tests can load it.
--
-- Damage model. Weapons are NOT hard-coded per target. A weapon id maps to a weapon CLASS (MG / LASER / HEAVY); a
-- material (or a per-object override) lists a resistance multiplier per class. effective = weaponDamage * resist[class].
-- The raw weapon numbers (damage, cadence, energy) stay in ComponentRegistry and are never changed here.

local Config = {}

-- Weapon identity ---------------------------------------------------------------------------------------------------------
Config.weaponClassById = {
    W_MACHINE_GUN = "MG",
    W_LASER_RIFLE = "LASER",
    W_HMG_MAULER = "HEAVY",
    TANK_CANNON = "HEAVY", -- M10B: unmanned tank shells break cover like the Mauler does (CombatConfig.shellWeaponId)
}

-- Unknown ballistic/energy weapons (future content) still resolve: by category, and heavy ballistic by per-hit damage.
function Config.WeaponClass(weaponId: string?, category: string?, damage: number?): string?
    local byId = weaponId and Config.weaponClassById[weaponId]
    if byId then
        return byId
    end
    if category == "laser" then
        return "LASER"
    elseif category == "ballistic" then
        return if (damage or 0) >= 20 then "HEAVY" else "MG"
    end
    return nil
end

-- Materials ---------------------------------------------------------------------------------------------------------------
-- hp            default health of one module
-- resist        multiplier per weapon class
-- damagedAt     fraction of health at/below which the module shows its DAMAGED variant
-- label         stage word used by the range display for the final stage (walls "BREACH", the rest "DESTROY")
-- fx            effect family used by the client (DestructionFx)
-- splash        true: heavy-weapon splash may chip this material
Config.materials = {
    PANEL = { name = "LIGHT INDUSTRIAL PANEL", hp = 110, resist = { MG = 1.25, LASER = 1.0, HEAVY = 1.7 }, damagedAt = 0.62, fx = "panel", final = "BREACHED", splash = true },
    CONCRETE = { name = "REINFORCED CONCRETE", hp = 420, resist = { MG = 0.3, LASER = 0.45, HEAVY = 1.55 }, damagedAt = 0.66, fx = "concrete", final = "COLLAPSED", splash = true },
    ARMOR = { name = "ARMORED METAL", hp = 360, resist = { MG = 0.34, LASER = 0.85, HEAVY = 1.12 }, damagedAt = 0.6, fx = "metal", final = "BREACHED", splash = true },
    STRUCTURE = { name = "HEAVY STRUCTURAL", hp = 720, resist = { MG = 0.12, LASER = 0.4, HEAVY = 0.95 }, damagedAt = 0.7, fx = "structure", final = "COLLAPSED", splash = true },
    MACHINERY = { name = "EXPOSED MACHINERY", hp = 170, resist = { MG = 1.3, LASER = 1.2, HEAVY = 1.5 }, damagedAt = 0.6, fx = "machine", final = "DISABLED", splash = true },
    -- Vehicle and training-mech components use the same engine; they just never take splash from other targets.
    VEHICLE_HULL = { name = "HEAVY HULL ARMOR", hp = 700, resist = { MG = 0.16, LASER = 0.55, HEAVY = 0.9 }, damagedAt = 0.66, fx = "metal", final = "DESTROYED" },
    VEHICLE_TURRET = { name = "TURRET ARMOR", hp = 520, resist = { MG = 0.22, LASER = 0.62, HEAVY = 1.0 }, damagedAt = 0.62, fx = "metal", final = "DISABLED" },
    VEHICLE_TRACK = { name = "TRACK ASSEMBLY", hp = 240, resist = { MG = 0.45, LASER = 0.7, HEAVY = 1.25 }, damagedAt = 0.6, fx = "metal", final = "DISABLED" },
    VEHICLE_ENGINE = { name = "ENGINE DECK", hp = 210, resist = { MG = 1.1, LASER = 1.15, HEAVY = 1.4 }, damagedAt = 0.55, fx = "machine", final = "DISABLED" },
    MECH_CHASSIS = { name = "CENTRAL CHASSIS", hp = 760, resist = { MG = 0.26, LASER = 0.62, HEAVY = 1.0 }, damagedAt = 0.62, fx = "metal", final = "DISABLED" },
    MECH_ARM = { name = "ARM WEAPON MOUNT", hp = 260, resist = { MG = 0.5, LASER = 0.8, HEAVY = 1.25 }, damagedAt = 0.6, fx = "machine", final = "DISABLED" },
    MECH_ARMOR = { name = "SHOULDER ARMOR", hp = 300, resist = { MG = 0.42, LASER = 0.75, HEAVY = 1.15 }, damagedAt = 0.6, fx = "metal", final = "DESTROYED" },
    MECH_LEG = { name = "LEG ASSEMBLY", hp = 340, resist = { MG = 0.4, LASER = 0.7, HEAVY = 1.2 }, damagedAt = 0.6, fx = "machine", final = "DISABLED" },
}

-- Heavy-weapon blast: damages nearby STRUCTURAL modules only (never vehicles, mechs, pilots or capsules).
Config.splash = {
    HEAVY = { radius = 6.5, fraction = 0.5, maxTargets = 10 },
}

-- Stages in order. DAMAGED has its own visual variant; DESTROYED removes server-owned collision and line of sight.
Config.stages = { "INTACT", "DAMAGED", "DESTROYED" }

-- Server-side limits (the cosmetic client limits live in Config.client).
Config.limits = {
    rubbleParts = 160, -- simultaneous server-owned rubble parts across a district
    overlayPerModule = 4, -- crack/chip parts added to one DAMAGED module
    fxBatchInterval = 0.1, -- seconds between effect packets
    fxHitsPerBatch = 18, -- impact events kept per packet (extra hits are dropped, not queued)
    fxMaxEventsPerBatch = 40,
    statsInterval = 0.2,
    collapseDelayMin = 0.35,
    collapseDelayMax = 0.9,
    resetChunk = 36, -- objects restored per heartbeat during a reset
    hitRearmGuard = 0.0,
}

-- Client cosmetic budgets. All fragments are client-created, bounded and recycled.
Config.client = {
    maxFragments = 64,
    fragmentLife = 3.6,
    fragmentFade = 0.7,
    maxScorch = 36,
    scorchLife = 28,
    emitterSlots = 20,
    soundVoices = 10,
    maxDistance = 520, -- effects farther than this from the camera are skipped
    maxNotices = 4,
}

-- Per-fx-family presentation (client). Colors are 0-255 triples.
Config.fx = {
    panel = { spark = { 255, 190, 90 }, debris = { 120, 126, 130 }, dust = { 150, 150, 148 }, fragments = 3, big = 6 },
    concrete = { spark = { 255, 210, 140 }, debris = { 120, 120, 116 }, dust = { 168, 164, 156 }, fragments = 4, big = 9 },
    metal = { spark = { 255, 196, 96 }, debris = { 74, 80, 78 }, dust = { 110, 110, 108 }, fragments = 3, big = 7 },
    structure = { spark = { 255, 200, 120 }, debris = { 90, 92, 92 }, dust = { 150, 148, 142 }, fragments = 3, big = 8 },
    machine = { spark = { 120, 210, 255 }, debris = { 56, 60, 64 }, dust = { 90, 90, 90 }, fragments = 3, big = 6 },
}

-- Original synthesized sounds (tools/synthesize_destruction_audio.py), filled in after the Open Cloud upload validates.
-- An empty id stays silent; the client never substitutes a different sample.
Config.audio = {
    concreteHit = { id = "rbxassetid://90380186327747", volume = 0.7, duration = 0.28 },
    metalHit = { id = "rbxassetid://89556137773249", volume = 0.6, duration = 0.22 },
    laserSizzle = { id = "rbxassetid://125716281003648", volume = 0.5, duration = 0.3 },
    collapse = { id = "rbxassetid://110245360489063", volume = 1.0, duration = 1.6 },
    explosion = { id = "rbxassetid://98545819452219", volume = 1.0, duration = 1.4 },
    zap = { id = "rbxassetid://123144333775805", volume = 0.6, duration = 0.4 },
}

return Config
