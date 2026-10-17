-- Combat telemetry (M10B): concise cockpit alerts for incoming fire, tank targeting, shield results and component condition.
-- Presentation only. Sources are server-authoritative: the CombatFx events (fire / end), tank attributes (AiState ...) and the
-- Bastion's published damage attributes (Dmg_*). Published to the Telemetry bus too, so the Structure MFD shows the same data.
--
-- Deliberately not an arcade HUD: nothing sits in the forward view except two small, short-lived markers.
--   top centre   one threat line + up to three alert lines (small type, fade out)
--   around reticle  a thin timing ring that closes on the best moment to raise the shield + up to three bearing chevrons
--   bottom left  six hair-thin condition bars (CORE, L/R WEAPON ASSY, L/R LEG, REACTOR)
--   screen edge  a brief gold / cyan / red edge flash on a shield result or a penetrating hit

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local Damage = require(Shared:WaitForChild("MechDamage"))
local Config = require(Shared:WaitForChild("CombatConfig"))
local Math = require(Shared:WaitForChild("CombatMath"))
local Components = require(Shared:WaitForChild("ComponentRegistry"))
local Audio = require(script.Parent:WaitForChild("CockpitAudio"))

local CombatHud = {}

local AMBER = Color3.fromRGB(255, 178, 66)
local CYAN = Color3.fromRGB(134, 222, 244)
local RED = Color3.fromRGB(255, 76, 58)
local GOLD = Color3.fromRGB(255, 214, 120)
local WHITE = Color3.fromRGB(226, 238, 242)
local PANEL = Color3.fromRGB(10, 18, 24)
local STAGE_COLOR = { OK = CYAN, DAMAGED = AMBER, CRITICAL = RED, FAILED = Color3.fromRGB(150, 36, 30) }
local LABEL = { CORE = "CORE", ARM_L = "L WPN", ARM_R = "R WPN", LEG_L = "L LEG", LEG_R = "R LEG", REACTOR = "RCTR" }
local HARDPOINTS = { ARM_L = "HARDPOINTS 1 + 3", ARM_R = "HARDPOINTS 2 + 4" }

local PERFECT_LEAD = Components.SHIELD_PULSE.chargeTime + Components.SHIELD_PULSE.perfectTime / 2 -- press this long before impact

function CombatHud.Start(remotes, cameraMode)
    local player = Players.LocalPlayer
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "IronframeCombatHud", false, 25, true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = player:WaitForChild("PlayerGui")
    local scale = Instance.new("UIScale")
    scale.Parent = gui

    local function text(parent: Instance, name: string, size: UDim2, pos: UDim2, color: Color3, textSize: number, align: Enum.TextXAlignment?): TextLabel
        local l = Instance.new("TextLabel")
        l.Name, l.Size, l.Position = name, size, pos
        l.BackgroundTransparency, l.TextColor3, l.Font, l.TextSize = 1, color, Enum.Font.Code, textSize
        l.TextXAlignment = align or Enum.TextXAlignment.Center
        l.TextYAlignment = Enum.TextYAlignment.Top
        l.Text = ""
        l.Parent = parent
        return l
    end

    -- Threat line + alert feed ------------------------------------------------------------------------------------------------
    local top = Instance.new("Frame")
    top.Name, top.AnchorPoint, top.Position, top.Size = "Alerts", Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 178), UDim2.fromOffset(640, 120)
    top.BackgroundTransparency = 1
    top.Parent = gui
    local threatLine = text(top, "Threat", UDim2.fromOffset(640, 22), UDim2.fromOffset(0, 0), AMBER, 17)
    threatLine.Font = Enum.Font.RobotoMono
    local feed: { TextLabel } = {}
    for i = 1, 3 do
        feed[i] = text(top, "Alert" .. i, UDim2.fromOffset(640, 20), UDim2.fromOffset(0, 24 + (i - 1) * 21), WHITE, 15)
        feed[i].TextTransparency = 1
    end
    local alerts: { { text: string, color: Color3, born: number, key: string } } = {}
    local function alert(msg: string, color: Color3, key: string?)
        local now = os.clock()
        for _, a in ipairs(alerts) do
            if key and a.key == key and now - a.born < 1.2 then
                return
            end
        end
        table.insert(alerts, 1, { text = msg, color = color, born = now, key = key or msg })
        while #alerts > 3 do
            table.remove(alerts)
        end
    end

    -- Timing ring and bearing chevrons ----------------------------------------------------------------------------------------
    local ring = Instance.new("Frame")
    ring.Name, ring.AnchorPoint, ring.Position, ring.BackgroundTransparency = "GuardRing", Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), 1
    ring.Visible = false
    ring.Parent = gui
    local ringCorner = Instance.new("UICorner")
    ringCorner.CornerRadius = UDim.new(1, 0)
    ringCorner.Parent = ring
    local ringStroke = Instance.new("UIStroke")
    ringStroke.Thickness, ringStroke.Color = 2, AMBER
    ringStroke.Parent = ring
    local ringLabel = text(gui, "GuardLabel", UDim2.fromOffset(300, 22), UDim2.new(0.5, -150, 0.5, 60), GOLD, 18)
    ringLabel.Font = Enum.Font.RobotoMono
    local chevrons: { Frame } = {}
    for i = 1, 3 do
        local c = Instance.new("Frame")
        c.Name, c.AnchorPoint, c.Size, c.BorderSizePixel = "Chevron" .. i, Vector2.new(0.5, 0.5), UDim2.fromOffset(18, 18), 0
        c.BackgroundColor3, c.Visible = RED, false
        c.Rotation = 45
        c.Parent = gui
        chevrons[i] = c
    end

    -- Edge flash -------------------------------------------------------------------------------------------------------------------
    local edges: { Frame } = {}
    for _, spec in ipairs({ { UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, 36), 90 }, { UDim2.new(0, 0, 1, -36), UDim2.new(1, 0, 0, 36), 270 }, { UDim2.fromScale(0, 0), UDim2.new(0, 36, 1, 0), 0 }, { UDim2.new(1, -36, 0, 0), UDim2.new(0, 36, 1, 0), 180 } }) do
        local f = Instance.new("Frame")
        f.Position, f.Size, f.BorderSizePixel, f.BackgroundColor3, f.BackgroundTransparency, f.Visible = spec[1], spec[2], 0, RED, 1, false
        local g = Instance.new("UIGradient")
        g.Rotation = spec[3]
        g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
        g.Parent = f
        f.Parent = gui
        table.insert(edges, f)
    end
    local flash = { color = RED, born = -10, strength = 0 }
    local function flashEdges(color: Color3, strength: number)
        flash.color, flash.born, flash.strength = color, os.clock(), strength
    end

    -- Condition strip ---------------------------------------------------------------------------------------------------------
    local strip = Instance.new("Frame")
    strip.Name, strip.AnchorPoint, strip.Position, strip.Size = "Condition", Vector2.new(0, 1), UDim2.new(0, 22, 1, -64), UDim2.fromOffset(190, 122)
    strip.BackgroundColor3, strip.BackgroundTransparency, strip.BorderSizePixel = PANEL, 0.45, 0
    strip.Visible = false
    strip.Parent = gui
    text(strip, "Title", UDim2.fromOffset(180, 14), UDim2.fromOffset(6, 3), Color3.fromRGB(120, 160, 172), 11, Enum.TextXAlignment.Left).Text = "BASTION CONDITION"
    local bars: { [string]: { fill: Frame, label: TextLabel } } = {}
    for i, region in ipairs(Damage.Regions) do
        local y = 20 + (i - 1) * 16
        local label = text(strip, "L" .. region, UDim2.fromOffset(58, 14), UDim2.fromOffset(6, y), WHITE, 12, Enum.TextXAlignment.Left)
        label.Text = LABEL[region]
        local back = Instance.new("Frame")
        back.Size, back.Position, back.BackgroundColor3, back.BackgroundTransparency, back.BorderSizePixel = UDim2.fromOffset(98, 6), UDim2.fromOffset(64, y + 4), Color3.fromRGB(30, 44, 52), 0.2, 0
        back.Parent = strip
        local fill = Instance.new("Frame")
        fill.Name, fill.Size, fill.BackgroundColor3, fill.BorderSizePixel = "Fill", UDim2.fromScale(1, 1), CYAN, 0
        fill.Parent = back
        local pct = text(strip, "P" .. region, UDim2.fromOffset(28, 14), UDim2.fromOffset(160, y), WHITE, 11, Enum.TextXAlignment.Right)
        bars[region] = { fill = fill, label = pct }
    end

    -- State ---------------------------------------------------------------------------------------------------------------------
    local fx: any = nil
    local damageFx: any = nil
    local api = {}
    function api.SetFx(value)
        fx = value
    end
    function api.SetDamageFx(value)
        damageFx = value
    end
    local lastFireAlert = -10
    function api.OnFire(e)
        if os.clock() - lastFireAlert > 0.3 then
            lastFireAlert = os.clock()
            Audio.Blip(if e.heavy then 0.8 else 1.4)
        end
    end
    local function facingBearing(chassis: CFrame, p: Vector3): number
        local yaw = math.atan2(-chassis.LookVector.X, -chassis.LookVector.Z)
        local d = p - chassis.Position
        return Math.relativeBearing(yaw, d.X, d.Z)
    end
    local function describeBearing(b: number): string
        local a = math.abs(b)
        return if a < 25 then "AHEAD" elseif a < 70 then (if b < 0 then "FRONT-LEFT" else "FRONT-RIGHT") elseif a < 115 then (if b < 0 then "LEFT" else "RIGHT") elseif a < 155 then (if b < 0 then "REAR-LEFT" else "REAR-RIGHT") else "REAR"
    end
    function api.OnEnd(e)
        if damageFx then
            damageFx.OnHit(e)
        end
        if e.why ~= "MECH" then
            return
        end
        local name = Config.mech.names[e.region] or e.region
        if e.timing == "PERFECT" then
            alert(string.format("PERFECT GUARD  BLOCKED %d  /  PENETRATED %d  [%s]", e.prevented + 0.5, e.pen + 0.5, name), GOLD, "hit")
            flashEdges(GOLD, 0.55)
        elseif e.timing == "GUARD" then
            alert(string.format("SHIELD GUARD  BLOCKED %d  /  PENETRATED %d  [%s]", e.prevented + 0.5, e.pen + 0.5, name), CYAN, "hit")
            flashEdges(CYAN, 0.5)
        elseif e.timing == "OFF_AXIS" then
            alert(string.format("SHIELD OFF-AXIS  NO MITIGATION  -%d  [%s]", e.pen + 0.5, name), RED, "hit")
            flashEdges(RED, 0.8)
        else
            alert(string.format("UNSHIELDED HIT  -%d  [%s]", e.pen + 0.5, name), RED, "hit")
            flashEdges(RED, 0.9)
        end
    end

    -- Per-frame ---------------------------------------------------------------------------------------------------------------------
    local previousStage: { [string]: string } = {}
    local previousState: { [Model]: string } = setmetatable({}, { __mode = "k" }) :: any
    local lastTelemetry = 0

    local function findMech(): Model?
        local folder = workspace:FindFirstChild("IronframeMechs")
        return folder and folder:FindFirstChild(tostring(player.UserId)) :: Model?
    end
    local function findDistrict(): Instance?
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
    local district: Instance? = nil
    local districtAt = -10

    local function updateCondition(mech: Model, now: number)
        local fractions = {}
        for _, region in ipairs(Damage.Regions) do
            local f = mech:GetAttribute("Dmg_" .. region) or 1
            fractions[region] = f
            local stage = Damage.Stage(f)
            local bar = bars[region]
            bar.fill.Size = UDim2.fromScale(f, 1)
            bar.fill.BackgroundColor3 = STAGE_COLOR[stage]
            bar.label.Text = string.format("%d", math.floor(f * 100 + 0.5))
            bar.label.TextColor3 = STAGE_COLOR[stage]
            local old = previousStage[region]
            previousStage[region] = stage
            if old and old ~= stage then
                local speed = math.floor((mech:GetAttribute("DmgSpeedFactor") or 1) * 100 + 0.5)
                local reactor = math.floor((mech:GetAttribute("DmgReactorFactor") or 1) * 100 + 0.5)
                local name = Config.mech.names[region]
                if stage == "OK" then
                    continue
                end
                if region == "CORE" then
                    if stage == "FAILED" then
                        alert("CORE FAILURE - EMERGENCY EJECTION", RED, "core")
                    elseif stage == "CRITICAL" then
                        alert("STRUCTURAL: CORE CRITICAL - EJECTION IMMINENT", RED, "core")
                    else
                        alert("STRUCTURAL: CORE DAMAGED", AMBER, "core")
                    end
                elseif region == "ARM_L" or region == "ARM_R" then
                    if stage == "FAILED" then
                        alert(string.format("%s OFFLINE - %s DISABLED", name, HARDPOINTS[region]), RED, region)
                    else
                        alert(string.format("%s %s", name, stage), AMBER, region)
                    end
                elseif region == "REACTOR" then
                    alert(string.format("REACTOR HOUSING %s - OUTPUT %d%%", stage, reactor), if stage == "DAMAGED" then AMBER else RED, region)
                else
                    alert(string.format("%s %s - DRIVE %d%%", name, stage, speed), if stage == "DAMAGED" then AMBER else RED, region)
                end
            end
        end
        if now - lastTelemetry > 0.2 then
            lastTelemetry = now
            Telemetry.Publish("damage.regions", fractions)
            Telemetry.Publish("damage.speed", mech:GetAttribute("DmgSpeedFactor") or 1)
            Telemetry.Publish("damage.reactor", mech:GetAttribute("DmgReactorFactor") or 1)
            Telemetry.Publish("damage.disabled", mech:GetAttribute("DmgDisabledSockets") or "")
            Telemetry.Publish("combat.lastHit", mech:GetAttribute("LastHitTiming") or "")
        end
    end

    RunService.RenderStepped:Connect(function(dt)
        local camera = workspace.CurrentCamera
        if camera then
            local size = camera.ViewportSize
            scale.Scale = math.clamp(math.min(size.Y / 1080, size.X / 1600), 0.6, 1.7)
            top.Position = UDim2.new(0.5, 0, 0, 262 / scale.Scale) -- always 262 px from the top: clear of the cockpit status and energy-report lines
        end
        local now = os.clock()
        local mech = findMech()
        local live = mech ~= nil and mech:GetAttribute("Deployment") == "ACTIVE" and mech:GetAttribute("State") == "OPERATIONAL"
        local inCockpit = cameraMode.Current() == "COCKPIT"
        top.Visible, strip.Visible = live, live and not inCockpit -- the cockpit's STRUCTURE display already shows condition
        if not live or not mech or not camera then
            ring.Visible, ringLabel.Text = false, ""
            for _, c in ipairs(chevrons) do
                c.Visible = false
            end
            for _, f in ipairs(edges) do
                f.Visible = false
            end
            return
        end
        if now - districtAt > 1 and (not district or not district.Parent) then
            districtAt = now
            district = findDistrict()
        end
        updateCondition(mech, now)

        -- Hostile tanks: targeting state and incoming shells
        local chassis = mech:FindFirstChild("Chassis") :: BasePart?
        local center = chassis and chassis.Position or camera.CFrame.Position
        local targeted: { text: string, f: number }? = nil
        local targets = {}
        if district then
            for _, model in ipairs(district:GetChildren()) do
                if model:IsA("Model") and model:GetAttribute("AiType") then
                    local state = model:GetAttribute("AiState") or "IDLE"
                    table.insert(targets, string.format("%s %s %s", model:GetAttribute("VehicleId") or "?", model:GetAttribute("AiType"), state))
                    if previousState[model] ~= state then
                        if state == "DETECT" then
                            alert(string.format("%s %s - TARGET ACQUIRED", model:GetAttribute("VehicleId"), model:GetAttribute("AiType")), AMBER, "det" .. model.Name)
                            Audio.Blip(1.1)
                        elseif state == "AIM" then
                            alert(string.format("TARGETED BY %s %s - RAISE SHIELD", model:GetAttribute("VehicleId"), model:GetAttribute("AiType")), RED, "aim" .. model.Name)
                            Audio.Blip(2)
                        elseif state == "DISABLED" then
                            alert(string.format("%s %s - WEAPON SYSTEMS OFFLINE", model:GetAttribute("VehicleId"), model:GetAttribute("AiType")), CYAN, "dis" .. model.Name)
                        end
                        previousState[model] = state
                    end
                    if state == "AIM" then
                        local warn = model:GetAttribute("AiWarn") or 1
                        local remaining = math.max(0, warn - (workspace:GetServerTimeNow() - (model:GetAttribute("AiAimAt") or 0)))
                        if not targeted or remaining < targeted.f then
                            targeted = { text = string.format("TARGETED  %s %s  |  FIRING IN %.1fs", model:GetAttribute("VehicleId"), model:GetAttribute("AiType"), remaining), f = remaining }
                        end
                    end
                end
            end
        end
        Telemetry.Publish("combat.targets", table.concat(targets, " | "))

        local threats = {}
        if fx then
            for _, shell in ipairs(fx.Active()) do
                local t, miss = Math.closest(shell.pos.X, shell.pos.Y, shell.pos.Z, shell.v.X, shell.v.Y, shell.v.Z, center.X, center.Y + 9, center.Z)
                if t > -0.05 and t < 4 and miss < 7 + shell.r + 4 then
                    table.insert(threats, { t = math.max(t, 0), shell = shell, miss = miss })
                end
            end
            table.sort(threats, function(a, b) return a.t < b.t end)
        end
        local shieldState = mech:GetAttribute("ShieldState") or "READY"
        local ready = shieldState == "READY" and (mech:GetAttribute("EnergyCharge") or 0) >= Components.SHIELD_PULSE.activationCost
        if #threats > 0 then
            local first = threats[1]
            local bearing = facingBearing(chassis and chassis.CFrame or camera.CFrame, first.shell.pos - first.shell.v.Unit * 30)
            threatLine.Text = string.format("INCOMING  %s  |  IMPACT %.1fs  |  %s", first.shell.tank, first.t, describeBearing(bearing))
            threatLine.TextColor3 = if math.floor(now * 8) % 2 == 0 or first.t > 0.8 then RED else WHITE
            Telemetry.Publish("combat.threat", string.format("%s %.1f", first.shell.tank, first.t))
            -- Closing ring: reaches the reticle at the best moment to press the shield (perfect-window centre).
            local lead = first.t - PERFECT_LEAD
            ring.Visible = ready and lead > -0.12
            local radius = 34 + 150 * math.clamp(lead / 1.2, 0, 1)
            ring.Size = UDim2.fromOffset(radius * 2, radius * 2)
            local now_ = lead < 0.08 and lead > -0.12
            ringStroke.Color = if now_ then GOLD else AMBER
            ringStroke.Thickness = if now_ then 4 else 2
            ringLabel.Text = if not ready then (if shieldState ~= "READY" then "SHIELD " .. shieldState else "CAPACITOR LOW") elseif now_ then "GUARD  NOW" elseif lead < 0.9 then "GUARD" else ""
            ringLabel.TextColor3 = if not ready then AMBER elseif now_ then GOLD else WHITE
            if not ready then
                ring.Visible = false
            end
        else
            Telemetry.Publish("combat.threat", "")
            ring.Visible, ringLabel.Text = false, ""
            if targeted then
                threatLine.Text = targeted.text
                threatLine.TextColor3 = AMBER
            else
                threatLine.Text = ""
            end
        end
        -- Chevrons toward the shooters of up to three shells on a collision course
        local look = camera.CFrame.LookVector
        local cameraYaw = math.atan2(-look.X, -look.Z)
        local viewport = camera.ViewportSize / scale.Scale
        for i, c in ipairs(chevrons) do
            local threat = threats[i]
            if threat then
                local from = threat.shell.pos - threat.shell.v.Unit * 30
                local d = from - camera.CFrame.Position
                local rel = math.rad(Math.relativeBearing(cameraYaw, d.X, d.Z))
                local r = 210
                c.Position = UDim2.fromOffset(viewport.X / 2 + math.sin(rel) * r, viewport.Y / 2 - math.cos(rel) * r)
                c.Rotation = math.deg(rel) + 45
                c.BackgroundTransparency = if math.floor(now * (6 + 10 / math.max(threat.t, 0.2))) % 2 == 0 then 0.15 else 0.7
                c.Visible = true
            else
                c.Visible = false
            end
        end

        -- Alert feed
        for i = #alerts, 1, -1 do
            if now - alerts[i].born > 4.2 then
                table.remove(alerts, i)
            end
        end
        for i, line in ipairs(feed) do
            local a = alerts[i]
            if a then
                line.Text, line.TextColor3 = a.text, a.color
                local age = now - a.born
                line.TextTransparency = if age < 3.4 then 0 else (age - 3.4) / 0.8
            else
                line.TextTransparency = 1
            end
        end
        -- Edge flash
        local age = now - flash.born
        local intensity = flash.strength * math.clamp(1 - age / 0.5, 0, 1)
        for _, f in ipairs(edges) do
            f.Visible = intensity > 0.01
            f.BackgroundColor3 = flash.color
            f.BackgroundTransparency = 1 - intensity
        end
    end)

    -- Client-only test interface (no authority): lets scripted playtests read what the pilot sees.
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeCombatControl"
    control.OnInvoke = function(command, a)
        if command == "state" then
            local lines = {}
            for _, al in ipairs(alerts) do
                table.insert(lines, al.text)
            end
            return { threat = threatLine.Text, alerts = lines, ringVisible = ring.Visible, ringLabel = ringLabel.Text, conditionVisible = strip.Visible,
                fx = fx and fx.Stats() or nil, dmgfx = damageFx and damageFx.Stats() or nil }
        elseif command == "mode" then
            remotes.RequestCombatMode:FireServer(a)
        end
        return nil
    end
    control.Parent = player:WaitForChild("PlayerScripts")
    return api
end

return CombatHud
