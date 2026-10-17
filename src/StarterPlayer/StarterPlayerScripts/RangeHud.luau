-- Range control panel (M10A): live training statistics and the three reset commands. Presentation only: the numbers are the
-- server's district attributes, and every command is a validated remote request. Vocabulary is machinery-only (TARGET DISABLED,
-- VEHICLE DESTROYED, SECTION BREACHED) - never casualties.
--
-- Visible while the pilot is deployed (ACTIVE) and inside the testing district (mech attribute RangeZone == "DISTRICT").
-- In the cockpit view hold ALT to free the cursor, or use the B hotkey (reset all).

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.IronframeShared.DestructionConfig)

local Hud = {}

local AMBER = Color3.fromRGB(255, 178, 66)
local CYAN = Color3.fromRGB(134, 222, 244)
local PANEL = Color3.fromRGB(12, 22, 28)

local function comma(n: number): string
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

function Hud.Start(remotes, cameraMode)
    local player = Players.LocalPlayer
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "IronframeRangeUI", false, 33
    gui.Parent = player:WaitForChild("PlayerGui")

    local panel = Instance.new("Frame")
    panel.Name = "RangePanel"
    panel.Size, panel.Position = UDim2.fromOffset(318, 322), UDim2.fromOffset(22, 96)
    panel.BackgroundColor3, panel.BackgroundTransparency, panel.BorderSizePixel = PANEL, 0.12, 0
    panel.Visible = false
    panel.Parent = gui
    local stroke = Instance.new("UIStroke")
    stroke.Color, stroke.Thickness, stroke.Transparency = Color3.fromRGB(70, 110, 124), 1.5, 0.2
    stroke.Parent = panel

    local function label(name: string, text: string, y: number, h: number, color: Color3, size: number)
        local l = Instance.new("TextLabel")
        l.Name, l.Text = name, text
        l.Size, l.Position = UDim2.fromOffset(300, h), UDim2.fromOffset(9, y)
        l.BackgroundTransparency, l.TextColor3, l.Font, l.TextSize = 1, color, Enum.Font.Code, size
        l.TextXAlignment, l.TextYAlignment, l.TextWrapped = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top, true
        l.Parent = panel
        return l
    end
    label("Title", "RANGE CONTROL  /  DESTRUCTION DISTRICT", 6, 20, AMBER, 14)
    local damage = label("Damage", "", 30, 52, CYAN, 14)
    local targets = label("Targets", "", 84, 52, CYAN, 14)
    local structures = label("Structures", "", 138, 52, CYAN, 14)
    local hint = label("Hint", "B  RESET ALL   |   ALT: free cursor in cockpit", 296, 20, Color3.fromRGB(150, 176, 186), 12)

    local function button(text: string, y: number, kind: string)
        local b = Instance.new("TextButton")
        b.Name, b.Text = kind, text
        b.Size, b.Position = UDim2.fromOffset(300, 30), UDim2.fromOffset(9, y)
        b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = Color3.fromRGB(22, 37, 46), AMBER, Enum.Font.GothamBold, 13
        b.AutoButtonColor = true
        b.Parent = panel
        local s = Instance.new("UIStroke")
        s.Color, s.Thickness = Color3.fromRGB(70, 110, 124), 1.2
        s.Parent = b
        b.MouseButton1Click:Connect(function()
            remotes.RequestRangeReset:FireServer(kind)
        end)
        return b
    end
    button("RESET ENTIRE DISTRICT", 192, "ALL")
    button("REPAIR + RESPAWN VEHICLES", 226, "VEHICLES")
    button("RESTORE STRUCTURES", 260, "STRUCTURES")
    hint.Position = UDim2.fromOffset(9, 296)
    panel.Size = UDim2.fromOffset(318, 322)

    -- Notices (toast stack, top centre): TARGET DISABLED, VEHICLE DESTROYED, WALL BREACHED ...
    local toastFrame = Instance.new("Frame")
    toastFrame.Name = "Notices"
    toastFrame.Size, toastFrame.Position, toastFrame.AnchorPoint = UDim2.fromOffset(520, 110), UDim2.new(0.5, 0, 0, 74), Vector2.new(0.5, 0)
    toastFrame.BackgroundTransparency = 1
    toastFrame.Parent = gui
    local toasts = {}
    local function relayout()
        for i, t in ipairs(toasts) do
            t.label.Position = UDim2.fromOffset(0, (i - 1) * 26)
        end
    end
    function Hud.Notice(text: string)
        local l = Instance.new("TextLabel")
        l.Size, l.BackgroundColor3, l.BackgroundTransparency = UDim2.fromOffset(520, 24), PANEL, 0.2
        l.TextColor3, l.Font, l.TextSize, l.Text = AMBER, Enum.Font.Code, 15, text
        l.BorderSizePixel = 0
        l.Parent = toastFrame
        table.insert(toasts, { label = l, born = os.clock() })
        while #toasts > Config.client.maxNotices do
            toasts[1].label:Destroy()
            table.remove(toasts, 1)
        end
        relayout()
    end

    local district, lastFind = nil, 0
    local function findDistrict()
        local hangar = workspace:FindFirstChild("IronframeHangar")
        if not hangar then
            return nil
        end
        for _, bay in ipairs(hangar:GetChildren()) do
            local ground = bay:FindFirstChild("ProvingGround")
            local d = ground and ground:FindFirstChild("TestingDistrict")
            if d and d:GetAttribute("OwnerUserId") == player.UserId then
                return d
            end
        end
        return nil
    end

    local elapsed = 0
    RunService.Heartbeat:Connect(function(dt)
        local clock = os.clock()
        for i = #toasts, 1, -1 do
            local t = toasts[i]
            local age = clock - t.born
            if age > 5 then
                t.label:Destroy()
                table.remove(toasts, i)
                relayout()
            elseif age > 4 then
                t.label.TextTransparency = (age - 4)
                t.label.BackgroundTransparency = 0.2 + (age - 4) * 0.8
            end
        end
        elapsed += dt
        if elapsed < 0.15 then
            return
        end
        elapsed = 0
        local folder = workspace:FindFirstChild("IronframeMechs")
        local mech = folder and folder:FindFirstChild(tostring(player.UserId))
        local live = mech ~= nil and mech:GetAttribute("Deployment") == "ACTIVE" and mech:GetAttribute("RangeZone") == "DISTRICT"
        panel.Visible = live
        toastFrame.Visible = mech ~= nil and mech:GetAttribute("Deployment") == "ACTIVE"
        if not live then
            return
        end
        if (not district or not district.Parent) and clock - lastFind > 1 then
            lastFind = clock
            district = findDistrict()
        end
        if not district then
            return
        end
        local function a(name: string): number
            return district:GetAttribute(name) or 0
        end
        damage.Text = string.format("DAMAGE INFLICTED  %s\nMG-9 %s | LR-12 %s | HMG-20 %s", comma(a("StatDamage")), comma(a("StatDamageMG")), comma(a("StatDamageLR")), comma(a("StatDamageHMG")))
        targets.Text = string.format("TARGETS DISABLED  %d / %d\nVEHICLES DESTROYED %d / %d | COMPONENTS LOST %d", a("StatTargetsDisabled"), a("StatTargetsTotal"), a("StatVehiclesDestroyed"), a("StatVehiclesTotal"), a("StatComponentsLost"))
        structures.Text = string.format("STRUCTURE SECTIONS  %d / %d\nWALLS BREACHED %d / %d | COLLAPSES %d", a("StatSections"), a("StatSectionsTotal"), a("StatWallsBreached"), a("StatWallsTotal"), a("StatCollapses"))
        stroke.Color = if district:GetAttribute("StatResetting") then AMBER else Color3.fromRGB(70, 110, 124)
    end)

    UIS.InputBegan:Connect(function(input, processed)
        if processed or UIS:GetFocusedTextBox() then
            return
        end
        if input.KeyCode == Enum.KeyCode.B and panel.Visible then
            remotes.RequestRangeReset:FireServer("ALL")
        end
    end)

    local control = Instance.new("BindableFunction")
    control.Name = "IronframeRangeControl"
    control.OnInvoke = function(command, kind)
        if command == "reset" then
            remotes.RequestRangeReset:FireServer(kind or "ALL")
        elseif command == "state" then
            return { visible = panel.Visible, damage = damage.Text, targets = targets.Text, structures = structures.Text, toasts = #toasts }
        end
        return nil
    end
    control.Parent = player.PlayerScripts
    return Hud
end

return Hud
