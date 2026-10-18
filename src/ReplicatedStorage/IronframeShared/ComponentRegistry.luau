-- All numbers are prototype balance parameters, not final game tuning.
--
-- M11A: a component marked `selectable = true` is offered in the garage engineering panel (LoadoutCompiler.Catalog derives every list
-- from these flags: there is no second list). Fields that only the compiler reads:
--   reactor     capacitorScale (x capacitor capacity), chargeRateScale (x capacitor charge rate), thermalScale (x heat per energy),
--               coolingScale (x heat dissipation)
--   actuator    speedScale / reverseScale / accelScale / turnScale (x drive limits), legStructureScale (x leg-assembly health),
--               movementEnergyScale (x every movement energy demand)
--   armor       integrityBonus (structure; the per-region health scale is derived from it), speedScale / accelScale / turnScale,
--               movementEnergyScale
local ComponentRegistry = {
    CAP_STANDARD = { name = "Integrated C-160", class = "capacitor", mass = 0, capacity = 160, initialCharge = 160,
        chargeEfficiency = 0.9, maxChargeRate = 50, maxDischargeRate = 100, burstLimit = 60 },
    CAP_HIGH_DENSITY = { name = "C-240 Reserve", class = "capacitor", mass = 1.0, capacity = 240, initialCharge = 240,
        chargeEfficiency = 0.94, maxChargeRate = 55, maxDischargeRate = 120, burstLimit = 80 },
    SHIELD_PULSE = { name = "P-01 Pulse Guard", class = "shield", mass = 0, quality = 1, integrity = 180,
        activationCost = 25, chargeTime = 0.15, perfectTime = 0.25, activeTime = 0.5, recoveryTime = 0.25,
        cooldown = 4, activeDrain = 50, arcCos = math.cos(math.rad(65)), perfectMultiplier = 1.45, impactEnergy = 0.18,
        mitigation = { ballistic = 0.65, laser = 0.8, plasma = 0.5, missile = 0.4 } },
    CORE_220 = { name = "Core 220", class = "reactor", mass = 4.0, powerOutput = 80, selectable = true,
        summary = "Balanced baseline. Deep capacitor, mild heat." },
    CORE_300 = { name = "Core 300", class = "reactor", mass = 5.0, powerOutput = 120 },
    -- M11A high-output reactor: +40 % generation, paid for with a shallow capacitor (the burst bank), hotter conversion and extra mass.
    -- (Thermal is the real ceiling on sustained laser fire, so the package carries big heat exchangers: without them the extra output would be
    -- throttled away. The price is a shallow capacitor, hotter energy conversion and 1.2 t.)
    CORE_260 = { name = "Core 260 High-Output", class = "reactor", mass = 5.2, powerOutput = 112, capacitorScale = 0.65, chargeRateScale = 1.25,
        thermalScale = 1.25, coolingScale = 1.4, selectable = true, summary = "Sustained throughput, big heat exchangers. Shallow capacitor, hot conversion." },
    -- M11A leg actuators. STANDARD is the established Bastion drive; MOBILITY trades leg structure and energy for speed and agility.
    ACT_STANDARD = { name = "Standard Actuators", class = "actuator", mass = 0, speedScale = 1, reverseScale = 1, accelScale = 1, turnScale = 1,
        legStructureScale = 1, movementEnergyScale = 1, selectable = true, summary = "Balanced drive, standard leg structure." },
    ACT_MOBILITY = { name = "Sprint Actuators M-2", class = "actuator", mass = 0.6, speedScale = 1.12, reverseScale = 1.15, accelScale = 1.2, turnScale = 1.2,
        legStructureScale = 0.78, movementEnergyScale = 1.3, selectable = true, summary = "Faster, nimbler. Fragile legs, thirstier drive." },
    RAD_STANDARD = { name = "Standard Radiator", class = "cooling", mass = 1.5, coolingPerSecond = 18 },
    RAD_ADVANCED = { name = "High-Flow Radiator", class = "cooling", mass = 2.4, coolingPerSecond = 28 },
    ARMOR_STANDARD = { name = "Composite Armor", class = "armor", mass = 3.0, integrityBonus = 200, speedScale = 1, accelScale = 1, turnScale = 1,
        movementEnergyScale = 1, selectable = true, summary = "Established Bastion protection." },
    -- Structure +25 % on every region (derived from integrityBonus), for +1.5 t, a slower and thirstier drive.
    ARMOR_REINFORCED = { name = "Reinforced Armor", class = "armor", mass = 4.5, integrityBonus = 500, speedScale = 0.93, accelScale = 0.9, turnScale = 0.94,
        movementEnergyScale = 1.12, selectable = true, summary = "+25% structure. Heavier, slower, thirstier." },

    W_LASER_RIFLE = {
        name = "LR-12 Laser Rifle", class = "weapon", family = "energy", size = 2, selectable = true,
        mass = 2.1, powerDraw = 8, heatPerSecond = 5, nominalDps = 25,
        combat = { category = "laser", damage = 25, interval = 0.25, range = 450, energy = 24,
            heat = 6, mode = "PULSE", magazine = 0, ammoPerShot = 0, reload = 0,
            hardpoints = { left_arm = true, right_arm = true, left_shoulder = true, right_shoulder = true },
            muzzle = 6.62, effect = "LASER" },
    },
    W_PLASMA_CANNON = {
        name = "PC-40 Plasma Cannon", class = "weapon", family = "energy", size = 3,
        mass = 5.5, powerDraw = 26, heatPerSecond = 13, nominalDps = 48,
    },
    W_MACHINE_GUN = {
        name = "MG-9 Machine Gun", class = "weapon", family = "ballistic", size = 2, selectable = true,
        mass = 2.5, powerDraw = 3, heatPerSecond = 1, nominalDps = 22,
        combat = { category = "ballistic", damage = 8, interval = 0.1, range = 350, energy = 0.6,
            heat = 0.12, mode = "AUTO", magazine = 60, ammoPerShot = 1, reload = 3,
            hardpoints = { left_arm = true, right_arm = true, left_shoulder = true, right_shoulder = true },
            muzzle = 5.67, effect = "BALLISTIC" },
    },
    -- M08D heavy autocannon. Arms only (size 3). 3 rounds/s, 3.1x MG-9 per-hit damage, 4.2x MG-9 per-shot energy:
    -- slower, heavier and ammunition-limited, with a long reload window, so it is not a strict MG-9 upgrade.
    W_HMG_MAULER = {
        name = "HMG-20 Mauler", class = "weapon", family = "ballistic", size = 3, selectable = true,
        mass = 5.0, powerDraw = 7, heatPerSecond = 3, nominalDps = 75,
        combat = { category = "ballistic", damage = 25, interval = 1 / 3, range = 500, energy = 2.5,
            heat = 0.9, mode = "AUTO", magazine = 24, ammoPerShot = 1, reload = 3.8, phaseLock = 0.05,
            hardpoints = { left_arm = true, right_arm = true },
            muzzle = 8.0, effect = "HEAVY_BALLISTIC" },
    },
    W_MISSILE_POD = {
        name = "MR-6 Missile Pod", class = "weapon", family = "missile", size = 2,
        mass = 3.0, powerDraw = 6, heatPerSecond = 2, nominalDps = 30,
    },
    W_MICRO_LASER = {
        name = "ML-3 Micro Laser", class = "weapon", family = "energy", size = 1,
        mass = 0.9, powerDraw = 3, heatPerSecond = 3, nominalDps = 12,
    },
    W_MICRO_MG = {
        name = "MG-2 Micro Gun", class = "weapon", family = "ballistic", size = 1,
        mass = 1.1, powerDraw = 1, heatPerSecond = 0.5, nominalDps = 10,
    },
}

return ComponentRegistry
