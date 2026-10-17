-- Presentation only. Never read by WeaponState/Energy or server damage resolution.
return {
    effectDistance = 650, effectLimit = 48, effectLifetime = 0.45,
    casing = { limit = 28, distance = 140, lifetime = 2.6, fadeTime = 0.45,
        length = 0.48, diameter = 0.18, speed = 10, lift = 3.2, restitution = 0.32, friction = 0.52,
        maxBounces = 3, gravityScale = 1, portSide = 0.72, portY = 0.06, portZ = -0.85 },
    recoil = {
        W_MACHINE_GUN = { distance = 0.24, kickTime = 0.018, recoverTime = 0.09, pitch = 0.006, cycle = 0.18 },
        W_LASER_RIFLE = { distance = 0.11, kickTime = 0.012, recoverTime = 0.14, pitch = 0.002, cycle = 0 },
    },
    audio = {
        -- Original WAV: assets/audio/lr12_discharge.wav. Set only after upload/moderation and experience access check.
        laserAssetId = "",
        laserDuration = 0.32, laserVolume = 0.65, pitchVariation = 0.025,
        dischargeVoices = 8, detailVoices = 4, maxDistance = 220,
        machineSound = "rbxasset://sounds/impact_explosion_03.mp3",
        mechanismSound = "rbxasset://sounds/action_footsteps_plastic.mp3",
    },
}
