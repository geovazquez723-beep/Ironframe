-- All numbers are prototype balance parameters, not final game tuning.
local ComponentRegistry = {
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
