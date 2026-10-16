local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("IronframeRemotes")
local getState = remotes:WaitForChild("GetGarageState")
local setPreset = remotes:WaitForChild("SetPreset")
local requestEject = remotes:WaitForChild("RequestTestEject")
local stateChanged = remotes:WaitForChild("StateChanged")

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
panel.Size = UDim2.fromOffset(324, 505)
panel.Position = UDim2.new(0, 22, 0.5, -252)
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
local tip = label(gui, "CameraTip", "RIGHT-DRAG  Orbit camera     •     SCROLL  Zoom     •     Ejection always safe", UDim2.new(0.8, 0, 0, 30), UDim2.new(0, 364, 1, -46), Color3.fromRGB(230, 238, 241), 14)
tip.TextXAlignment = Enum.TextXAlignment.Center

local function display(data)
    if not data or not data.ready then
        status.Text = "Garage initializing..."
        return
    end
    local m = data.compiled.metrics
    heading.Text = "IF-42 BASTION\n" .. data.presetName
    stats.Text = string.format(
        "MASS                 %.1f / %.1f t\nPOWER             %.0f / %.0f\nHEAT / COOL      %.1f / %.1f /s\nNOMINAL DPS    %.0f\nINTEGRITY          %.0f\nWEAPONS           %d / 6",
        m.mass, m.massLimit, m.powerDraw, m.powerOutput, m.heatPerSecond, m.coolingPerSecond,
        m.nominalDps, m.integrity, m.equippedWeapons
    )
    status.Text = data.message .. " [" .. data.machineState .. "]"
    print(string.format("[IF-CLIENT] preset=%s mass=%.1f power=%.1f", data.presetId, m.mass, m.powerDraw))
end

stateChanged.OnClientEvent:Connect(display)
local ok, result = pcall(function() return getState:InvokeServer() end)
if ok then display(result) else warn("[IF-CLIENT] GetGarageState failed:", result) end

local orbitYaw = math.rad(155)
local orbitPitch = math.rad(12)
local zoom = 34
local drag = false
UserInputService.InputBegan:Connect(function(input, _processed)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        drag = true
        print("[IF-CAMERA] Orbit drag started")
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then drag = false end
end)
UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        zoom = math.clamp(zoom - input.Position.Z * 3, 22, 62)
    elseif drag and input.UserInputType == Enum.UserInputType.MouseMovement then
        orbitYaw -= input.Delta.X * 0.008
        orbitPitch = math.clamp(orbitPitch - input.Delta.Y * 0.004, math.rad(-9), math.rad(36))
    end
end)

RunService:BindToRenderStep("IronframeGarageCamera", Enum.RenderPriority.Camera.Value + 1, function()
    local folder = workspace:FindFirstChild("IronframeMechs")
    local model = folder and folder:FindFirstChild(tostring(player.UserId))
    if not model then return end
    local target = model:GetPivot().Position + Vector3.new(0, 9, 0)
    local vector = Vector3.new(math.sin(orbitYaw)*math.cos(orbitPitch), math.sin(orbitPitch), math.cos(orbitYaw)*math.cos(orbitPitch))
    local camera = workspace.CurrentCamera
    if camera then
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = CFrame.lookAt(target + vector*zoom, target)
        camera.FieldOfView = 50
    end
end)
