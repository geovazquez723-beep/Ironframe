-- Inputs share the server's per-player drive path in both camera modes.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Telemetry = require(ReplicatedStorage.IronframeShared.Telemetry)
local Profiles = require(ReplicatedStorage.IronframeShared.EnergyProfiles)
local Client = {}
function Client.Start(remotes, cameraMode, animator)
    local player = Players.LocalPlayer
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "IronframeDeploymentUI", false, 31
    gui.Parent = player.PlayerGui
    local text = Instance.new("TextLabel")
    text.Name = "DriveTelemetry"
    text.Size, text.Position = UDim2.new(0, 600, 0, 80), UDim2.new(0.5, -300, 1, -178)
    text.BackgroundColor3, text.BackgroundTransparency = Color3.fromRGB(12, 22, 28), 0.2
    text.TextColor3, text.TextSize, text.Font = Color3.fromRGB(150, 224, 231), 16, Enum.Font.Code
    text.Parent = gui
    local action = Instance.new("TextButton")
    action.Name, action.Size, action.Position = "DeployReturn", UDim2.fromOffset(270, 38), UDim2.new(1, -294, 0, 78)
    action.BackgroundColor3, action.TextColor3 = Color3.fromRGB(30, 46, 52), Color3.fromRGB(255, 178, 66)
    action.TextSize, action.Font, action.Parent = 15, Enum.Font.GothamBold, gui
    local deployment = "STOWED"
    local testModes, selected = { "LASER", "BALLISTIC", "PLASMA", "REAR_MISSILE" }, 1
    local function shield() remotes.RequestShield:FireServer() end
    local function testImpact() remotes.RequestEnergyTest:FireServer(testModes[selected]) end
    local function cycleTest() selected = selected % #testModes + 1 end
    local function testWeapon() remotes.RequestEnergyTest:FireServer("WEAPON_LOAD") end
    local function smallButton(name, y, callback)
        local b = Instance.new("TextButton")
        b.Name, b.Size, b.Position = name, UDim2.fromOffset(270,34), UDim2.new(1,-294,0,y)
        b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = Color3.fromRGB(22,37,46), Color3.fromRGB(134,222,244), Enum.Font.Code, 14
        b.Parent = gui
        b.MouseButton1Click:Connect(callback)
        return b
    end
    local function selectProfile(id) remotes.RequestEnergyProfile:FireServer(id) end
    local function cycleProfile() selectProfile(Profiles.Next(Telemetry.Value("energy.profile", Profiles.Default))) end
    -- Power-profile strip: always visible while piloting, so profiles never need a memorised shortcut.
    local strip = Instance.new("Frame")
    strip.Name, strip.Size, strip.Position = "PowerProfile", UDim2.fromOffset(270, 58), UDim2.new(1, -294, 0, 204)
    strip.BackgroundColor3, strip.BackgroundTransparency, strip.BorderSizePixel, strip.Parent = Color3.fromRGB(12, 22, 28), 0.15, 0, gui
    local stripTitle = Instance.new("TextLabel")
    stripTitle.Name, stripTitle.Size, stripTitle.Position = "Title", UDim2.new(1, -8, 0, 18), UDim2.fromOffset(6, 2)
    stripTitle.BackgroundTransparency, stripTitle.TextXAlignment, stripTitle.Font, stripTitle.TextSize = 1, Enum.TextXAlignment.Left, Enum.Font.Code, 12
    stripTitle.TextColor3, stripTitle.Text, stripTitle.Parent = Color3.fromRGB(134, 222, 244), "C  POWER PROFILE", strip
    local profileButtons = {}
    for i, id in ipairs(Profiles.Order) do
        local b = Instance.new("TextButton")
        b.Name, b.Size, b.Position, b.Text = id, UDim2.fromOffset(84, 30), UDim2.fromOffset(6 + (i - 1) * 88, 22), id
        b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize, b.AutoButtonColor, b.Parent = Color3.fromRGB(22, 37, 46), Color3.fromRGB(134, 222, 244), Enum.Font.Code, 12, true, strip
        local stroke = Instance.new("UIStroke")
        stroke.Thickness, stroke.Color, stroke.Parent = 1.5, Color3.fromRGB(70, 110, 124), b
        b.MouseButton1Click:Connect(function() selectProfile(id) end)
        profileButtons[id] = { button = b, stroke = stroke }
    end
    local shieldButton = smallButton("PulseShield", 122, shield)
    local testButton = smallButton("TestImpact", 162, testImpact)
    local report = Instance.new("TextLabel")
    report.Name, report.Size, report.Position = "EnergyTestReport", UDim2.fromOffset(620,42), UDim2.new(0.5,-310,0,135)
    report.BackgroundTransparency, report.TextWrapped = 1, true
    report.TextColor3, report.Font, report.TextSize, report.Parent = Color3.fromRGB(255,207,119), Enum.Font.Code, 15, gui
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
        if not processed and input.KeyCode == Enum.KeyCode.G then shield() end
        if not processed and input.KeyCode == Enum.KeyCode.H then testImpact() end
        if not processed and input.KeyCode == Enum.KeyCode.J then cycleTest() end
        if not processed and input.KeyCode == Enum.KeyCode.K then testWeapon() end
        if not processed and input.KeyCode == Enum.KeyCode.C then cycleProfile() end
        if not processed and input.KeyCode == Enum.KeyCode.X and cameraMode.Current() ~= "COCKPIT" then
            remotes.RequestTestEject:FireServer()
        end
    end)
    UIS.WindowFocusReleased:Connect(function() focused = false; override = nil; remotes.DriveInput:FireServer(0, 0) end)
    UIS.WindowFocused:Connect(function() focused = true end)
    local function axes()
        if deployment ~= "ACTIVE" or cameraMode.IsEvacuating() then return 0, 0, false end
        if override then return override[1], override[2], override[3] == true end
        if not focused or UIS:GetFocusedTextBox() then return 0, 0, false end
        local function key(k) return if UIS:IsKeyDown(k) then 1 else 0 end
        return key(Enum.KeyCode.W) - key(Enum.KeyCode.S), key(Enum.KeyCode.A) - key(Enum.KeyCode.D), UIS:IsKeyDown(Enum.KeyCode.LeftShift)
    end
    RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed < 0.08 then return end
        elapsed = 0
        local folder = workspace:FindFirstChild("IronframeMechs")
        local mech = folder and folder:FindFirstChild(tostring(player.UserId))
        deployment = mech and mech:GetAttribute("Deployment") or "EJECTED"
        local garageGui = player.PlayerGui:FindFirstChild("IronframeGarageUI")
        if garageGui then garageGui.StatsPanel.Visible = deployment == "STOWED" and cameraMode.Current() ~= "COCKPIT" end
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
        local attributes = {
            ["energy.charge"] = "EnergyCharge", ["energy.capacity"] = "EnergyCapacity", ["energy.output"] = "EnergyOutput",
            ["energy.demand"] = "EnergyDemand", ["energy.supply"] = "EnergySupply", ["energy.capRate"] = "EnergyCapRate",
            ["energy.thermal"] = "EnergyThermal", ["energy.propulsion"] = "EnergyPropulsion", ["energy.deficit"] = "EnergyDeficit",
            ["energy.weaponDemand"] = "EnergyWeaponDemand", ["energy.profile"] = "EnergyProfile", ["energy.profilePending"] = "EnergyProfilePending",
            ["energy.profileEta"] = "EnergyProfileEta", ["energy.profileSerial"] = "EnergyProfileSerial", ["energy.profileReason"] = "EnergyProfileReason",
            ["energy.focus"] = "EnergyFocus", ["energy.limited"] = "EnergyLimited", ["energy.weaponRate"] = "EnergyWeaponRate",
            ["energy.shieldDemand"] = "EnergyShieldDemand", ["energy.sprintDemand"] = "EnergySprintDemand", ["shield.state"] = "ShieldState", ["shield.cooldown"] = "ShieldCooldown",
            ["shield.integrity"] = "ShieldIntegrity", ["shield.reason"] = "ShieldReason", ["shield.timing"] = "ShieldLastTiming",
        }
        for key, attr in pairs(attributes) do
            local value = mech and mech:GetAttribute(attr)
            Telemetry.Publish(key, value, if value ~= nil then "LIVE" else "STANDBY")
        end
        local charge, capacity = Telemetry.Value("energy.charge",0), Telemetry.Value("energy.capacity",160)
        local activeProfile, pendingProfile = Telemetry.Value("energy.profile", ""), Telemetry.Value("energy.profilePending", "")
        strip.Visible = deployment == "ACTIVE"
        stripTitle.Text = if pendingProfile ~= "" then string.format("C  POWER PROFILE  >  %s %.1fs", pendingProfile, Telemetry.Value("energy.profileEta", 0))
            else "C  POWER PROFILE  " .. Telemetry.Value("energy.profileReason", "")
        for id, entry in pairs(profileButtons) do
            local on, pend = id == activeProfile, id == pendingProfile
            entry.stroke.Color = if on then Color3.fromRGB(255, 178, 66) elseif pend then Color3.fromRGB(134, 222, 244) else Color3.fromRGB(70, 110, 124)
            entry.button.TextColor3 = if on then Color3.fromRGB(255, 178, 66) else Color3.fromRGB(134, 222, 244)
            entry.button.BackgroundColor3 = if on then Color3.fromRGB(52, 40, 20) else Color3.fromRGB(22, 37, 46)
        end
        text.Visible = cameraMode.Current() ~= "COCKPIT" and not cameraMode.IsTransitioning()
        local shieldState = Telemetry.Value("shield.state","READY")
        shieldButton.Text = string.format("G  SHIELD %s  %.1fs",shieldState,Telemetry.Value("shield.cooldown",0))
        if shieldState == "READY" and charge < 25 then shieldButton.Text = "G  SHIELD UNAVAILABLE: CAP LOW" end
        if deployment ~= "ACTIVE" then shieldButton.Text = "G  SHIELD: DEPLOY FIRST" end
        testButton.Text = "H  " .. testModes[selected] .. " TEST  [J CYCLE]"
        report.Text = mech and mech:GetAttribute("EnergyTestReport") or ""
        local eta = mech and mech:GetAttribute("EnergyTestETA") or 0
        if eta > 0 then report.Text ..= string.format("  [%.1fs]",eta) end
        text.Text = string.format("%s | %s %.1f st/s | HDG %03d | CAP %.0f/%.0f\nTHERMAL %.0f%% | SHIELD %s | %s\nWASD Drive  SHIFT Sprint  C Profile  V View  X Eject  K Weapon-load SIM", deployment, direction, math.abs(speed), heading,charge,capacity,Telemetry.Value("energy.thermal",0),shieldState,Telemetry.Value("shield.reason",""))
        action.Text = if deployment == "STOWED" then (if cameraMode.Current() == "COCKPIT" then "F  DEPLOY / OPEN DOORS" else "F  ENTER COCKPIT") elseif deployment == "ACTIVE" then "F  RETURN TO HANGAR" else deployment
        local t, s, sprint = axes()
        remotes.DriveInput:FireServer(t, s, sprint)
    end)
    -- Client-only test interface: uses the same inputs/remotes, never bypasses server validation.
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeDeploymentControl"
    control.OnInvoke = function(command, a, b, sprint)
        if command == "input" then override = { a or 0, b or 0, sprint == true }
        elseif command == "shield" then shield()
        elseif command == "test" then remotes.RequestEnergyTest:FireServer(a or testModes[selected])
        elseif command == "release" then override = nil; remotes.DriveInput:FireServer(0, 0)
        elseif command == "action" then perform()
        elseif command == "profile" then selectProfile(a)
        elseif command == "cycleProfile" then cycleProfile()
        elseif command == "return" then remotes.RequestReturn:FireServer()
        elseif command == "eject" then remotes.RequestTestEject:FireServer()
        elseif command == "stats" then return { deployment = deployment, speed = Telemetry.Value("movement.speed"), heading = Telemetry.Value("movement.heading"), charge = Telemetry.Value("energy.charge"), demand = Telemetry.Value("energy.demand"), thermal = Telemetry.Value("energy.thermal"), shield = Telemetry.Value("shield.state"), cooldown = Telemetry.Value("shield.cooldown"), shieldTiming = Telemetry.Value("shield.timing") } end
        return nil
    end
    control.Parent = player.PlayerScripts
end
return Client
