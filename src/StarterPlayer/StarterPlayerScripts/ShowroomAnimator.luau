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

local function rigFor(model)
    local entry = rigs[model]
    if not entry or entry.parts ~= model:GetAttribute("PartCount") then
        entry = { rig = MechRig.Bind(model), parts = model:GetAttribute("PartCount") }
        rigs[model] = entry
    end
    return entry.rig
end

function ShowroomAnimator.Start()
    RunService:BindToRenderStep("IronframeShowroom", Enum.RenderPriority.Camera.Value - 1, function()
        local folder = workspace:FindFirstChild("IronframeMechs")
        if not folder then return end
        local t = workspace:GetServerTimeNow()
        for _, model in ipairs(folder:GetChildren()) do
            local baseCF = model:GetAttribute("BaseCF")
            if baseCF and model:GetAttribute("State") == "OPERATIONAL" and model:GetAttribute("PartCount") then
                local angles, bob = Showroom.Pose(t, model:GetAttribute("OwnerUserId") or 0)
                MechRig.Apply(rigFor(model), baseCF * CFrame.new(0, bob, 0), angles)
            end
        end
    end)
end

return ShowroomAnimator
