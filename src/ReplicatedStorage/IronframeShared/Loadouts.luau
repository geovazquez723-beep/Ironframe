local Loadouts = {
    order = { "BALANCED", "ENERGY", "MISSILE" },
    presets = {
        BALANCED = {
            name = "Bastion / General Purpose",
            chassisId = "IF42_BASTION",
            systems = { reactor = "CORE_220", cooling = "RAD_STANDARD", armor = "ARMOR_STANDARD" },
            mounts = {
                left_arm = "W_LASER_RIFLE", right_arm = "W_MACHINE_GUN",
                left_shoulder = "W_MISSILE_POD", right_shoulder = "W_LASER_RIFLE",
                left_torso = "W_MICRO_LASER", right_torso = "W_MICRO_MG",
            },
        },
        ENERGY = {
            name = "Bastion / Plasma Specialist",
            chassisId = "IF42_BASTION",
            systems = { reactor = "CORE_220", cooling = "RAD_STANDARD", armor = "ARMOR_STANDARD" },
            mounts = {
                left_arm = "W_PLASMA_CANNON", right_arm = "W_LASER_RIFLE",
                left_shoulder = "W_LASER_RIFLE", right_shoulder = "W_LASER_RIFLE",
                left_torso = "W_MICRO_LASER", right_torso = "W_MICRO_LASER",
            },
        },
        MISSILE = {
            name = "Bastion / Barrage",
            chassisId = "IF42_BASTION",
            systems = { reactor = "CORE_220", cooling = "RAD_STANDARD", armor = "ARMOR_STANDARD" },
            mounts = {
                left_arm = "W_MACHINE_GUN", right_arm = "W_MACHINE_GUN",
                left_shoulder = "W_MISSILE_POD", right_shoulder = "W_MISSILE_POD",
                left_torso = "W_MICRO_LASER", right_torso = "W_MICRO_MG",
            },
        },
    },
}

return Loadouts
