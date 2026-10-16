-- Client-side cosmetic showroom animation. Poses every operational mech from the shared,
-- deterministic Showroom.Pose(serverTime). The server never reads this; stats and placement
-- are untouched. Parts are anchored and only moved via MechRig, so nothing can destabilise.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local MechRig = require(Shared:WaitForChild("MechRig"))
local Showroom = require(Shared:WaitForChild("Showroom"))

local ShowroomAnimator = {}

local rigs = setmetatable({}, { __mode = "k" })

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

function ShowroomAnimator.Start()
    RunService:BindToRenderStep("IronframeShowroom", Enum.RenderPriority.Camera.Value - 1, function()
        local folder = workspace:FindFirstChild("IronframeMechs")
        if not folder then return end
        local t = workspace:GetServerTimeNow()
        for _, model in ipairs(folder:GetChildren()) do
            local baseCF = model:GetAttribute("BaseCF")
            if baseCF and model:GetAttribute("State") == "OPERATIONAL" and model:GetAttribute("PartCount") then
                local rig = rigFor(model)
                if rig then
                    local angles, bob = Showroom.Pose(t, model:GetAttribute("OwnerUserId") or 0)
                    MechRig.Apply(rig, baseCF * CFrame.new(0, bob, 0), angles)
                    model:SetAttribute("ShowroomTorsoYaw", angles.Torso) -- local-only diagnostic (Studio checklist)
                end
            end
        end
    end)
end

return ShowroomAnimator
