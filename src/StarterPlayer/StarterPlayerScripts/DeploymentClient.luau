-- Inputs share the server's per-player drive path in both camera modes.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Telemetry = require(ReplicatedStorage.IronframeShared.Telemetry)
local Client = {}
function Client.Start(remotes, cameraMode, animator)
    local player = Players.LocalPlayer
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "IronframeDeploymentUI", false, 31
    gui.Parent = player.PlayerGui
    local text = Instance.new("TextLabel")
    text.Name = "DriveTelemetry"
    text.Size, text.Position = UDim2.new(0, 530, 0, 62), UDim2.new(0.5, -265, 1, -160)
    text.BackgroundColor3, text.BackgroundTransparency = Color3.fromRGB(12, 22, 28), 0.2
    text.TextColor3, text.TextSize, text.Font = Color3.fromRGB(150, 224, 231), 16, Enum.Font.Code
    text.Parent = gui
    local action = Instance.new("TextButton")
    action.Name, action.Size, action.Position = "DeployReturn", UDim2.fromOffset(270, 38), UDim2.new(1, -294, 0, 78)
    action.BackgroundColor3, action.TextColor3 = Color3.fromRGB(30, 46, 52), Color3.fromRGB(255, 178, 66)
    action.TextSize, action.Font, action.Parent = 15, Enum.Font.GothamBold, gui
    local deployment = "STOWED"
    local focused, override, elapsed = true, nil, 0
    local function perform()
        if deployment == "STOWED" then
            if cameraMode.Current() ~= "COCKPIT" or cameraMode.IsTransitioning() then
                cameraMode.Toggle()
                return -- enter first; a second press initializes deployment
            end
            remotes.RequestDeploy:FireServer()
        elseif deployment == "ACTIVE" then remotes.RequestReturn:FireServer() end
    end
    action.MouseButton1Click:Connect(perform)
    UIS.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == Enum.KeyCode.F then perform() end
        if not processed and input.KeyCode == Enum.KeyCode.X and cameraMode.Current() ~= "COCKPIT" then
            remotes.RequestTestEject:FireServer()
        end
    end)
    UIS.WindowFocusReleased:Connect(function() focused = false; override = nil; remotes.DriveInput:FireServer(0, 0) end)
    UIS.WindowFocused:Connect(function() focused = true end)
    local function axes()
        if deployment ~= "ACTIVE" or cameraMode.IsEvacuating() then return 0, 0 end
        if override then return override[1], override[2] end
        if not focused or UIS:GetFocusedTextBox() then return 0, 0 end
        local function key(k) return if UIS:IsKeyDown(k) then 1 else 0 end
        return key(Enum.KeyCode.W) - key(Enum.KeyCode.S), key(Enum.KeyCode.A) - key(Enum.KeyCode.D)
    end
    RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed < 0.08 then return end
        elapsed = 0
        local folder = workspace:FindFirstChild("IronframeMechs")
        local mech = folder and folder:FindFirstChild(tostring(player.UserId))
        deployment = mech and mech:GetAttribute("Deployment") or "EJECTED"
        local speed = mech and mech:GetAttribute("DriveSpeed") or 0
        local drive = mech and mech:GetAttribute("DriveState") or "IDLE"
        local cf = mech and animator.ChassisCF(mech)
        local heading = cf and math.deg(math.atan2(cf.LookVector.X, -cf.LookVector.Z)) % 360 or 0
        local direction = if math.abs(speed) < 0.15 then "STOP" elseif speed > 0 then "FORWARD" else "REVERSE"
        Telemetry.Publish("movement.speed", speed)
        Telemetry.Publish("movement.heading", heading)
        Telemetry.Publish("movement.direction", direction)
        Telemetry.Publish("movement.drive", drive)
        Telemetry.Publish("deployment.state", deployment)
        Telemetry.Publish("reactor.state", mech and mech:GetAttribute("ReactorState") or "SHUTDOWN")
        text.Text = string.format("%s | %s | %s %.1f st/s | HDG %03d\nW/S Drive  A/D Steer  V View  X Eject | EXIT: HDG 180", deployment, drive, direction, math.abs(speed), heading)
        action.Text = if deployment == "STOWED" then (if cameraMode.Current() == "COCKPIT" then "F  DEPLOY / OPEN DOORS" else "F  ENTER COCKPIT") elseif deployment == "ACTIVE" then "F  RETURN TO HANGAR" else deployment
        local t, s = axes()
        remotes.DriveInput:FireServer(t, s)
    end)
    -- Client-only test interface: uses the same inputs/remotes, never bypasses server validation.
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeDeploymentControl"
    control.OnInvoke = function(command, a, b)
        if command == "input" then override = { a or 0, b or 0 }
        elseif command == "release" then override = nil; remotes.DriveInput:FireServer(0, 0)
        elseif command == "action" then perform()
        elseif command == "return" then remotes.RequestReturn:FireServer()
        elseif command == "eject" then remotes.RequestTestEject:FireServer()
        elseif command == "stats" then return { deployment = deployment, speed = Telemetry.Value("movement.speed"), heading = Telemetry.Value("movement.heading") } end
        return nil
    end
    control.Parent = player.PlayerScripts
end
return Client
