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

local rigs = setmetatable({}, { __mode = "k" })
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
                    local world = MechRig.Apply(rig, root, angles)
                    torsoFrames[model] = world.Torso
                    model:SetAttribute("ShowroomTorsoYaw", angles.Torso) -- local-only diagnostic (Studio checklist)
                end
            end
        end
    end)
end

return ShowroomAnimator
