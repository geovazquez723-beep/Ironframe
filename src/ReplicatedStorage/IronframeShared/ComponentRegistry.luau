-- All numbers are prototype balance parameters, not final game tuning.
local ComponentRegistry = {
    CAP_STANDARD = { name = "Integrated C-160", class = "capacitor", mass = 0, capacity = 160, initialCharge = 160,
        chargeEfficiency = 0.9, maxChargeRate = 50, maxDischargeRate = 100, burstLimit = 60 },
    CAP_HIGH_DENSITY = { name = "C-240 Reserve", class = "capacitor", mass = 1.0, capacity = 240, initialCharge = 240,
        chargeEfficiency = 0.94, maxChargeRate = 55, maxDischargeRate = 120, burstLimit = 80 },
    SHIELD_PULSE = { name = "P-01 Pulse Guard", class = "shield", mass = 0, quality = 1, integrity = 180,
        activationCost = 25, chargeTime = 0.15, perfectTime = 0.25, activeTime = 0.5, recoveryTime = 0.25,
        cooldown = 4, activeDrain = 50, arcCos = math.cos(math.rad(65)), perfectMultiplier = 1.45, impactEnergy = 0.18,
        mitigation = { ballistic = 0.65, laser = 0.8, plasma = 0.5, missile = 0.4 } },
    CORE_220 = { name = "Core 220", class = "reactor", mass = 4.0, powerOutput = 80 },
    CORE_300 = { name = "Core 300", class = "reactor", mass = 5.0, powerOutput = 120 },
    RAD_STANDARD = { name = "Standard Radiator", class = "cooling", mass = 1.5, coolingPerSecond = 18 },
    RAD_ADVANCED = { name = "High-Flow Radiator", class = "cooling", mass = 2.4, coolingPerSecond = 28 },
    ARMOR_STANDARD = { name = "Composite Armor", class = "armor", mass = 3.0, integrityBonus = 200 },
    ARMOR_REINFORCED = { name = "Reinforced Armor", class = "armor", mass = 4.5, integrityBonus = 450 },

    W_LASER_RIFLE = {
        name = "LR-12 Laser Rifle", class = "weapon", family = "energy", size = 2,
        mass = 2.1, powerDraw = 8, heatPerSecond = 5, nominalDps = 25,
    },
    W_PLASMA_CANNON = {
        name = "PC-40 Plasma Cannon", class = "weapon", family = "energy", size = 3,
        mass = 5.5, powerDraw = 26, heatPerSecond = 13, nominalDps = 48,
    },
    W_MACHINE_GUN = {
        name = "MG-9 Machine Gun", class = "weapon", family = "ballistic", size = 2,
        mass = 2.5, powerDraw = 3, heatPerSecond = 1, nominalDps = 22,
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
