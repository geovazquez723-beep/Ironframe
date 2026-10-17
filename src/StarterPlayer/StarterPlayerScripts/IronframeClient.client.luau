local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("IronframeRemotes")
local getState = remotes:WaitForChild("GetGarageState")
local setPreset = remotes:WaitForChild("SetPreset")
local requestEject = remotes:WaitForChild("RequestTestEject")
local stateChanged = remotes:WaitForChild("StateChanged")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local Loadouts = require(Shared:WaitForChild("Loadouts"))

local gui = Instance.new("ScreenGui")
gui.Name = "IronframeGarageUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local function label(parent, name, text, size, pos, color, textSize)
    local item = Instance.new("TextLabel")
    item.Name = name
    item.Size = size
    item.Position = pos
    item.BackgroundTransparency = 1
    item.Text = text
    item.TextColor3 = color
    item.TextSize = textSize or 18
    item.Font = Enum.Font.Gotham
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.TextYAlignment = Enum.TextYAlignment.Top
    item.TextWrapped = true
    item.Parent = parent
    return item
end
local function button(parent, name, text, pos, action)
    local item = Instance.new("TextButton")
    item.Name = name
    item.Size = UDim2.fromOffset(280, 42)
    item.Position = pos
    item.BackgroundColor3 = Color3.fromRGB(42, 57, 68)
    item.TextColor3 = Color3.fromRGB(230, 241, 246)
    item.TextSize = 15
    item.Font = Enum.Font.GothamBold
    item.Text = text
    item.Parent = parent
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent = item
    item.MouseButton1Click:Connect(action)
    return item
end
local panel = Instance.new("Frame")
panel.Name = "StatsPanel"
panel.Size = UDim2.fromOffset(324, 585)
panel.Position = UDim2.new(0, 22, 0.5, -292)
panel.BackgroundColor3 = Color3.fromRGB(17, 24, 32)
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel
label(panel, "Brand", "IRONFRAME  /  GARAGE 01", UDim2.fromOffset(288, 28), UDim2.fromOffset(16, 16), Color3.fromRGB(255, 178, 66), 20)
local heading = label(panel, "Mech", "IF-42 BASTION", UDim2.fromOffset(288, 50), UDim2.fromOffset(16, 55), Color3.fromRGB(236, 245, 249), 19)
local stats = label(panel, "Stats", "Initializing mech telemetry...", UDim2.fromOffset(287, 140), UDim2.fromOffset(16, 103), Color3.fromRGB(172, 211, 224), 15)
label(panel, "LoadoutsLabel", "LOADOUT PRESETS", UDim2.fromOffset(288, 28), UDim2.fromOffset(16, 250), Color3.fromRGB(255, 178, 66), 15)
button(panel, "Balanced", "GENERAL PURPOSE", UDim2.fromOffset(18, 278), function() setPreset:FireServer("BALANCED") end)
button(panel, "Energy", "PLASMA SPECIALIST", UDim2.fromOffset(18, 324), function() setPreset:FireServer("ENERGY") end)
button(panel, "Missile", "MISSILE BARRAGE", UDim2.fromOffset(18, 370), function() setPreset:FireServer("MISSILE") end)
button(panel, "Eject", "TEST SAFE EJECTION", UDim2.fromOffset(18, 431), function() requestEject:FireServer() end)
local status = label(panel, "Status", "System nominal", UDim2.fromOffset(288, 25), UDim2.fromOffset(17, 478), Color3.fromRGB(255, 178, 66), 13)
local diag = label(panel, "Diagnostics", "", UDim2.fromOffset(288, 70), UDim2.fromOffset(17, 508), Color3.fromRGB(140, 200, 160), 12)
local tip = label(gui, "CameraTip", "RIGHT-DRAG  Orbit  •  MIDDLE-DRAG  Focus height  •  R  Reset view     •     SCROLL  Zoom     •     V  Cockpit view     •     Ejection always safe", UDim2.new(0.8, 0, 0, 30), UDim2.new(0, 364, 1, -46), Color3.fromRGB(230, 238, 241), 14)
tip.TextXAlignment = Enum.TextXAlignment.Center

local function display(data)
    if not data or not data.ready then
        status.Text = "Garage initializing..."
        return
    end
    local m = data.compiled.metrics
    local stowed = data.deployment == nil or data.deployment == "STOWED"
    for _, name in ipairs({ "Balanced", "Energy", "Missile" }) do
        panel[name].Active = stowed
        panel[name].AutoButtonColor = stowed
        panel[name].TextTransparency = if stowed then 0 else 0.55
    end
    -- Cockpit telemetry: authoritative server state republished on the bus (LIVE); subsystems that do not exist stay STANDBY.
    local loadout = Loadouts.presets[data.presetId]
    Telemetry.Publish("mech.preset", data.presetId)
    Telemetry.Publish("mech.presetOrder", data.presetOrder)
    Telemetry.Publish("mech.state", data.machineState)
    Telemetry.Publish("pilot.safe", data.pilotSafe)
    Telemetry.Publish("loadout.metrics", m)
    Telemetry.Publish("loadout.mounts", loadout and loadout.mounts or {})
    Telemetry.Publish("loadout.systems", loadout and loadout.systems or {})
    Telemetry.Publish("integrity.total", m.integrity)
    if data.diagnostics then
        Telemetry.Publish("diag.tests", data.diagnostics.tests)
        Telemetry.Publish("diag.rig", data.diagnostics.rig)
    end
    heading.Text = "IF-42 BASTION\n" .. data.presetName
    stats.Text = string.format(
        "MASS                 %.1f / %.1f t\nPOWER             %.0f / %.0f\nHEAT / COOL      %.1f / %.1f /s\nNOMINAL DPS    %.0f\nINTEGRITY          %.0f\nWEAPONS           %d / 6",
        m.mass, m.massLimit, m.powerDraw, m.powerOutput, m.heatPerSecond, m.coolingPerSecond,
        m.nominalDps, m.integrity, m.equippedWeapons
    )
    status.Text = data.message .. " [" .. data.machineState .. "]"
    local dg = data.diagnostics
    if dg then
        local t, r = dg.tests, dg.rig
        diag.Text = string.format("DIAGNOSTICS\nSELF-TEST  %d / %d %s\nRIG  %d parts (%d AI meshes)  %d joints  %d hydraulics\nSOCKETS  %d / %d    ARMOR PANELS  %d\nPILOT  %s",
            t.passed, t.total, (#t.failed == 0) and "PASS" or ("FAIL: " .. table.concat(t.failed, ", ")),
            r.parts, r.meshParts or 0, r.joints, r.links, r.socketsFilled, r.socketsTotal, r.armorPanels,
            data.pilotSafe and "SAFE / UNTARGETABLE" or "SAFE")
    end
    print(string.format("[IF-CLIENT] preset=%s mass=%.1f power=%.1f", data.presetId, m.mass, m.powerDraw))
end

stateChanged.OnClientEvent:Connect(display)
local ok, result = pcall(function() return getState:InvokeServer() end)
if ok then display(result) else warn("[IF-CLIENT] GetGarageState failed:", result) end

local GarageCamera = require(script.Parent:WaitForChild("GarageCamera"))
local AvatarHider = require(script.Parent:WaitForChild("AvatarHider"))
local ShowroomAnimator = require(script.Parent:WaitForChild("ShowroomAnimator"))
local CockpitMode = require(script.Parent:WaitForChild("CockpitMode"))

AvatarHider.Start()
-- Garage presentation: hide default chat/player list/backpack UI.
pcall(function() game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
ShowroomAnimator.Start()
GarageCamera.Start(function()
    local folder = workspace:FindFirstChild("IronframeMechs")
    local model = folder and folder:FindFirstChild(tostring(player.UserId))
    local base = model and ShowroomAnimator.ChassisCF(model)
    return base and base.Position or nil
end)
CockpitMode.Start({ garage = GarageCamera, animator = ShowroomAnimator, remotes = remotes })
require(script.Parent.BayClient).Start()
require(script.Parent.DeploymentClient).Start(remotes, CockpitMode, ShowroomAnimator)
require(script.Parent.ShieldClient).Start(ShowroomAnimator)

require(script.Parent.WeaponClient).Start(remotes, CockpitMode, ShowroomAnimator)
