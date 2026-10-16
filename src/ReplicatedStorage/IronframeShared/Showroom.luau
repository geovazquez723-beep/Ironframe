-- Deterministic showroom pose: pure function of time + phase. It never touches loadout stats
-- or placement, and every angle is clamped to the RigSpec limits.

local RigSpec = require(script.Parent.RigSpec)

local Showroom = {}

local function rad(value: number): number
    return math.rad(value)
end

-- Returns absolute joint angles (radians) and a small vertical bob (studs).
function Showroom.Pose(t: number, phase: number?): ({ [string]: number }, number)
    local p = (phase or 0) % 6.2831853
    local breathe = math.sin(t * 1.3 + p)
    local sway = math.sin(t * 0.55 + p)
    local scan = math.sin(t * 0.8 + p * 0.5)
    local torsoTurn = math.sin(t * 0.32 + p)

    local delta: { [string]: number } = {
        Hip = rad(1.1) * sway,
        Torso = rad(16) * torsoTurn,
        Head = rad(-8) * torsoTurn + rad(9) * scan, -- sensor leads/counters the torso
        ShoulderL = rad(2.5) * breathe,
        ShoulderR = rad(2.5) * -breathe,
        ElbowL = rad(2) * -breathe,
        ElbowR = rad(2) * breathe,
    }
    for _, tag in ipairs({ "L", "R" }) do
        local weight = if tag == "L" then breathe else -breathe
        local settle = rad(1.4) * (0.6 * breathe + 0.4 * weight)
        -- Thigh/knee/ankle deltas (+d, -2d, +d) keep the foot orientation level.
        delta["Thigh" .. tag] = settle
        delta["Knee" .. tag] = -2 * settle
        delta["Ankle" .. tag] = settle
    end

    local angles: { [string]: number } = {}
    for name, d in pairs(delta) do
        local joint = RigSpec.JointsByName[name]
        angles[name] = RigSpec.ClampAngle(name, joint.rest + d)
    end
    return angles, 0.06 * breathe
end

return Showroom
