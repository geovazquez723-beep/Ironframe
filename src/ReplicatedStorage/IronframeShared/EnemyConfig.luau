-- Data for M10C autonomous mech enemies. Pure tables (no Roblox types) so the offline tests can load it.
--
-- An enemy is DATA: which preset (chassis + weapons) it wears, how tough each region is, how it perceives, how its weapons
-- are used, how it defends and how it moves around its court. The tactical brain (MechBrain), steering / navigation
-- (MechNav) and the server runner (EnemyMech) read only this table, so a second chassis or a different weapon pair is a new
-- entry, not new code.
--
-- Every number below is a first-pass tuning value for a FIRST autonomous opponent: challenging but forgiving, with readable
-- patterns. None of it has been human-playtested (see docs/M10C_AUTONOMOUS_MECH_COMBAT.md).
--
-- Rules ROOK obeys (nothing here relaxes them): the same reactor / capacitor / thermal ledger, the same pulse-shield
-- timings and costs, the same weapon magazines, reloads and per-shot energy as the player's identical components, the same
-- drive model (acceleration, jerk, turn rate) and the same aim cone. Differences are doctrine (when and how to use them),
-- armour values and reaction times.

local Config = {}

Config.modes = { MECH = "MECH TRIAL - ROOK-01" }

-- Shared trial tuning ------------------------------------------------------------------------------------------------------------
Config.trial = {
    armDelay = 2.5, -- seconds from MECH TRIAL being selected to ROOK being allowed to sense / act (reactor spin-up)
    maxBolts = 24, -- cap on ROOK bolts in flight (an MG burst is 6, an LR volley is 3)
    disabledHold = 0, -- ROOK stays down until the trial is reset; there is no automatic respawn
    separation = 9.0, -- horizontal radius of each mech's collision circle (Bastion hull is 14 wide)
}

-- Region armour: multiplier on PENETRATING damage by region and weapon class (MG-9 / LR-12 / HMG-20). Lower is tougher.
-- Core is shielded by the torso; the reactor backpack is exposed to anything that gets behind the machine.
local function armour(mg: number, laser: number, heavy: number)
    return { MG = mg, LASER = laser, HEAVY = heavy }
end

Config.enemies = {
    ROOK_01 = {
        id = "ROOK_01", callsign = "ROOK-01", designation = "AUTONOMOUS COMBAT TEST UNIT", short = "ROOK",
        presetId = "ROOK", chassisId = "IF42_BASTION", startProfile = "BALANCED",

        -- Where it is parked and how it may move (bay-local studs; the builder adds the district origin).
        station = { x = 0, z = 606, yaw = 0 },
        court = {
            minX = -18, maxX = 18, minZ = 500, maxZ = 612, -- limits for the CENTRE of the hull
            -- Tactical lattice (nodes and edges are validated against real geometry). It must be finer than the hull's clearance around
            -- a cover wall (the hull is 14 wide), or a zig-zag between staggered walls has no connected route.
            cols = { -14, -7, 0, 7, 14 }, rowStart = 504, rowStep = 6, rowCount = 17,
            edgeReach = 9.8, passRadius = 5.0, arriveRadius = 4.5,
        },

        -- Six independently damageable regions, the same names and consequences as the player Bastion (MechDamage).
        structure = {
            regions = { CORE = 700, ARM_L = 220, ARM_R = 220, LEG_L = 260, LEG_R = 260, REACTOR = 240 },
            resist = {
                CORE = armour(0.55, 0.80, 1.00),
                ARM_L = armour(0.80, 1.00, 1.20), ARM_R = armour(0.80, 1.00, 1.20),
                LEG_L = armour(0.70, 0.90, 1.15), LEG_R = armour(0.70, 0.90, 1.15),
                REACTOR = armour(1.00, 1.10, 1.30),
            },
        },

        -- Weapons. `id` and `socket` come from the shared component registry / rig; ROOK adds doctrine only.
        --   spool / charge   seconds of warning before the first round / pulse
        --   burst / pulses   rounds per trigger pull
        --   gap / cooldown   seconds between pulls
        --   lockAt           (LR) fraction of the charge after which the aim is frozen: the player's window to break the lock
        --   speed            bolt speed (studs/s) - rounds are swept projectiles, never instant hits
        --   spread           base aim error half-angle (radians); grows with target speed and with ROOK's own motion
        --   lead             fraction of the target's velocity anticipated (1 = perfect prediction)
        --   damageScale      multiplier on the component's nominal damage (ROOK-only tuning, the component stays untouched)
        weapons = {
            MG = {
                key = "MG", label = "MG-9", id = "W_MACHINE_GUN", socket = "right_arm", region = "ARM_R", category = "ballistic",
                spool = 0.35, burst = 6, gap = 1.3, minRange = 0, maxRange = 140, optimal = 80,
                speed = 250, radius = 0.55, life = 1.4, spread = math.rad(3.0), lead = 0.45, damageScale = 1.0,
            },
            LR = {
                key = "LR", label = "LR-12", id = "W_LASER_RIFLE", socket = "left_arm", region = "ARM_L", category = "laser",
                charge = 1.1, lockAt = 0.8, pulses = 3, gap = 0.25, cooldown = 4.2, chargeDraw = 22, minRange = 35, maxRange = 175, optimal = 120,
                speed = 520, radius = 0.5, life = 0.9, spread = math.rad(1.1), lead = 0.55, damageScale = 1.25,
            },
            -- Doctrine switches (see MechBrain.ChooseWeapon).
            lrPreferRange = 78, -- beyond this the laser is the weapon of choice, closer in the machine gun is
            lrMaxTargetSpeed = 13, -- a target faster than this is a poor laser target (the lock would miss)
            lowEnergy = 0.35, -- capacitor fraction below which the laser is withheld and only the cheap gun is used
            minAmmoForBurst = 6,
        },

        -- Perception: ROOK knows only what it sensed.
        perception = {
            sightRange = 230, sightHalfArc = math.rad(105), proximity = 38,
            hearRange = 260, hearError = 24, -- gunfire fixes the player's position only roughly
            memory = 7.0, -- seconds a contact is remembered after the last confirmation
            acquireTime = 0.9, -- reaction delay between first contact and the first weapon spool
            fireCone = math.rad(26), -- how far off the barrel line the target may be before a pull starts
            losInterval = 0.15,
            lostLosHold = 0.6, -- seconds of broken line of sight before ENGAGE gives up the position
        },

        -- Where it wants to fight.
        tactics = {
            band = { 62, 112 }, -- preferred range band (studs); approaches beyond it, backs off inside the near limit
            tooClose = 40, -- inside this ROOK retreats rather than trades
            approachCap = 0.85, retreatCap = 0.55, creepCap = 0.35,
            flankEvery = 9.5, flankJitter = 3.0, -- seconds of stable engagement before it tries a different angle
            repositionTimeout = 7.0,
            coverBelow = 0.38, -- structure fraction below which it prefers cover
            coverDwell = 5.5, coverRecoverTo = 0.62, -- capacitor fraction it waits to regain in cover (or the dwell ends)
            brakeNoFire = 0.45, -- while moving faster than this fraction of top speed only the MG may fire, with a penalty
        },

        -- Pulse shield (the player's P-01 timings are unchanged; this is only WHEN it is raised).
        defense = {
            reaction = 0.45, reactionJitter = 0.25, -- delay between noticing fire at itself and pressing the shield
            reactChance = 0.7, -- some threats it simply does not react to in time
            arc = math.rad(50), -- the attacker must lie this close to dead ahead (the shield only covers the front)
            minCharge = 0.22, -- capacitor fraction below which it does not even try (activation 25 + sustain)
            minGap = 1.5, -- seconds between two presses regardless of the shield's own state
            hitAwareness = 0.7, -- seconds after taking a hit during which the hit counts as a threat
            aimRadius = 24, -- the player's aim point this close to ROOK counts as "being shot at"
            cycle = 1.15, -- seconds ROOK stays braced (DEFEND) after pressing: charge + perfect + active phases of the P-01 plus a margin
        },

        -- Energy-profile doctrine: MOBILITY to relocate, BALANCED to fight, WEAPONS to prepare a laser volley.
        energy = {
            profileHold = 0.8, -- the same wish must persist this long before a switch is requested
            weaponsMinCharge = 0.5, mobilityRange = 25, lowCharge = 0.25,
        },

        -- Targeting error model (see MechBrain.AimSpread).
        accuracy = {
            rangeGain = 0.5, -- spread x (1 + gain * range / 100): distance costs accuracy
            targetSpeedGain = 1.0, -- spread x (1 + gain * targetSpeed / 14)
            ownSpeedGain = 0.9, -- spread x (1 + gain * ownSpeed / 16)
            damagedArmGain = 1.2, -- spread x (1 + gain * (1 - armHealth))
            maxMultiplier = 4.0,
        },
    },
}

Config.defaultEnemy = "ROOK_01"

return Config
