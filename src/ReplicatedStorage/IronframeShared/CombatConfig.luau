-- Data for M10B active tank combat and Bastion component damage. Pure tables (no Roblox types) so offline tests can load it.
--
-- Everything tunable about the encounter lives here: three tank archetypes (what they see, how long they warn, how hard they hit),
-- the shell they fire, the Bastion's six damage regions and the mechanical consequences of losing them.
-- Damage numbers for shells are NOMINAL "ballistic" damage: the existing M08A pulse shield mitigates them through
-- EnergySystems.ResolveImpact, and only the penetrating remainder reaches the Bastion's components.

local Config = {}

Config.modes = { PASSIVE = "PASSIVE RANGE", ACTIVE = "ACTIVE TRAINING" }
Config.defaultMode = "PASSIVE"
Config.armDelay = 2.0 -- seconds between ACTIVE TRAINING being selected and the tanks being allowed to acquire targets
Config.shellWeaponId = "TANK_CANNON" -- registered in DestructionConfig.weaponClassById (HEAVY class against structure)
Config.losInterval = 0.2 -- seconds between line-of-sight refreshes per tank
Config.maxProjectiles = 8 -- district-wide cap on shells in flight (3 tanks, one shell each at most; the cap is a backstop)
Config.sampleHeights = { 9.0, 4.5, 14.5 } -- aim samples above the Bastion's ground point: torso, hips/legs, head

-- Archetypes ---------------------------------------------------------------------------------------------------------------
-- mobility   FIXED (never moves)  PIVOT (turns the hull in place)  ROUTE (drives along its patrol route)
-- detect*    acquisition range / hysteresis range / acquisition delay (turret holds still while "acquiring")
-- warnTime   AIM state length: turret locked on, muzzle charging, targeting beam - the player's window to react
-- reload     seconds between shots (RELOAD state), tanks that can move reposition during it
-- lead       fraction of the target's velocity the tank anticipates (1 = perfect prediction, 0 = aims where you are now)
-- spread     random aim error half-angle (radians)
Config.archetypes = {
    SENTRY = {
        id = "SENTRY", label = "SENTRY", mobility = "FIXED",
        detectRange = 185, fireRange = 175, loseRange = 220, loseTime = 2.5,
        detectTime = 0.8, settleTime = 0.25, warnTime = 0.9, fireTime = 0.25, reload = 4.5,
        turretRate = math.rad(34), aimRateScale = 0.4, aimTolerance = math.rad(2.2), traverse = math.rad(115),
        lead = 0.2, spread = math.rad(1.3),
        shell = { speed = 115, damage = 70, structure = 55, radius = 0.9, life = 3.4, heavy = false },
        hp = nil, -- default component health
    },
    PATROL = {
        id = "PATROL", label = "PATROL", mobility = "ROUTE",
        detectRange = 175, fireRange = 150, loseRange = 215, loseTime = 2.5,
        detectTime = 0.7, settleTime = 0.2, warnTime = 0.75, fireTime = 0.2, reload = 5.5,
        turretRate = math.rad(42), aimRateScale = 0.45, aimTolerance = math.rad(2.8), traverse = math.rad(100),
        lead = 0.25, spread = math.rad(1.8),
        preferredRange = { 85, 130 }, engagedSpeed = 7.0, slowFactor = 0.4, repositionTime = 7,
        shell = { speed = 105, damage = 48, structure = 40, radius = 0.8, life = 3.8, heavy = false },
    },
    HEAVY = {
        id = "HEAVY", label = "HEAVY", mobility = "PIVOT",
        detectRange = 200, fireRange = 190, loseRange = 235, loseTime = 3.0,
        detectTime = 1.4, settleTime = 0.4, warnTime = 1.2, fireTime = 0.4, reload = 8.5,
        turretRate = math.rad(19), aimRateScale = 0.3, aimTolerance = math.rad(1.6), traverse = math.rad(90),
        lead = 0.15, spread = math.rad(1.0), hullTurn = math.rad(10),
        shell = { speed = 85, damage = 150, structure = 120, radius = 1.6, life = 4.6, heavy = true },
        -- Stronger armor: multipliers on the component health of the stock vehicle materials.
        hp = { HULL = 1.6, TURRET = 1.5, TRACK_L = 1.3, TRACK_R = 1.3, ENGINE = 1.3 },
    },
}
Config.archetypeOrder = { "SENTRY", "PATROL", "HEAVY" }

-- Bastion damage model -------------------------------------------------------------------------------------------------------
-- Six regions. Only damage that gets past the pulse shield reaches them. Pilots are NOT a region: nothing here models a person.
Config.mech = {
    regions = { CORE = 900, ARM_L = 300, ARM_R = 300, LEG_L = 380, LEG_R = 380, REACTOR = 320 },
    order = { "CORE", "ARM_L", "ARM_R", "LEG_L", "LEG_R", "REACTOR" },
    names = { CORE = "CORE TORSO", ARM_L = "L WEAPON ASSY", ARM_R = "R WEAPON ASSY", LEG_L = "L LEG ASSY", LEG_R = "R LEG ASSY", REACTOR = "REACTOR HOUSING" },
    spill = 0.2, -- fraction of damage to any other region that is also structural damage to the core
    damagedAt = 0.6, criticalAt = 0.25,
    -- Consequences. speed loss = perDamage * (1 - health fraction) + destroyed, summed over both legs, never below `floor`.
    leg = { perDamage = 0.22, destroyed = 0.12, floor = 0.4 },
    reactor = { perDamage = 0.45, destroyed = 0.15, floor = 0.4 }, -- scales reactor output
    sockets = { ARM_L = { "left_arm", "left_shoulder" }, ARM_R = { "right_arm", "right_shoulder" } }, -- disabled when the assembly fails
    -- Hit-region map, in the hull box's normalised coordinates (see MechDamage.RegionAt).
    legBelow = 0.34, armBeyond = 0.58, reactorBehind = 0.4,
}

return Config
