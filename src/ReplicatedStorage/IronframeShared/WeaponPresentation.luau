-- Presentation only. Never read by WeaponState/Energy or server damage resolution.
return {
    effectDistance = 650, effectLimit = 48, effectLifetime = 0.45,
    casing = { limit = 28, distance = 140, lifetime = 2.6, fadeTime = 0.45,
        length = 0.48, diameter = 0.18, speed = 10, lift = 3.2, restitution = 0.32, friction = 0.52,
        maxBounces = 3, gravityScale = 1, portSide = 0.72, portY = 0.06, portZ = -0.85 },
    -- Per-weapon overrides of the base casing (MG-9) parameters. A weapon absent here uses `casing` unchanged.
    -- port* locate the ejection port in the weapon frame (breech at origin, muzzle toward -Z).
    casingProfiles = {
        W_HMG_MAULER = { name = "SpentHMG20Case", length = 1.05, diameter = 0.4, speed = 12.5, lift = 5.2, side = 2.2,
            spin = 1.3, restitution = 0.38, friction = 0.45, maxBounces = 4, lifetime = 3, typeLimit = 10, protect = 0.8,
            portSide = 1.0, portY = 0.28, portZ = -1.5, boltSize = { 0.12, 0.5, 1.0 }, mouth = 0.78, bounceVolume = 0.07 },
    },
    recoil = {
        W_MACHINE_GUN = { distance = 0.24, kickTime = 0.018, recoverTime = 0.09, pitch = 0.006, cycle = 0.18 },
        W_LASER_RIFLE = { distance = 0.11, kickTime = 0.012, recoverTime = 0.14, pitch = 0.002, cycle = 0 },
        -- Heavy: receiver slams back, barrel slides further in its housing, brief return to battery; torso nudge is a
        -- cosmetic pitch of the root frame only (0.3 degrees), never fed to locomotion or hit resolution.
        W_HMG_MAULER = { distance = 0.62, kickTime = 0.022, recoverTime = 0.27, pitch = 0.016, cycle = 0.42, barrel = 0.5,
            torso = 0.0045 },
    },
    audio = {
        -- Original WAV: assets/audio/lr12_discharge.wav. Set only after upload/moderation and experience access check.
        laserAssetId = "rbxassetid://123083870222487", -- registered/validated via tools/roblox_audio_upload.py
        laserDuration = 0.32, laserVolume = 0.65, pitchVariation = 0.025,
        -- Original WAV: assets/audio/mauler_discharge.wav. Uploaded and moderation-approved via tools/roblox_audio_upload.py.
        maulerAssetId = "rbxassetid://75916048000769", maulerDuration = 0.62, maulerVolume = 0.8,
        dischargeVoices = 8, detailVoices = 4, maxDistance = 220,
        machineSound = "rbxasset://sounds/impact_explosion_03.mp3",
        mechanismSound = "rbxasset://sounds/action_footsteps_plastic.mp3",
    },
    -- Heavy-weapon visual identity (cosmetic budgets are shared with the base effect pool).
    heavy = {
        W_HMG_MAULER = { flash = { 0.7, 0.7, 1.9 }, light = 2.4, lightRange = 12, smoke = 5, blast = 3.2, blastTime = 0.09,
            life = 0.6, tracer = 0.09, portFlash = 0.26, sparks = 14, fragments = 5, impactSize = 1.5, impactFlash = 1.6,
            sparkSpeed = 24, cockpitLight = 0.35 },
    },
}
