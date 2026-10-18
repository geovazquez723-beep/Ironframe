local ChassisRegistry = {
    IF42_BASTION = {
        id = "IF42_BASTION",
        displayName = "IF-42 Bastion",
        class = "Medium",
        massLimit = 42,
        dryMass = 19.5,
        baseIntegrity = 1000,
        -- Integrated default generator/capacitor mass is included in dryMass; upgrade mass is additional.
        defaultSystems = { capacitor = "CAP_STANDARD", shield = "SHIELD_PULSE", actuators = "ACT_STANDARD" },
        -- M11C cockpit contract: the physical frame (CockpitLayouts), the equipment packages this frame can take, and what a factory machine wears.
        -- A future chassis names its own layout and a compatible catalog; the sensor services never look at the frame.
        cockpit = { layout = "BASTION_FRAME", packages = { "CKP_STANDARD", "CKP_RECON" }, defaultPackage = "CKP_STANDARD",
            defaultAvionics = { radar = "AV_RADAR_BASIC" }, eyeHeight = 13.6 },
        referenceIntegrity = 1200, -- baseIntegrity + ARMOR_STANDARD: the structure the CombatConfig region health is tuned for
        energy = {
            idle = 8, drive = 20, speed = 14, acceleration = 2.4, turn = 10, braking = 0.35,
            sprintDemand = 100, sprintMultiplier = 1.6, sprintAcceleration = 1.35, coolingScale = 0.6,
        },
        hardpoints = {
            left_arm       = { size = 3, families = { "energy", "ballistic", "missile" } },
            right_arm      = { size = 3, families = { "energy", "ballistic", "missile" } },
            left_shoulder  = { size = 2, families = { "energy", "ballistic", "missile" } },
            right_shoulder = { size = 2, families = { "energy", "ballistic", "missile" } },
            left_torso     = { size = 1, families = { "energy", "ballistic" } },
            right_torso    = { size = 1, families = { "energy", "ballistic" } },
        },

        -- M07 locomotion. Everything the drive model, gait, camera and audio need to move THIS chassis lives here, so a
        -- future chassis only adds another table. Units: studs, seconds, radians (turn rates are written in degrees).
        locomotion = {
            maxForward = 16, -- studs/s
            maxReverse = 7,
            accelForward = 7.0, -- studs/s^2 (about 2.5 s to near full speed with the soft tail below)
            accelReverse = 4.5,
            coastDecel = 7.0, -- throttle released
            brakeDecel = 13.0, -- throttle reversed against the motion
            responsiveness = 2.2, -- 1/s: the approach to the target speed softens once within a few studs/s of it
            jerk = 20.0, -- studs/s^3, limits how quickly acceleration itself may change (the "weight")
            turnRate = math.rad(35), -- rad/s at full steering
            turnAccel = math.rad(55), -- rad/s^2 building up
            turnDecel = math.rad(95), -- rad/s^2 coming off
            turnSpeedPenalty = 0.3, -- fraction of turn rate lost at full forward speed
            hull = { width = 14, height = 15.5, depth = 14.5, offsetX = 0, offsetY = 10.3, offsetZ = -1.6 }, -- box centre offset in the chassis frame (plain numbers: usable without Roblox types)
            stepUp = 2.4, -- hull floor clearance: ledges lower than this are walked over
            climbRate = 9, -- studs/s the body may rise to follow ground
            fallRate = 30, -- studs/s the body may descend
            maxTilt = math.rad(12),
            tiltSmooth = 5,
            footprint = 4.5, -- half-spacing of the ground probes
            bumpSpeed = 3, -- impact speed above which a collision is reported
        },

        -- Procedural gait. The legs are solved with two-bone IK against a foot path in the body frame so a planted foot is
        -- stationary on the ground while the body moves over it.
        gait = {
            refSpeed = 16, -- speed at which stride/amplitudes saturate
            refTurn = math.rad(35),
            hipHalfWidth = 2.5,
            thighLength = 3.6,
            shinLength = 3.6,
            restFootDrop = 6.52, -- ankle depth below the thigh joint in the showroom pose
            crouch = 1.05, -- body lowered at full stride
            reach = 4.4, -- hard foot travel limit either side of the hip (studs)
            stepMin = 1.3, -- half stride when only turning or creeping
            stepMax = 4.0, -- half stride at full speed
            landFrac = 0.92, -- touchdown point as a fraction of the half stride
            liftMax = 1.15,
            swingScale = 0.55,
            swingMin = 0.30,
            swingMax = 0.62,
            settleDist = 0.35,
            settleSwing = 0.42,
            moveEps = 0.25,
            impactDip = 0.14, -- studs the hull drops on a heavy footfall
            hipRoll = math.rad(1.3),
            torsoCounter = math.rad(1.9),
            armSwing = math.rad(3.2),
            headLead = math.rad(5),
            leanMax = math.rad(1.8),
            leanPerAccel = math.rad(0.45),
            sway = 0.16, -- studs of lateral weight shift
        },
    },
}

return ChassisRegistry
