local ChassisRegistry = {
    IF42_BASTION = {
        id = "IF42_BASTION",
        displayName = "IF-42 Bastion",
        class = "Medium",
        massLimit = 42,
        dryMass = 19.5,
        baseIntegrity = 1000,
        hardpoints = {
            left_arm       = { size = 3, families = { "energy", "ballistic", "missile" } },
            right_arm      = { size = 3, families = { "energy", "ballistic", "missile" } },
            left_shoulder  = { size = 2, families = { "energy", "ballistic", "missile" } },
            right_shoulder = { size = 2, families = { "energy", "ballistic", "missile" } },
            left_torso     = { size = 1, families = { "energy", "ballistic" } },
            right_torso    = { size = 1, families = { "energy", "ballistic" } },
        },
    },
}

return ChassisRegistry
