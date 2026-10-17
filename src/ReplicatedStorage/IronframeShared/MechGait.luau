--!nocheck
-- IRONFRAME PROCEDURAL GAIT (M07)
--
-- Pure numbers, cosmetic only: it reads the measured drive speed and yaw rate and produces joint angles for the existing
-- RigSpec skeleton. It never feeds back into movement, so a bad pose can never corrupt the authoritative position.
--
-- Each leg is a stance/swing state machine in the BODY frame. A planted foot moves backwards through the body at exactly the
-- rate the ground passes beneath it (v + yawRate * hipOffset), so it is stationary in the world: no foot sliding. Feet lift
-- only when the other foot is planted, land with a heavy mechanical dip, and report each touchdown as an event so audio,
-- dust and camera can react to the same contact the eye sees.
--
-- Leg solve: two-bone IK in the sagittal plane (digitigrade, knee forward) onto a foot target (f, d):
--   f = foot forward of the thigh joint (studs, + toward -Z), d = depth of the ankle below the thigh joint.
-- Joint angles follow RigSpec: absolute pitch of each bone, + swings the lower end forward.

local Gait = {}

local function clamp(v: number, lo: number, hi: number): number
    return if v < lo then lo elseif v > hi then hi else v
end

local function smoother(u: number): number
    u = clamp(u, 0, 1)
    return u * u * u * (u * (u * 6 - 15) + 10)
end

local function sign(v: number): number
    return if v >= 0 then 1 else -1
end

export type Leg = {
    side: string, x: number,
    state: string, -- "stance" | "swing"
    f: number, f0: number, f1: number, t: number, T: number, lift: number, height: number,
}

function Gait.New(): any
    return {
        legs = {
            L = { side = "L", x = -1, state = "stance", f = 0, f0 = 0, f1 = 0, t = 0, T = 0.4, lift = 0, height = 0 },
            R = { side = "R", x = 1, state = "stance", f = 0, f0 = 0, f1 = 0, t = 0, T = 0.4, lift = 0, height = 0 },
        },
        lead = "L",
        activity = 0, -- smoothed 0..1, shapes every secondary amplitude
        crouch = 0,
        dip = 0, -- footfall spring: current offset (studs, + = lowered)
        dipVel = 0,
        wasMoving = false,
        slip = 0, -- accumulated planted-foot slip, for diagnostics/tests
        steps = 0,
    }
end

-- Two-bone digitigrade IK. Returns thigh, knee, ankle(flat) absolute angles, and the reach actually used.
function Gait.LegIK(f: number, d: number, l1: number, l2: number): (number, number, number)
    local dist = math.sqrt(f * f + d * d)
    local maxReach = (l1 + l2) * 0.9995
    if dist > maxReach then
        f, d, dist = f * maxReach / dist, d * maxReach / dist, maxReach
    end
    dist = math.max(dist, math.abs(l1 - l2) + 0.05)
    local base = math.atan2(f, d)
    local alpha = math.acos(clamp((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1))
    local thigh = base + alpha
    -- Shin direction from the knee to the ankle.
    local kneeF, kneeD = math.sin(thigh) * l1, math.cos(thigh) * l1
    local shin = math.atan2(f - kneeF, d - kneeD)
    return thigh, shin - thigh, -shin
end

local function startSwing(g: any, leg: Leg, to: number, T: number, height: number)
    leg.state = "swing"
    leg.f0, leg.f1, leg.t, leg.T, leg.height = leg.f, to, 0, T, height
end

-- Advances the gait by dt. v = signed forward speed, w = yaw rate (+ left). Returns a pose description and the events list.
function Gait.Update(g: any, dt: number, v: number, w: number, P: any): (any, { { leg: string, strength: number } })
    local events = {}
    local pace = math.max(1, math.abs(v) / P.refSpeed)
    local swingMin, swingMax = P.swingMin / pace, P.swingMax / pace
    local speedFrac = clamp(math.abs(v) / P.refSpeed, 0, 1)
    local turnFrac = clamp(math.abs(w) / P.refTurn, 0, 1)
    local want = math.max(speedFrac, turnFrac * 0.5)
    g.activity += (want - g.activity) * (1 - math.exp(-4 * dt))
    g.crouch += (P.crouch * speedFrac - g.crouch) * (1 - math.exp(-3 * dt))

    local half = P.stepMin + (P.stepMax - P.stepMin) * speedFrac
    local legs = g.legs
    local rates = {}
    for _, leg in pairs(legs) do
        rates[leg.side] = v + w * leg.x * P.hipHalfWidth -- how fast the ground passes backwards under this foot
    end

    -- 1. Integrate current motion --------------------------------------------------------------------------------------
    for _, leg in pairs(legs) do
        if leg.state == "stance" then
            leg.f -= rates[leg.side] * dt
            if leg.f > P.reach or leg.f < -P.reach then
                -- Past the mechanical reach the foot would have to drag: clamp, and account for the slip.
                local clamped = clamp(leg.f, -P.reach, P.reach)
                g.slip += math.abs(leg.f - clamped)
                leg.f = clamped
            end
        else
            leg.t += dt / leg.T
            local u = clamp(leg.t, 0, 1)
            leg.f = leg.f0 + (leg.f1 - leg.f0) * smoother(u)
            leg.lift = leg.height * math.sin(math.pi * u) ^ 0.8
            if leg.t >= 1 then
                leg.state, leg.lift = "stance", 0
                leg.f = leg.f1
                local strength = clamp(0.3 + 0.7 * speedFrac, 0.3, 1)
                g.dipVel += strength * P.impactDip * 32
                g.steps += 1
                table.insert(events, { leg = leg.side, strength = strength })
            end
        end
    end

    -- 2. Decide new steps (one foot at a time) ---------------------------------------------------------------------------
    local moving = false
    for _, r in pairs(rates) do
        if math.abs(r) > P.moveEps then
            moving = true
        end
    end
    local order = if g.lead == "L" then { legs.L, legs.R } else { legs.R, legs.L }
    for _, leg in ipairs(order) do
        local other = if leg.side == "L" then legs.R else legs.L
        if leg.state == "stance" and other.state == "stance" then
            local s = rates[leg.side]
            local go = false
            local target = 0
            local T = P.settleSwing
            local height = P.liftMax * 0.55
            if math.abs(s) > P.moveEps then
                local dir = sign(s)
                local atLimit = (dir > 0 and leg.f <= -half) or (dir < 0 and leg.f >= half)
                local stepOff = not g.wasMoving and leg.side == g.lead and math.abs(leg.f) < 0.3
                if atLimit or stepOff then
                    go = true
                    target = dir * half * P.landFrac
                    T = clamp(P.swingScale * (2 * half) / math.max(math.abs(s), 1.0), swingMin, swingMax)
                    -- Never keep the other foot waiting past its own lift point: it can only travel so far meanwhile.
                    local so = rates[other.side]
                    if math.abs(so) > P.moveEps then
                        local remaining = if so > 0 then (other.f + half) else (half - other.f)
                        T = math.max(swingMin, math.min(T, remaining / math.abs(so) * 0.95))
                    end
                    height = P.liftMax * (0.5 + 0.5 * speedFrac)
                end
            elseif math.abs(leg.f) > P.settleDist then
                go = true
                target = 0
            end
            if go then
                startSwing(g, leg, target, T, height)
                g.lead = other.side
                break -- only one foot leaves the ground per update
            end
        end
    end
    g.wasMoving = moving

    -- Footfall spring (critically damped): dip jumps on touchdown then settles.
    local k = 140
    local c = 2 * math.sqrt(k)
    g.dipVel += (-k * g.dip - c * g.dipVel) * dt
    g.dip += g.dipVel * dt -- a strength-1 touchdown peaks near P.impactDip (v0 / (w * e) with w = sqrt(k))

    -- 3. Pose ---------------------------------------------------------------------------------------------------------------
    local dStance = P.restFootDrop - g.crouch
    local pose = { angles = {}, crouch = g.crouch, dip = clamp(g.dip, -P.impactDip * 1.5, P.impactDip * 1.5), activity = g.activity }
    local a = pose.angles
    for _, leg in pairs(legs) do
        local d = dStance - leg.lift
        local thigh, knee, ankle = Gait.LegIK(leg.f, d, P.thighLength, P.shinLength)
        local toe = 0
        if leg.state == "swing" then
            local u = clamp(leg.t, 0, 1)
            toe = 0.22 * math.sin(math.pi * math.min(u * 1.6, 1)) - 0.12 * smoother((u - 0.7) / 0.3)
        end
        a["Thigh" .. leg.side], a["Knee" .. leg.side], a["Ankle" .. leg.side] = thigh, knee, ankle + toe
    end

    local reach = math.max(P.stepMax, 1)
    local q = clamp((legs.L.f - legs.R.f) / (2 * reach), -1, 1) -- + when the left foot is ahead of the right
    local liftDiff = (legs.L.lift - legs.R.lift) / math.max(P.liftMax, 0.1)
    local act = g.activity
    pose.torsoYaw = -P.torsoCounter * q * act
    pose.hipRoll = P.hipRoll * liftDiff * act
    pose.sway = P.sway * liftDiff * act -- weight shifts toward the planted side (+x = right)
    pose.shoulderL, pose.shoulderR = -P.armSwing * q * act, P.armSwing * q * act
    pose.elbowL, pose.elbowR = -pose.shoulderL * 0.85, -pose.shoulderR * 0.85 -- forearms/weapons stay level
    pose.headYaw = -pose.torsoYaw + P.headLead * clamp(w / P.refTurn, -1, 1)
    pose.stride = q
    return pose, events
end

-- Forward-kinematic foot position (f, d) from the three leg angles: used by tests to prove the IK and by the diagnostics.
function Gait.FootFromAngles(thigh: number, knee: number, l1: number, l2: number): (number, number)
    local shin = thigh + knee
    return math.sin(thigh) * l1 + math.sin(shin) * l2, math.cos(thigh) * l1 + math.cos(shin) * l2
end

return Gait
