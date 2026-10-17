--!nocheck
-- IRONFRAME MECH DRIVE MODEL (M07)
--
-- Pure kinematic locomotion for a heavy walker: numbers in, numbers out, no Roblox types, so the same code runs on the
-- server (authoritative), in offline Luau tests, and could drive client prediction later. The model is deliberately a
-- controlled kinematic body, not a physics simulation: it cannot tip, jitter or be launched, and its weight comes from
-- limited acceleration, limited jerk and slow steering.
--
-- Conventions match RigSpec: the mech faces -Z at yaw 0 and a positive yaw turns the front toward the mech's LEFT (-X),
-- so heading vector = (-sin yaw, -cos yaw) in (x, z).
--
-- The world is reached only through a `probe` (all optional, see Probe below), so collision geometry is a separate concern.

local Drive = {}

export type Params = { [string]: any }

export type State = {
    x: number, y: number, z: number,
    yaw: number, pitch: number, roll: number,
    speed: number, -- signed, + forward
    yawRate: number, -- rad/s, + turns left
    accel: number, -- current linear acceleration (jerk-limited)
    throttle: number, steer: number, -- last applied (post-sanitise) input
    contact: number, -- seconds since the hull last touched something
    distance: number, -- odometer, studs
}

Drive.MAX_SUBSTEP = 1 / 30

local function clamp(v: number, lo: number, hi: number): number
    return if v < lo then lo elseif v > hi then hi else v
end

local function approach(value: number, target: number, maxDelta: number): number
    if value < target then
        return math.min(value + maxDelta, target)
    end
    return math.max(value - maxDelta, target)
end

function Drive.New(x: number, y: number, z: number, yaw: number?): State
    return {
        x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0,
        speed = 0, yawRate = 0, accel = 0, throttle = 0, steer = 0, contact = 99, distance = 0,
    }
end

-- Clients are untrusted: anything that is not a finite number in [-1, 1] becomes 0, and values are clamped.
function Drive.SanitizeInput(throttle: any, steer: any): (number, number)
    local function clean(v: any): number
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
            return 0
        end
        return clamp(v, -1, 1)
    end
    return clean(throttle), clean(steer)
end

function Drive.Heading(yaw: number): (number, number)
    return -math.sin(yaw), -math.cos(yaw)
end

-- Probe contract (every function optional; a missing one means "open flat world"):
--   ground(x, y, z, yaw) -> height?, pitch, roll    support height under the mech (nil = no ground)
--   move(x, y, z, yaw, dx, dz) -> nx, nz, hitFraction, normalX, normalZ     swept hull move with wall sliding
--   blocked(x, y, z, yaw) -> boolean                hull overlaps something at this pose (used for turning)

local function stepOnce(s: State, input: { throttle: number?, steer: number?, locked: boolean? }, dt: number, P: Params, probe: any): { [string]: any }
    local events: { [string]: any } = {}
    local throttle, steer = Drive.SanitizeInput(input.throttle, input.steer)
    if input.locked then
        throttle, steer = 0, 0
    end
    s.throttle, s.steer = throttle, steer

    -- Linear speed ----------------------------------------------------------------------------------------------------
    local target = if throttle > 0 then P.maxForward * throttle * (input.speedScale or 1) elseif throttle < 0 then P.maxReverse * throttle * (input.baseScale or 1) else 0
    local err = target - s.speed
    local slowing = math.abs(target) < math.abs(s.speed) or (target ~= 0 and s.speed ~= 0 and (target > 0) ~= (s.speed > 0))
    local limit
    if slowing then
        limit = if throttle == 0 and not input.locked then P.coastDecel else P.brakeDecel -- locked (ejection, startup) stops hard
    else
        limit = if target >= 0 then P.accelForward * (input.accelScale or 1) else P.accelReverse * (input.baseScale or 1)
    end
    local desired = clamp(err * P.responsiveness, -limit, limit)
    -- Past a reversal the brake limit applies until the sign flips, then acceleration limits take over.
    s.accel = approach(s.accel, desired, P.jerk * dt)
    local newSpeed = s.speed + s.accel * dt
    if (newSpeed - target) * (s.speed - target) < 0 then -- would cross the target: settle on it, no overshoot
        newSpeed = target
        s.accel = 0
    end
    if target == 0 and math.abs(newSpeed) < 0.04 then
        newSpeed, s.accel = 0, 0
    end
    s.speed = newSpeed

    -- Steering ---------------------------------------------------------------------------------------------------------
    local turnTarget = steer * P.turnRate * (1 - P.turnSpeedPenalty * clamp(math.abs(s.speed) / P.maxForward, 0, 1))
    local rate = if math.abs(turnTarget) > math.abs(s.yawRate) and (turnTarget * s.yawRate >= 0) then P.turnAccel else P.turnDecel
    s.yawRate = approach(s.yawRate, turnTarget, rate * dt)
    if steer == 0 and math.abs(s.yawRate) < 0.002 then
        s.yawRate = 0
    end
    if s.yawRate ~= 0 then
        local newYaw = s.yaw + s.yawRate * dt
        if probe and probe.blocked and probe.blocked(s.x, s.y, s.z, newYaw) then
            s.yawRate = 0 -- hull would sweep into geometry: hold heading
            events.turnBlocked = true
        else
            s.yaw = newYaw
        end
    end

    -- Translation ------------------------------------------------------------------------------------------------------
    if s.speed ~= 0 then
        local hx, hz = Drive.Heading(s.yaw)
        local dx, dz = hx * s.speed * dt, hz * s.speed * dt
        local nx, nz, hitFraction, nxn, nzn = s.x + dx, s.z + dz, 1, 0, 0
        if probe and probe.move then
            nx, nz, hitFraction, nxn, nzn = probe.move(s.x, s.y, s.z, s.yaw, dx, dz)
        end
        if hitFraction < 1 then
            local impact = math.abs(s.speed * (hx * nxn + hz * nzn))
            if impact > P.bumpSpeed then
                events.bump = impact
            end
            s.contact = 0
            -- Speed that survives the contact is what actually carried the hull along its heading.
            local along = ((nx - s.x) * hx + (nz - s.z) * hz) / dt
            s.speed = clamp(along, -math.abs(s.speed), math.abs(s.speed))
            if math.abs(s.speed) < 0.2 then
                s.speed, s.accel = 0, 0
            end
        end
        s.distance += math.sqrt((nx - s.x) ^ 2 + (nz - s.z) ^ 2)
        s.x, s.z = nx, nz
    end
    s.contact += dt

    -- Ground following ---------------------------------------------------------------------------------------------------
    if probe and probe.ground then
        local height, pitch, roll = probe.ground(s.x, s.y, s.z, s.yaw)
        if height then
            s.y += clamp(height - s.y, -P.fallRate * dt, P.climbRate * dt)
            local k = 1 - math.exp(-P.tiltSmooth * dt)
            s.pitch += (clamp(pitch or 0, -P.maxTilt, P.maxTilt) - s.pitch) * k
            s.roll += (clamp(roll or 0, -P.maxTilt, P.maxTilt) - s.roll) * k
        end
    end
    return events
end

-- Advances the state by `dt`, split into substeps of at most MAX_SUBSTEP so that the result does not depend on frame rate.
-- Returns the merged events (largest bump wins).
function Drive.Advance(s: State, input: any, dt: number, P: Params, probe: any?): { [string]: any }
    local events: { [string]: any } = {}
    dt = clamp(dt, 0, 0.25) -- a long hitch must never launch the machine
    local steps = math.max(1, math.ceil(dt / Drive.MAX_SUBSTEP))
    local h = dt / steps
    for _ = 1, steps do
        local e = stepOnce(s, input, h, P, probe)
        if e.turnBlocked then
            events.turnBlocked = true
        end
        if e.bump and e.bump > (events.bump or 0) then
            events.bump = e.bump
        end
    end
    return events
end

-- Human-readable drive state for telemetry. Derived only from measured speed and the applied input.
function Drive.Classify(s: State, P: Params): string
    local speed = s.speed
    local turning = math.abs(s.yawRate) > math.rad(4)
    if math.abs(speed) < 0.15 then
        return if turning then "PIVOTING" else "IDLE"
    end
    if speed < 0 then
        return if s.throttle < 0 then "REVERSING" else "BRAKING"
    end
    if s.throttle <= 0 then
        return "BRAKING"
    end
    if s.accel > 0.8 and speed < P.maxForward * 0.9 then
        return "ACCELERATING"
    end
    return if turning then "TURNING" else "CRUISING"
end

-- Simple go-to-pose autopilot used for docking: returns throttle, steer, arrived. Turns in place until roughly facing
-- the waypoint, then drives and slows on approach; once on the spot it squares up to `finalYaw`.
function Drive.Autopilot(s: State, tx: number, tz: number, finalYaw: number): (number, number, boolean)
    local dx, dz = tx - s.x, tz - s.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local function wrap(a: number): number
        return (a + math.pi) % (2 * math.pi) - math.pi
    end
    if dist < 3 then
        local err = wrap(finalYaw - s.yaw)
        if math.abs(err) < math.rad(2.5) then
            return 0, 0, math.abs(s.speed) < 0.3
        end
        return 0, clamp(err / math.rad(18), -1, 1), false
    end
    local desiredYaw = math.atan2(-dx, -dz) -- inverse of heading = (-sin yaw, -cos yaw)
    local err = wrap(desiredYaw - s.yaw)
    local steer = clamp(err / math.rad(14), -1, 1)
    local throttle = 0
    if math.abs(err) < math.rad(22) then
        throttle = clamp((dist - 3) / 14, 0.25, 0.7)
    end
    return throttle, steer, false
end

return Drive
