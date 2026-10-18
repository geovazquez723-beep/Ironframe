local Loadouts = {
    order = { "BALANCED", "ENERGY", "MISSILE", "AUTOCANNON" },
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
        AUTOCANNON = {
            name = "Bastion / Heavy Autocannon",
            chassisId = "IF42_BASTION",
            systems = { reactor = "CORE_220", cooling = "RAD_STANDARD", armor = "ARMOR_STANDARD" },
            mounts = {
                left_arm = "W_LASER_RIFLE", right_arm = "W_HMG_MAULER",
                left_shoulder = "W_MACHINE_GUN", right_shoulder = "W_LASER_RIFLE",
                left_torso = "W_MICRO_LASER", right_torso = "W_MICRO_MG",
            },
        },
    },
}

-- M10C: enemy loadouts. Deliberately NOT in `presets` / `order`: the player can never select, assemble or deploy these (SetPreset only
-- accepts ids from `presets`). The rig contract (MechRig weapon recoil / aiming) and the builders look them up through `Loadouts.Get`.
Loadouts.enemy = {
    ROOK = {
        name = "ROOK-01 / Autonomous Combat Test Unit",
        chassisId = "IF42_BASTION",
        systems = { reactor = "CORE_220", cooling = "RAD_STANDARD", armor = "ARMOR_STANDARD" },
        mounts = { left_arm = "W_LASER_RIFLE", right_arm = "W_MACHINE_GUN" },
    },
}

function Loadouts.Get(id)
    return Loadouts.presets[id] or Loadouts.enemy[id]
end

return Loadouts
