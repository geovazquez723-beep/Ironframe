-- Authoritative mech locomotion (M07).
--
-- The visual rig (300+ anchored parts) is NEVER moved here. The server owns one compact invisible hull Part ("Chassis")
-- whose CFrame is the mech's authoritative pose; clients read it and pose the existing rig around it locally
-- (ShowroomAnimator + MechGait). One CFrame per mech replicates, plus a few rounded attributes for HUD and audio.
--
-- Movement itself is MechDrive (pure, tested offline). This file only supplies the world: a ground probe and a swept hull
-- probe built from Roblox raycasts/blockcasts against CanQuery geometry, and the replication of the result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Drive = require(Shared:WaitForChild("MechDrive"))
local ChassisRegistry = require(Shared:WaitForChild("ChassisRegistry"))
local EnergySystems = require(script.Parent.EnergySystems)

local Locomotion = {}

Locomotion.INPUT_TIMEOUT = 0.75 -- seconds without a fresh input packet before the throttle is treated as released
Locomotion.SKIN = 0.15

export type Controller = {
    model: Model,
    params: { [string]: any },
    state: any,
    input: { throttle: number, steer: number, locked: boolean, sprint: boolean? },
    lastInput: number,
    hull: Part,
    params2: any,
    autopilot: { x: number, z: number, yaw: number }?,
    publishedAt: number,
    published: { speed: number, yawRate: number, state: string },
    stats: { stepMs: number, steps: number },
    lastCF: CFrame,
    energySystems: any?,
    mobility: { speed: number, turn: number }?,
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshFilter()
    local ignore = {}
    local mechs = workspace:FindFirstChild("IronframeMechs")
    if mechs then
        table.insert(ignore, mechs)
    end
    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        if player.Character then
            table.insert(ignore, player.Character)
        end
    end
    rayParams.FilterDescendantsInstances = ignore
    overlapParams.FilterDescendantsInstances = ignore
end

local function hullCFrame(p: any, x: number, y: number, z: number, yaw: number): CFrame
    local h = p.hull
    return CFrame.new(x, y + h.offsetY, z) * CFrame.Angles(0, yaw, 0) * CFrame.new(h.offsetX, 0, h.offsetZ)
end

local function makeProbe(p: any)
    local h = p.hull
    local size = Vector3.new(h.width, h.height, h.depth)
    local fp = p.footprint
    local probe = {}

    local function groundAt(x: number, y: number, z: number): number?
        local result = workspace:Raycast(Vector3.new(x, y + p.stepUp, z), Vector3.new(0, -(p.stepUp + 40), 0), rayParams)
        return result and result.Position.Y or nil
    end

    function probe.ground(x: number, y: number, z: number, yaw: number)
        local center = groundAt(x, y, z)
        if not center then
            return nil, 0, 0
        end
        local hx, hz = Drive.Heading(yaw)
        local rx, rz = math.cos(yaw), -math.sin(yaw)
        local front = groundAt(x + hx * fp, y, z + hz * fp) or center
        local back = groundAt(x - hx * fp, y, z - hz * fp) or center
        local right = groundAt(x + rx * fp, y, z + rz * fp) or center
        local left = groundAt(x - rx * fp, y, z - rz * fp) or center
        -- Ignore ledges taller than the step limit when tilting: they are walls to the hull, not slopes.
        local function tilt(a: number, b: number): number
            return math.atan2(math.clamp(a - b, -p.stepUp, p.stepUp), 2 * fp)
        end
        -- A wide chassis bridges narrow trenches. Following only the centre ray can drop the swept hull into the floor,
        -- where Blockcast no longer detects initial overlaps and could let the mech tunnel into an obstacle.
        return math.max(center, front, back, right, left), tilt(front, back), tilt(right, left)
    end

    function probe.blocked(x: number, y: number, z: number, yaw: number): boolean
        local parts = workspace:GetPartBoundsInBox(hullCFrame(p, x, y, z, yaw), size - Vector3.new(0.3, 0.3, 0.3), overlapParams)
        for _, part in ipairs(parts) do
            if part.CanQuery then
                return true
            end
        end
        return false
    end

    function probe.move(x: number, y: number, z: number, yaw: number, dx: number, dz: number)
        if not groundAt(x + dx, y, z + dz) then
            return x, z, 0, 0, 0 -- never step into missing terrain
        end
        local dir = Vector3.new(dx, 0, dz)
        local length = dir.Magnitude
        if length < 1e-5 then
            return x, z, 1, 0, 0
        end
        local cf = hullCFrame(p, x, y, z, yaw)
        -- Always cast through the safety skin, even for a tiny acceleration substep. A cast shorter than the gap can
        -- miss at engine precision, slowly enter the obstacle, and then ignore it as an initial overlap forever.
        local hit = workspace:Blockcast(cf, size, dir.Unit * (length + Locomotion.SKIN), rayParams)
        if not hit then
            return x + dx, z + dz, 1, 0, 0
        end
        local normal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
        if normal.Magnitude < 1e-3 then
            -- Floor or ceiling contact only; treat as unobstructed horizontally.
            return x + dx, z + dz, 1, 0, 0
        end
        normal = normal.Unit
        local travel = math.max(hit.Distance - Locomotion.SKIN, 0)
        local frac = math.min(travel / length, 1)
        local nx, nz = x + dir.X * frac, z + dir.Z * frac
        -- Slide along the surface with whatever motion remains (one more cast to catch corners).
        local rest = dir * (1 - frac)
        local slide = rest - normal * rest:Dot(normal)
        local slideLength = slide.Magnitude
        if slideLength > 1e-4 then
            local cf2 = hullCFrame(p, nx, y, nz, yaw)
            local hit2 = workspace:Blockcast(cf2, size, slide.Unit * (slideLength + Locomotion.SKIN), rayParams)
            local move2 = if hit2 then math.max(hit2.Distance - Locomotion.SKIN, 0) else slideLength
            local f2 = math.min(move2 / slideLength, 1)
            nx, nz = nx + slide.X * f2, nz + slide.Z * f2
        end
        return nx, nz, math.min(frac, 0.999), normal.X, normal.Z
    end

    return probe
end

local chassisCFrame
function Locomotion.Create(model: Model, chassisId: string, position: Vector3, yaw: number): Controller
    local spec = assert(ChassisRegistry[chassisId], "unknown chassis " .. tostring(chassisId))
    local params = spec.locomotion
    assert(params, chassisId .. " has no locomotion parameters")
    local state = Drive.New(position.X, position.Y, position.Z, yaw)
    local hull = Instance.new("Part")
    hull.Name = "Chassis"
    hull.Size = Vector3.new(params.hull.width, params.hull.height, params.hull.depth)
    hull.Anchored = true
    hull.CanCollide = false -- a pose carrier and hitbox proxy; it must never shove avatars or other mechs around
    hull.CanQuery = true
    hull.CanTouch = false
    hull.Transparency = 1
    hull.CastShadow = false
    hull.Massless = true
    hull:SetAttribute("Hitbox", true)
    local controller: Controller = {
        model = model,
        params = params,
        state = state,
        input = { throttle = 0, steer = 0, locked = true },
        lastInput = os.clock(),
        hull = hull,
        params2 = makeProbe(params),
        autopilot = nil,
        publishedAt = 0,
        published = { speed = 0, yawRate = 0, state = "" },
        stats = { stepMs = 0, steps = 0 },
        lastCF = CFrame.new(),
    }
    controller.lastCF = Locomotion.HullPose(params, state)
    hull.CFrame = controller.lastCF
    hull.Parent = model
    model:SetAttribute("DriveSpeed", 0)
    model:SetAttribute("DriveYawRate", 0)
    model:SetAttribute("DriveState", "IDLE")
    return controller
end

function Locomotion.Destroy(c: Controller)
    if c.hull then
        c.hull:Destroy()
    end
    if c.model and c.model.Parent then
        c.model:SetAttribute("DriveSpeed", nil)
        c.model:SetAttribute("DriveYawRate", nil)
        c.model:SetAttribute("DriveState", nil)
    end
end

-- Untrusted client input. Always sanitised; the timestamp feeds the dead-man timeout.
function Locomotion.SetInput(c: Controller, throttle: any, steer: any, sprint: any)
    local t, s = Drive.SanitizeInput(throttle, steer)
    c.input.throttle, c.input.steer = t, s
    c.input.sprint = sprint == true
    c.lastInput = os.clock()
end

function Locomotion.SetLocked(c: Controller, locked: boolean)
    c.input.locked = locked
end

function Locomotion.Position(c: Controller): Vector3
    return Vector3.new(c.state.x, c.state.y, c.state.z)
end

-- Snap the authoritative pose (used by recall/return). Speed and rates are zeroed.
function Locomotion.Teleport(c: Controller, position: Vector3, yaw: number)
    local s = c.state
    s.x, s.y, s.z, s.yaw = position.X, position.Y, position.Z, yaw
    s.speed, s.yawRate, s.accel, s.pitch, s.roll = 0, 0, 0, 0, 0
end

-- Leg damage (M10B): drive performance multipliers applied on top of the energy economy. 1,1 clears the penalty.
function Locomotion.SetMobility(c: Controller, speed: number, turn: number)
    if speed >= 0.999 and turn >= 0.999 then
        c.mobility = nil
    else
        c.mobility = { speed = math.clamp(speed, 0.1, 1), turn = math.clamp(turn, 0.1, 1) }
    end
end

function Locomotion.SetAutopilot(c: Controller, target: { x: number, z: number, yaw: number }?)
    c.autopilot = target
end

chassisCFrame = function(s: any): CFrame
    return CFrame.new(s.x, s.y, s.z) * CFrame.Angles(0, s.yaw, 0) * CFrame.Angles(s.pitch, 0, s.roll)
end

-- The replicated hull pose is the chassis frame times the hull offset, so clients recover the chassis (ground-level root)
-- exactly with hull.CFrame * offset:Inverse().
function Locomotion.HullPose(p: any, s: any): CFrame
    return chassisCFrame(s) * CFrame.new(p.hull.offsetX, p.hull.offsetY, p.hull.offsetZ)
end

function Locomotion.ChassisCFrame(c: Controller): CFrame
    return chassisCFrame(c.state)
end

-- Advances one controller. Returns the drive events (bump, turnBlocked) and whether autopilot arrived.
function Locomotion.Step(c: Controller, dt: number): ({ [string]: any }, boolean)
    local started = os.clock()
    refreshFilter()
    local s = c.state
    local input = c.input
    local arrived = false
    local throttle, steer = input.throttle, input.steer
    if c.autopilot then
        local th, st, done = Drive.Autopilot(s, c.autopilot.x, c.autopilot.z, c.autopilot.yaw)
        throttle, steer, arrived = th, st, done
    elseif os.clock() - c.lastInput > Locomotion.INPUT_TIMEOUT then
        throttle, steer = 0, 0
    end
    local mob = c.mobility
    if mob then
        steer *= mob.turn
    end
    local ms = if mob then mob.speed else 1
    local events = {}
    local elapsed = math.clamp(dt, 0, 0.25)
    local steps = math.max(1, math.ceil(elapsed * 60))
    local h = elapsed / steps
    for _ = 1, steps do
        local base, boost = 1, 0
        if c.energySystems then
            local live = not input.locked or c.autopilot ~= nil
            local sprint = input.sprint == true and not c.autopilot and os.clock() - c.lastInput <= Locomotion.INPUT_TIMEOUT
            base, boost = EnergySystems.Step(c.energySystems, h, s, if live then throttle else 0, if live then steer else 0, sprint, live)
        end
        local balance = c.energySystems and c.energySystems.config.movement
        local e = Drive.Advance(s, { throttle = throttle, steer = steer, locked = input.locked and not c.autopilot,
            baseScale = base * ms, speedScale = base * ms * (1 + boost * ms * (balance and balance.sprintMultiplier - 1 or 0)),
            accelScale = base * ms * (1 + boost * ms * (balance and balance.sprintAcceleration - 1 or 0)),
        }, h, c.params, c.params2)
        if e.bump then events.bump = math.max(events.bump or 0, e.bump) end
        if e.turnBlocked then events.turnBlocked = true end
    end

    -- Void watchdog: a pose far below the world means something went badly wrong; the caller recovers it.
    if s.y < -60 then
        events.fellOut = true
    end

    -- Replicate only when the pose really changed.
    local cf = Locomotion.HullPose(c.params, s)
    local old = c.lastCF
    if (cf.Position - old.Position).Magnitude > 0.005 or (cf.LookVector - old.LookVector).Magnitude > 0.0004 or (cf.RightVector - old.RightVector).Magnitude > 0.0004 then
        c.hull.CFrame = cf
        c.lastCF = cf
    end
    -- Rounded attributes at most ~15 Hz, and only when they changed.
    local now = os.clock()
    if now - c.publishedAt >= 0.066 then
        local speed = math.floor(s.speed * 20 + 0.5) / 20
        local yawRate = math.floor(s.yawRate * 200 + 0.5) / 200
        local label = Drive.Classify(s, c.params)
        local pub = c.published
        if pub.speed ~= speed then
            c.model:SetAttribute("DriveSpeed", speed)
            pub.speed = speed
        end
        if pub.yawRate ~= yawRate then
            c.model:SetAttribute("DriveYawRate", yawRate)
            pub.yawRate = yawRate
        end
        if pub.state ~= label then
            c.model:SetAttribute("DriveState", label)
            pub.state = label
        end
        c.publishedAt = now
    end
    c.stats.stepMs += ((os.clock() - started) * 1000 - c.stats.stepMs) * 0.05
    c.stats.steps += 1
    return events, arrived
end

return Locomotion
