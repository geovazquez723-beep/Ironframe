-- Tunable constants for the first-person cockpit (M06A). Pure data: the camera, builder, HUD and audio all read it.
-- All offsets are in the TORSO joint frame (RigSpec: mech faces -Z, +X right, +Y up).

local Config = {}

-- Pilot eye point and view limits. The camera is EYE_OFFSET from the animated Torso joint, so it follows torso yaw.
Config.EYE_OFFSET = Vector3.new(0, 4.3, -0.55)
Config.FOV = 74 -- vertical, capped so the horizontal field never exceeds MAX_HFOV (ultrawide screens)
Config.MAX_HFOV = 106
Config.BASE_PITCH = math.rad(-3) -- resting gaze slightly toward the instrument bank
Config.MAX_YAW = math.rad(55) -- head-look limits, left/right
Config.MAX_PITCH_UP = math.rad(28)
Config.MAX_PITCH_DOWN = math.rad(32)
Config.LOOK_SENSITIVITY = 0.0026 -- radians per mouse pixel
Config.LOOK_KEY_RATE = 1.1 -- radians per second for arrow-key head-look
Config.LOOK_SMOOTH = 16

-- Comfort. 0 disables. Sway is angular (radians), vibration is positional (studs). Kept deliberately tiny.
Config.SWAY = 0.0022
Config.VIBRATION = 0.0035
Config.COMFORT_SCALE_ATTRIBUTE = "CockpitComfort" -- player attribute 0..1 multiplies sway and vibration

-- Transition and startup timings (seconds).
Config.TRANSITION = 1.1
Config.BOOT_DURATION = 6.2
Config.EJECT_WARNING = 2.2

-- Visual identity.
Config.COLORS = {
    black = Color3.fromRGB(5, 8, 10),
    panel = Color3.fromRGB(10, 15, 18),
    gunmetal = Color3.fromRGB(46, 51, 56),
    graphite = Color3.fromRGB(28, 31, 35),
    steel = Color3.fromRGB(104, 110, 116),
    cyan = Color3.fromRGB(70, 214, 240),
    cyanDim = Color3.fromRGB(22, 82, 96),
    amber = Color3.fromRGB(255, 176, 52),
    amberDim = Color3.fromRGB(110, 70, 14),
    red = Color3.fromRGB(255, 62, 52), -- reserved for genuine critical warnings
    white = Color3.fromRGB(214, 236, 242),
}

-- Torso-local box (centre-in-box test) of exterior parts hidden locally while the pilot is inside. Weapons and
-- hardpoint mounts are always kept. Nothing is ever modified on the server or for other players.
Config.HIDE_MIN = Vector3.new(-4.2, 1.7, -4.6)
Config.HIDE_MAX = Vector3.new(4.2, 5.95, 2.9)

return Config
