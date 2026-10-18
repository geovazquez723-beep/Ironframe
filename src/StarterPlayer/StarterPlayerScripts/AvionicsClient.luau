-- Avionics client (M11C): the pilot's side of the sensor suite. Presentation and input only; every number comes from the server.
--
--   packets    AvionicsUpdate from the server (contacts, lock, thermal list, capability) -> the Telemetry bus ("avionics.state"), where the
--              radar, targeting and sensor displays on the cockpit consoles read it
--   zoom       the server confirms the optics mode (mech attribute AvMag); the camera controller (CockpitMode) asks `Camera` for the field of view
--              and `LookScale` for the head-look sensitivity. One camera controller, one zoom state (ZoomControl); no second camera exists
--   thermal    ThermalView renders the machines the server reported as thermally visible
--   tracking   a screen-space box that follows the locked machine's REAL replicated model (so it can never float away from it), with a raycast for
--              cover; the text comes from the server tracker
--   controls   Z zoom, Y thermal, L acquire / next target, U release, O radar scale (all only in the cockpit view), plus a small clickable strip
--              (use ALT for the cursor)
-- Reset(reason) returns every view change to the factory state; it is called whenever the cockpit view ends (toggle, garage, ejection, respawn).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local ZoomControl = require(Shared:WaitForChild("ZoomControl"))
local ThermalView = require(script.Parent:WaitForChild("ThermalView"))
local Audio = require(script.Parent:WaitForChild("CockpitAudio"))

local Client = {}
Client.publishedAt = -10

local player = Players.LocalPlayer
local zoom = ZoomControl.New()
local thermal = ThermalView.New()
local remotes: Folder
local mode: any
local hud: any
local packet: any = nil
local packetAt = -10
local lastN = -1
local lastPing = -10
local gui: ScreenGui
local tracking: any = {}
local markers: { Frame } = {}
local buttons: { [string]: TextButton } = {}
local stripFrame: Frame
local perf = { ms = 0, samples = 0 }
local lastAttrAt = 0
local cockpitLive = false
local thermalWanted = false
local stabilized = true

local function getModel(): Model?
    local folder = workspace:FindFirstChild("IronframeMechs")
    local model = folder and folder:FindFirstChild(tostring(player.UserId))
    return if model and model:IsA("Model") then model else nil
end

local function send(cmd: string, a: any?, b: any?)
    local remote = remotes:FindFirstChild("RequestAvionics")
    if remote then
        (remote :: RemoteEvent):FireServer(cmd, a, b)
    end
end

-- Input is live only in the settled cockpit view of a deployed, operational machine.
local function inputLive(): boolean
    if mode.Current() ~= "COCKPIT" or mode.IsTransitioning() or mode.IsEvacuating() or UserInputService:GetFocusedTextBox() then
        return false
    end
    local model = getModel()
    return model ~= nil and model:GetAttribute("Deployment") == "ACTIVE" and model:GetAttribute("State") == "OPERATIONAL"
end

-- Commands -----------------------------------------------------------------------------------------------------------------------------
function Client.CycleZoom()
    if inputLive() then
        send("zoom", "cycle")
    end
end

function Client.ToggleThermal()
    if inputLive() then
        send("thermal", "toggle")
    end
end

function Client.Acquire()
    if not inputLive() then
        return
    end
    local camera = workspace.CurrentCamera
    local locked = packet ~= nil and packet.lock ~= nil
    send("acquire", camera.CFrame.LookVector, if locked then "next" else nil)
end

function Client.Release()
    if inputLive() then
        send("release")
    end
end

function Client.CycleRadar()
    if mode.Current() == "COCKPIT" then
        local scale = hud.CycleRadarScale()
        Audio.Blip(1.6 + scale)
    end
end

-- Camera integration (called by the one camera controller) ---------------------------------------------------------------------------
-- baseFov is the controller's own baseline (already capped for ultrawide viewports). Returns the magnified field of view.
function Client.Camera(baseFov: number): number
    return ZoomControl.Fov(zoom, baseFov)
end

function Client.LookScale(): number
    return ZoomControl.LookScale(zoom)
end

function Client.ThermalActive(): boolean
    return thermal.active
end

function Client.Magnification(): number
    return zoom.current
end

-- Camera sway is an angle, so a magnified picture shows it m times larger. Gyro-stabilised optics (powered) hold the on-screen shake constant; starved
-- optics let the full magnified shake through.
function Client.ShakeScale(): number
    return if stabilized then 1 / zoom.current else 1
end

function Client.Reset(reason: string, notifyServer: boolean?)
    local wasActive = ZoomControl.IsZoomed(zoom) or thermal.active or (packet ~= nil and packet.lock ~= nil)
    ZoomControl.Reset(zoom)
    thermal:SetActive(false)
    thermalWanted = false
    tracking.hideAll()
    if notifyServer and wasActive then
        send("reset")
    end
    Client.lastReset = reason
end

function Client.Stats()
    return {
        packets = Client.packets or 0, ms = perf.ms, zoom = zoom.current, zoomTarget = zoom.target, thermal = thermal:Report(), lastReset = Client.lastReset,
        lock = packet and packet.lock and { nm = packet.lock.nm, st = packet.lock.st, d = packet.lock.d, rs = packet.lock.rs, cm = packet.lock.cm ~= nil } or nil,
        contacts = packet and #packet.c or 0, rd = packet and packet.rd, th = packet and packet.th, tr = packet and packet.tr, ms2 = packet and packet.ms,
        boxVisible = tracking.boxVisible and tracking.boxVisible() or false, boxObscured = tracking.obscured, stabilized = stabilized, fov = workspace.CurrentCamera.FieldOfView,
        inputLive = inputLive(), age = os.clock() - packetAt, markers = tracking.markerCount and tracking.markerCount() or 0,
    }
end

-- Packets -------------------------------------------------------------------------------------------------------------------------
local function onPacket(p: any)
    Client.packets = (Client.packets or 0) + 1
    if p.off then
        packet = nil
        Telemetry.Publish("avionics.state", nil, "STANDBY")
        return
    end
    p.rx = os.clock()
    packet, packetAt = p, p.rx
    Telemetry.Publish("avionics.state", p, "LIVE")
    -- the radar ping rings once per real scan return
    if p.rd then
        local freshest = 1e9
        for _, c in ipairs(p.c) do
            freshest = math.min(freshest, c.ag)
        end
        if (freshest < 0.12 or #p.c == 0) and p.rx - lastPing >= math.max(p.rd.i, 0.2) then
            lastPing = p.rx
            hud.RadarPing()
        end
    end
    -- audible cue for a fresh message (lock acquired / lost)
    if p.ms and p.ms ~= Client.lastMessage then
        Client.lastMessage = p.ms
        Audio.Blip(if string.find(p.ms, "LOCK", 1, true) and not string.find(p.ms, "RELEASED", 1, true) then 2.2 else 0.9)
    end
end

-- Tracking overlay -----------------------------------------------------------------------------------------------------------------------
local BAR = { { 0, 0, 1, 0 }, { 0, 0, 0, 1 }, { 1, 0, -1, 0 }, { 1, 0, 0, 1 }, { 0, 1, 1, 0 }, { 0, 1, 0, -1 }, { 1, 1, -1, 0 }, { 1, 1, 0, -1 } }

local function buildOverlay()
    gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder, gui.Enabled = "IronframeTracking", false, true, 21, true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = player:WaitForChild("PlayerGui")

    local box = Instance.new("Frame")
    box.Name = "TargetBox"
    box.BackgroundTransparency = 1
    box.Visible = false
    box.Parent = gui
    local bars = {}
    for _, spec in ipairs(BAR) do
        local bar = Instance.new("Frame")
        bar.BorderSizePixel = 0
        bar.AnchorPoint = Vector2.new(spec[1], spec[2])
        bar.Position = UDim2.fromScale(spec[1], spec[2])
        bar.Size = if spec[3] ~= 0 then UDim2.fromOffset(18, 3) else UDim2.fromOffset(3, 18)
        bar.Parent = box
        table.insert(bars, bar)
    end
    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 1, 6)
    label.Size = UDim2.fromOffset(320, 36)
    label.Font, label.TextSize = Enum.Font.RobotoMono, 16
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Text = ""
    label.Parent = box
    local stroke = Instance.new("UIStroke")
    stroke.Thickness, stroke.Color, stroke.Transparency = 1, Color3.new(0, 0, 0), 0.4
    stroke.Parent = label
    local arrow = Instance.new("TextLabel")
    arrow.Name = "Arrow"
    arrow.BackgroundTransparency = 1
    arrow.AnchorPoint = Vector2.new(0.5, 0.5)
    arrow.Size = UDim2.fromOffset(220, 44)
    arrow.Font, arrow.TextSize = Enum.Font.RobotoMono, 18
    arrow.Visible = false
    arrow.Parent = gui
    for i = 1, 4 do
        local blob = Instance.new("Frame")
        blob.Name = "Heat" .. i
        blob.AnchorPoint = Vector2.new(0.5, 0.5)
        blob.BackgroundTransparency = 0.35
        blob.BorderSizePixel = 0
        blob.Visible = false
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = blob
        blob.Parent = gui
        markers[i] = blob
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local rayAt, blocked = -10, false
    local boxShown = false
    local offset: Vector3? = nil
    local offsetFor: Instance? = nil

    tracking.hideAll = function()
        box.Visible, arrow.Visible, boxShown = false, false, false
        for _, blob in ipairs(markers) do
            blob.Visible = false
        end
    end
    tracking.boxVisible = function()
        return boxShown
    end
    tracking.markerCount = function()
        local n = 0
        for _, blob in ipairs(markers) do
            if blob.Visible then n += 1 end
        end
        return n
    end

    local function colorsFor(lock: any): Color3
        local c = hud.Colors()
        if lock.st == "TRACK" then return c.primary elseif lock.st == "COAST" then return c.warn end
        return c.crit
    end

    -- Projects the oriented box and positions the frame; returns false when the target is not in front of the camera.
    local function placeBox(camera: Camera, centre: Vector3, rotation: CFrame, size: Vector3, lock: any): boolean
        local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
        local inFront = true
        for sx = -1, 1, 2 do
            for sy = -1, 1, 2 do
                for sz = -1, 1, 2 do
                    local world = (CFrame.new(centre) * rotation * CFrame.new(size.X * 0.5 * sx, size.Y * 0.5 * sy, size.Z * 0.5 * sz)).Position
                    local v = camera:WorldToViewportPoint(world)
                    if v.Z <= 0 then
                        inFront = false
                    else
                        minX, minY, maxX, maxY = math.min(minX, v.X), math.min(minY, v.Y), math.max(maxX, v.X), math.max(maxY, v.Y)
                    end
                end
            end
        end
        if not inFront then
            return false
        end
        local viewport = camera.ViewportSize
        if maxX < 0 or minX > viewport.X or maxY < 0 or minY > viewport.Y then
            return false
        end
        local width, height = math.max(maxX - minX, 34), math.max(maxY - minY, 34)
        box.Position = UDim2.fromOffset((minX + maxX) / 2 - width / 2, (minY + maxY) / 2 - height / 2)
        box.Size = UDim2.fromOffset(width, height)
        return true
    end

    tracking.update = function(camera: Camera, model: Model?, now: number)
        local lock = packet and packet.lock
        if not cockpitLive or not lock or not lock.nm or not model then
            if boxShown or arrow.Visible then tracking.hideAll() end
            tracking.obscured = nil
            return
        end
        local target: Instance? = lock.m
        local pivot: CFrame? = nil
        if typeof(target) == "Instance" and target:IsA("Model") and target.Parent then
            pivot = target:GetPivot()
        end
        if pivot and offsetFor ~= target and lock.p then
            -- server centre minus the model's pivot when this model first appears in a packet: a constant, so the box rides the model exactly
            offset = lock.p - pivot.Position
            offsetFor = target
        end
        local centre: Vector3
        local rotation = CFrame.identity
        if pivot and offset then
            centre = pivot.Position + offset
            rotation = pivot.Rotation
        elseif lock.p then
            local age = now - packetAt
            centre = lock.p + (lock.v or Vector3.zero) * math.min(age, 0.5) -- extrapolate when the model is not streamed in
        else
            return
        end
        -- cover check at ~12 Hz: a machine behind a wall is boxed as obscured, never as a clean lock
        if now - rayAt > 0.08 then
            rayAt = now
            local list = {}
            local function add(instance: Instance?)
                if instance then
                    table.insert(list, instance)
                end
            end
            add(model)
            add(workspace:FindFirstChild("IronframeCockpitClient"))
            add(workspace:FindFirstChild("IronframeWeaponEffects"))
            add(workspace:FindFirstChild("IronframeCombatFx"))
            add(workspace:FindFirstChild("IronframeThermalClient"))
            add(player.Character)
            if typeof(target) == "Instance" then
                add(target)
            end
            params.FilterDescendantsInstances = list
            local origin = camera.CFrame.Position
            blocked = workspace:Raycast(origin, centre - origin, params) ~= nil
        end
        tracking.obscured = blocked
        local colour = if blocked and lock.st == "TRACK" then hud.Colors().warn else colorsFor(lock)
        local size = lock.sz or Vector3.new(14, 10, 14)
        local visible = placeBox(camera, centre, rotation, size, lock)
        local text = string.format("%s  %d ST  %s", lock.nm, lock.d, if blocked and lock.st == "TRACK" then "OBSCURED" else (lock.st or ""))
        if visible then
            arrow.Visible = false
            box.Visible, boxShown = true, true
            for _, bar in ipairs(bars) do
                bar.BackgroundColor3 = colour
                bar.BackgroundTransparency = if blocked then 0.45 else 0
            end
            label.Text = text
            label.TextColor3 = colour
        else
            box.Visible, boxShown = false, false
            -- off screen / behind: an edge marker toward the machine
            local v = camera.CFrame:PointToObjectSpace(centre)
            local dir = Vector2.new(v.X, -v.Y)
            if dir.Magnitude < 1e-3 then dir = Vector2.new(0, -1) end
            dir = dir.Unit
            local viewport = camera.ViewportSize
            local edge = math.min(viewport.X, viewport.Y) / 2 - 60
            arrow.Position = UDim2.fromOffset(viewport.X / 2 + dir.X * edge * 1.4, viewport.Y / 2 + dir.Y * edge)
            arrow.Text = (if dir.X < -0.3 then "<< " elseif dir.X > 0.3 then "" else "") .. text .. (if dir.X > 0.3 then " >>" else "")
            arrow.TextColor3 = colour
            arrow.Visible = true
        end
    end

    -- MARKERS fallback for the thermal view: a heat blob at each machine the server reported visible
    tracking.markers = function(camera: Camera, active: boolean)
        local list = if active and packet and packet.hot then packet.hot else {}
        for i, blob in ipairs(markers) do
            local entry = list[i]
            if entry and typeof(entry.m) == "Instance" and entry.m.Parent and entry.m:IsA("Model") then
                local pos = entry.m:GetPivot().Position + Vector3.new(0, 4, 0)
                local v = camera:WorldToViewportPoint(pos)
                if v.Z > 0 then
                    local diameter = math.clamp(7000 / math.max(v.Z, 20), 36, 220)
                    blob.Position = UDim2.fromOffset(v.X, v.Y)
                    blob.Size = UDim2.fromOffset(diameter, diameter)
                    blob.BackgroundColor3 = ThermalView.HeatColor(entry.lv or 0)
                    blob.BackgroundTransparency = 0.6 - 0.4 * (entry.lv or 0)
                    blob.Visible = true
                else
                    blob.Visible = false
                end
            else
                blob.Visible = false
            end
        end
    end
end

-- Control strip --------------------------------------------------------------------------------------------------------------------------
local function buildControls()
    local controls = Instance.new("ScreenGui")
    controls.Name, controls.ResetOnSpawn, controls.IgnoreGuiInset, controls.DisplayOrder = "IronframeAvionicsControls", false, true, 26
    controls.Parent = player:WaitForChild("PlayerGui")
    stripFrame = Instance.new("Frame")
    stripFrame.Name = "Strip"
    stripFrame.BackgroundTransparency = 1
    stripFrame.AnchorPoint = Vector2.new(0, 0.5)
    stripFrame.Position = UDim2.new(0, 22, 0.5, -30)
    stripFrame.Size = UDim2.fromOffset(150, 170)
    stripFrame.Visible = false
    stripFrame.Parent = controls
    local specs = { { "zoom", "Z  ZOOM", Client.CycleZoom }, { "thermal", "Y  THERMAL", Client.ToggleThermal }, { "lock", "L  LOCK", Client.Acquire },
        { "release", "U  RELEASE", Client.Release }, { "radar", "O  RADAR", Client.CycleRadar } }
    for i, spec in ipairs(specs) do
        local b = Instance.new("TextButton")
        b.Name = spec[1]
        b.Size, b.Position = UDim2.fromOffset(146, 28), UDim2.fromOffset(0, (i - 1) * 32)
        b.BackgroundColor3, b.BackgroundTransparency, b.BorderSizePixel = Color3.fromRGB(10, 16, 14), 0.25, 0
        b.Font, b.TextSize, b.TextXAlignment = Enum.Font.RobotoMono, 14, Enum.TextXAlignment.Left
        b.Text = spec[2]
        b.AutoButtonColor = true
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 8)
        pad.Parent = b
        local stroke = Instance.new("UIStroke")
        stroke.Thickness, stroke.Transparency = 1, 0.4
        stroke.Parent = b
        b.Parent = stripFrame
        b.MouseButton1Click:Connect(spec[3])
        buttons[spec[1]] = b
    end
end

local function refreshControls()
    local c = hud.Colors()
    local spec = Telemetry.Value("avionics.spec", nil)
    local st = packet
    local function style(name: string, fitted: boolean, text: string, active: boolean)
        local b = buttons[name]
        b.Visible = true
        b.Text = text
        b.TextColor3 = if not fitted then c.dim elseif active then c.warn else c.primary
        b.TextTransparency = if fitted then 0 else 0.4
        local stroke = b:FindFirstChildOfClass("UIStroke") :: UIStroke
        stroke.Color = b.TextColor3
    end
    local hasOptics, hasThermal, hasTracker = spec ~= nil and spec.optics ~= nil, spec ~= nil and spec.thermal ~= nil, spec ~= nil and spec.tracker ~= nil
    style("zoom", hasOptics, if hasOptics then string.format("Z  ZOOM %.0fX", zoom.target) else "Z  NO OPTICS", zoom.target > 1)
    local thermalOn = st ~= nil and st.th ~= nil and st.th.on == true
    style("thermal", hasThermal, if not hasThermal then "Y  NO THERMAL" elseif thermalOn then "Y  THERMAL ON" elseif st and st.th and not st.th.av then "Y  " .. st.th.why else "Y  THERMAL OFF", thermalOn)
    style("lock", hasTracker, if not hasTracker then "L  NO TRACKER" elseif st and st.lock then "L  NEXT TARGET" else "L  ACQUIRE", st ~= nil and st.lock ~= nil)
    style("release", hasTracker, "U  RELEASE", false)
    style("radar", true, string.format("O  RADAR 1/%d", math.floor(1 / hud.RadarScale() + 0.5)), false)
end

-- Frame step (called by the camera controller every frame while the interior is active) --------------------------------------------------
function Client.Step(dt: number, active: boolean)
    local started = os.clock()
    local now = os.clock()
    local model = getModel()
    cockpitLive = active and model ~= nil and model:GetAttribute("Deployment") == "ACTIVE" and model:GetAttribute("State") == "OPERATIONAL"
    local mag, wantThermal = 1, false
    if cockpitLive and model then
        mag = model:GetAttribute("AvMag") or 1
        wantThermal = model:GetAttribute("AvThermal") == true
        stabilized = model:GetAttribute("AvStabilized") ~= false
    end
    ZoomControl.SetTarget(zoom, mag)
    ZoomControl.Step(zoom, dt)
    if wantThermal ~= thermalWanted then
        thermalWanted = wantThermal
        thermal:SetActive(wantThermal)
        if wantThermal then
            thermal:SetTargets(packet and packet.hot)
            lastN = packet and packet.n or -1
        end
    elseif wantThermal and packet and packet.n ~= lastN then
        lastN = packet.n
        thermal:SetTargets(packet.hot)
    end
    local camera = workspace.CurrentCamera
    if cockpitLive then
        tracking.update(camera, model, now)
        tracking.markers(camera, thermalWanted and thermal.mode == "MARKERS")
    elseif tracking.boxVisible() then
        tracking.hideAll()
    end
    stripFrame.Visible = active and cockpitLive
    if stripFrame.Visible and now - lastAttrAt > 0.15 then
        lastAttrAt = now
        refreshControls()
    end
    if model and now - Client.publishedAt > 0.2 then
        Client.publishedAt = now
        Telemetry.Publish("avionics.demand", model:GetAttribute("AvionicsDemand") or 0)
        Telemetry.Publish("avionics.factor", model:GetAttribute("AvionicsFactor") or 1)
    end
    -- compact readouts under the reticle
    if active then
        local zoomText = if zoom.current > 1.02 then string.format("%.1fX  FOV %d", zoom.current, math.floor(camera.FieldOfView + 0.5)) else ""
        local parts = {}
        if thermalWanted then table.insert(parts, "THERMAL") end
        if packet and packet.lock and packet.lock.nm then table.insert(parts, string.format("LOCK %s %s", packet.lock.nm, packet.lock.st or "")) end
        if packet and packet.ms then table.insert(parts, packet.ms) end
        hud.SetReadouts(zoomText, table.concat(parts, "   |   "), if packet and packet.lock and packet.lock.st ~= "TRACK" then hud.Colors().warn else nil)
    else
        hud.SetReadouts("", "")
    end
    perf.samples += 1
    perf.ms += ((os.clock() - started) * 1000 - perf.ms) * 0.05
end

function Client.Start(remoteFolder: Folder, cameraMode: any, hudModule: any)
    remotes, mode, hud = remoteFolder, cameraMode, hudModule
    buildOverlay()
    buildControls()
    local update = remotes:WaitForChild("AvionicsUpdate") :: RemoteEvent
    update.OnClientEvent:Connect(onPacket)
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end
        local code = input.KeyCode
        if code == Enum.KeyCode.Z then
            Client.CycleZoom()
        elseif code == Enum.KeyCode.Y then
            Client.ToggleThermal()
        elseif code == Enum.KeyCode.L then
            Client.Acquire()
        elseif code == Enum.KeyCode.U then
            Client.Release()
        elseif code == Enum.KeyCode.O then
            Client.CycleRadar()
        end
    end)
    -- Studio verification interface (client side only; it drives the same functions the keys and buttons call)
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeAvionicsControl"
    control.OnInvoke = function(command: string, a: any, b: any)
        if command == "zoom" then Client.CycleZoom()
        elseif command == "thermal" then Client.ToggleThermal()
        elseif command == "acquire" then Client.Acquire()
        elseif command == "release" then Client.Release()
        elseif command == "radar" then Client.CycleRadar()
        elseif command == "stats" then return Client.Stats()
        elseif command == "packet" then return packet
        elseif command == "mode" then thermal:SetMode(a)
        end
        return nil
    end
    control.Parent = player:WaitForChild("PlayerScripts")
end

return Client
