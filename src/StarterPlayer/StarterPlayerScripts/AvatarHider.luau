-- Hides the local player's normal Roblox avatar during garage inspection. Purely client-side
-- and non-destructive: nothing is deleted, health is untouched, and Restore() undoes it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AvatarHider = {}

local player = Players.LocalPlayer
local hidden = true
local controlsDisabled = false

local function apply(character)
    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("BasePart") then
            d.LocalTransparencyModifier = hidden and 1 or 0
        elseif d:IsA("Decal") then
            d.Transparency = hidden and 1 or 0
        end
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.DisplayDistanceType = hidden and Enum.HumanoidDisplayDistanceType.None or Enum.HumanoidDisplayDistanceType.Viewer
    end
end

local function setControls(enabled)
    local ok, err = pcall(function()
        local moduleScript = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
        if not moduleScript then return end -- no default controls present (nothing to disable)
        local module = require(moduleScript)
        local controls = module:GetControls()
        if enabled then controls:Enable() else controls:Disable() end
    end)
    if not ok then warn("[IF-AVATAR] Could not toggle controls:", err) end
    controlsDisabled = not enabled
end

function AvatarHider.Start()
    task.spawn(setControls, false) -- the camera is scripted; walking an invisible avatar is confusing
    RunService.RenderStepped:Connect(function()
        local character = player.Character
        if character then apply(character) end
    end)
end

function AvatarHider.Restore()
    hidden = false
    if player.Character then apply(player.Character) end
    if controlsDisabled then setControls(true) end
end

return AvatarHider
