-- Client-side cosmetic showroom animation. Poses every operational mech from the shared,
-- deterministic Showroom.Pose(serverTime). The server never reads this; stats and placement
-- are untouched. Parts are anchored and only moved via MechRig, so nothing can destabilise.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local MechRig = require(Shared:WaitForChild("MechRig"))
local Showroom = require(Shared:WaitForChild("Showroom"))
local Gait = require(Shared:WaitForChild("MechGait"))
local Chassis = require(Shared:WaitForChild("ChassisRegistry"))
local Audio = require(script.Parent.CockpitAudio)
local gaitStates = setmetatable({}, { __mode = "k" })
local chassisFrames = setmetatable({}, { __mode = "k" })

local ShowroomAnimator = {}

local RigSpec = require(Shared:WaitForChild("RigSpec"))

local rigs = setmetatable({}, { __mode = "k" })

-- M10C: enemy presentation (cosmetic, client only). ROOK-01 walks with the same gait as the Bastion; on top of that the client adds
--   * a hit flinch when the server's HitSerial changes,
--   * a terminal slump when the server stamps `Wreck` (core failure): the machine kneels and tips forward and stays down,
--   * indicator lamps / sensor window colours keyed on the replicated AI state.
local enemyStates = setmetatable({}, { __mode = "k" })
local WRECK = { angles = {
    ThighL = 1.2, KneeL = -2.15, AnkleL = 0.95, ThighR = 1.2, KneeR = -2.15, AnkleR = 0.95,
    Torso = 0.38, Head = -0.55, ShoulderL = -0.2, ElbowL = 0.2, ShoulderR = -0.25, ElbowR = 0.15,
} }
do
    local world = MechRig.Solve(CFrame.identity, WRECK.angles)
    local lowest = math.huge
    for _, joint in ipairs({ "KneeL", "KneeR", "AnkleL", "AnkleR" }) do
        lowest = math.min(lowest, world[joint].Position.Y)
    end
    WRECK.drop = lowest - 1.3
end
local LAMP_COLORS = {
    IDLE = Color3.fromRGB(255, 170, 60), ACQUIRE = Color3.fromRGB(255, 236, 190), APPROACH = Color3.fromRGB(255, 110, 50),
    ENGAGE = Color3.fromRGB(255, 70, 40), REPOSITION = Color3.fromRGB(255, 130, 50), DEFEND = Color3.fromRGB(80, 200, 255),
}

local function enemyPose(model: Model, root: CFrame, angles: { [string]: number }, dt: number): (CFrame, { [string]: number })
    local st = enemyStates[model]
    if not st then
        st = { flinch = 0, serial = model:GetAttribute("HitSerial") or 0, lamps = {}, eye = nil, side = 1 }
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and string.find(part.Name, "^RookLamp") then
                table.insert(st.lamps, part)
            elseif part.Name == "RookSensorEye" then
                st.eye = part
            end
        end
        enemyStates[model] = st
    end
    local serial = model:GetAttribute("HitSerial") or 0
    if serial ~= st.serial then
        st.serial, st.flinch, st.side = serial, 1, -st.side
    end
    if st.flinch > 0 then
        st.flinch = math.max(0, st.flinch - dt * 5)
        root = root * CFrame.Angles(-0.04 * st.flinch, 0, 0.02 * st.flinch * st.side)
        angles.Torso = (angles.Torso or 0) + 0.07 * st.flinch * st.side
    end
    local wreck = model:GetAttribute("Wreck")
    local f = 0
    if wreck then
        f = math.clamp((workspace:GetServerTimeNow() - wreck) / 1.4, 0, 1)
        f = 1 - (1 - f) * (1 - f)
        for joint, target in pairs(WRECK.angles) do
            local from = angles[joint] or RigSpec.JointsByName[joint].rest
            angles[joint] = from + (target - from) * f
        end
        root = root * CFrame.new(0, -WRECK.drop * f, 0) * CFrame.Angles(0.16 * f, 0, 0.05 * f)
    end
    -- Lamps: slow amber pulse on standby, white blink on contact, steady red in combat, cyan while the guard is up, dark when down.
    local state = model:GetAttribute("AiState") or "IDLE"
    local t = os.clock()
    local color, level
    if model:GetAttribute("Disabled") then
        color, level = Color3.fromRGB(40, 38, 36), 0
    else
        color = LAMP_COLORS[state] or LAMP_COLORS.IDLE
        level = if state == "IDLE" then 0.5 + 0.5 * math.sin(t * 2.2) elseif state == "ACQUIRE" then (if math.floor(t * 8) % 2 == 0 then 1 else 0.15) else 1
        if model:GetAttribute("RookStatus") == "STANDBY" then
            level *= 0.55
        end
    end
    for _, lamp in ipairs(st.lamps) do
        lamp.Color = color
        lamp.Transparency = 0.75 - 0.75 * level
    end
    if st.eye then
        st.eye.Color = if model:GetAttribute("Disabled") then Color3.fromRGB(30, 28, 28) else color:Lerp(Color3.fromRGB(255, 80, 30), 0.4)
        st.eye.Transparency = if model:GetAttribute("Disabled") then 0.8 elseif state == "IDLE" then 0.35 else 0
    end
    return root, angles
end
local torsoFrames = setmetatable({}, { __mode = "k" }) -- model -> world CFrame of the Torso joint after the latest pose

-- Parts stream in after the model and its PartCount attribute, so a bind taken too early is
-- incomplete. Keep rebinding (once per frame) until every part the server built is present, and
-- do not animate a partial model.
local function rigFor(model)
    local expected = model:GetAttribute("PartCount")
    local entry = rigs[model]
    if not entry or (not entry.complete) then
        local rig = MechRig.Bind(model)
        entry = { rig = rig, complete = (#rig.parts + #rig.linkParts) == expected }
        rigs[model] = entry
    end
    if entry.complete then
        return entry.rig
    end
    return nil
end

-- World frame of the model's animated Torso joint (the pilot's reference frame), nil until first posed.
function ShowroomAnimator.TorsoCF(model: Model): CFrame?
    return torsoFrames[model]
end

function ShowroomAnimator.ChassisCF(model: Model): CFrame?
    return chassisFrames[model] or model:GetAttribute("BaseCF")
end

function ShowroomAnimator.Start()
    RunService:BindToRenderStep("IronframeShowroom", Enum.RenderPriority.Camera.Value - 1, function(dt)
        local folder = workspace:FindFirstChild("IronframeMechs")
        if not folder then return end
        local t = workspace:GetServerTimeNow()
        for _, model in ipairs(folder:GetChildren()) do
            local baseCF = model:GetAttribute("BaseCF")
            if baseCF and model:GetAttribute("State") == "OPERATIONAL" and model:GetAttribute("PartCount") then
                local rig = rigFor(model)
                if rig then
                    local angles, bob = Showroom.Pose(t, model:GetAttribute("OwnerUserId") or 0)
                    local hull = model:FindFirstChild("Chassis")
                    local spec = Chassis[model:GetAttribute("ChassisId")]
                    local root = baseCF * CFrame.new(0, bob, 0)
                    if hull and spec then
                        local offset = spec.locomotion.hull
                        local authoritative = hull.CFrame * CFrame.new(offset.offsetX, offset.offsetY, offset.offsetZ):Inverse()
                        local g = gaitStates[model]
                        if not g then
                            g = { gait = Gait.New(), cf = authoritative, previous = authoritative }
                            gaitStates[model] = g
                        end
                        g.cf = g.cf:Lerp(authoritative, 1 - math.exp(-20 * dt))
                        -- Measure replicated displacement, including collisions, instead of animating requested input.
                        local delta = g.cf.Position - g.previous.Position
                        local _, yaw = g.previous:ToObjectSpace(g.cf):ToOrientation()
                        local v = delta:Dot(g.cf.LookVector) / math.max(dt, 0.001)
                        local w = yaw / math.max(dt, 0.001)
                        g.previous = g.cf
                        local pose, events
                        local steps = math.max(1, math.ceil(math.min(dt, 0.1) * 120))
                        for _ = 1, steps do
                            pose, events = Gait.Update(g.gait, math.min(dt, 0.1) / steps, v, w, spec.gait)
                            for _, event in ipairs(events) do
                                model:SetAttribute("Footsteps", g.gait.steps)
                                model:SetAttribute("LastFootfall", event.leg)
                                Audio.Footfall(g.cf:PointToWorldSpace(Vector3.new((if event.leg == "L" then -1 else 1) * spec.gait.hipHalfWidth, 0, -g.gait.legs[event.leg].f)), event.strength)
                            end
                        end
                        angles = pose.angles
                        angles.Hip, angles.Torso, angles.Head = pose.hipRoll, pose.torsoYaw, pose.headYaw
                        angles.ShoulderL, angles.ShoulderR = math.rad(6) + pose.shoulderL, math.rad(6) + pose.shoulderR
                        angles.ElbowL, angles.ElbowR = math.rad(50) + pose.elbowL, math.rad(50) + pose.elbowR
                        root = g.cf * CFrame.new(pose.sway, -pose.crouch - pose.dip, 0)
                        chassisFrames[model] = g.cf
                    else
                        gaitStates[model] = nil
                        chassisFrames[model] = baseCF
                    end
                    if angles and model:GetAttribute("EnemyId") then
                        root, angles = enemyPose(model, root, angles, math.min(dt, 0.1))
                    end
                    local world = MechRig.Apply(rig, root, angles)
                    torsoFrames[model] = world.Torso
                    model:SetAttribute("ShowroomTorsoYaw", angles.Torso) -- local-only diagnostic (Studio checklist)
                end
            end
        end
    end)
end

return ShowroomAnimator
