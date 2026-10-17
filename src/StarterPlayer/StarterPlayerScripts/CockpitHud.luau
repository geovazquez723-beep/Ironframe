-- Cockpit instrumentation (M06A): physical SurfaceGui displays on the cockpit consoles plus a restrained ScreenGui overlay
-- (compass tape, reticle, status, evacuation warnings). Every readout comes from the Telemetry bus; subsystems that do
-- not exist yet show STANDBY, and clearly-labelled placeholder animation shows DEMO. Nothing here is invented gameplay data.
--
-- Update model: static layout is built once. `Hud.Step(dt)` moves a handful of cheap animated elements (compass, radar
-- sweep) every frame, and `refresh()` rewrites text/bars at ~6 Hz, only when telemetry changed or a display is visible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Config = require(Shared:WaitForChild("CockpitConfig"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local Components = require(Shared:WaitForChild("ComponentRegistry"))

local Hud = {}

local COLORS = Config.COLORS
local FONT_TITLE, FONT_DATA = Enum.Font.Michroma, Enum.Font.RobotoMono
local CYAN, CYAN_DIM, AMBER, RED, WHITE, PANEL = COLORS.cyan, COLORS.cyanDim, COLORS.amber, COLORS.red, COLORS.white, COLORS.panel
local DIM_TEXT = Color3.fromRGB(96, 140, 152)

local SOCKETS = {
    { id = "left_arm", label = "L ARM", group = "ARMS" },
    { id = "right_arm", label = "R ARM", group = "ARMS" },
    { id = "left_shoulder", label = "L SHLD", group = "SHOULDER" },
    { id = "right_shoulder", label = "R SHLD", group = "SHOULDER" },
    { id = "left_torso", label = "L TORSO", group = "TORSO" },
    { id = "right_torso", label = "R TORSO", group = "TORSO" },
}

local function new(class: string, props: { [string]: any }, parent: Instance?): any
    local inst = Instance.new(class)
    for key, value in pairs(props) do
        (inst :: any)[key] = value
    end
    inst.Parent = parent
    return inst
end

local function label(parent: Instance, text: string, position: UDim2, size: UDim2, props: { [string]: any }?): TextLabel
    local base = {
        BackgroundTransparency = 1, Text = text, Position = position, Size = size, Font = FONT_DATA, TextSize = 22,
        TextColor3 = CYAN, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = false, TextTruncate = Enum.TextTruncate.None,
    }
    for key, value in pairs(props or {}) do
        base[key] = value
    end
    return new("TextLabel", base, parent)
end

local function box(parent: Instance, position: UDim2, size: UDim2, color: Color3, transparency: number?, stroke: number?): Frame
    local frame = new("Frame", { Position = position, Size = size, BackgroundColor3 = color, BackgroundTransparency = transparency or 0, BorderSizePixel = 0 }, parent)
    if stroke then
        new("UIStroke", { Color = color, Thickness = stroke, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
        frame.BackgroundTransparency = transparency or 1
    end
    return frame
end

local function tagColor(status: string): Color3
    if status == "LIVE" then
        return CYAN
    elseif status == "DEMO" then
        return AMBER
    end
    return DIM_TEXT
end

-- ---------------------------------------------------------------------------------------------------------------
-- Physical displays
-- ---------------------------------------------------------------------------------------------------------------

type Display = {
    key: string,
    gui: SurfaceGui,
    root: Frame,
    content: Frame,
    boot: Frame,
    bootBar: Frame,
    tag: TextLabel,
    state: string,
    refresh: (() -> ())?,
}

local displays: { [string]: Display } = {}
local sections: { [string]: { Frame } } = {} -- schematic section frames, by id (a future damage feed colours these)
local widgets: { [string]: any } = {}

local function makeDisplay(key: string, part: Part, canvas: Vector2, title: string): Display
    local gui = new("SurfaceGui", {
        Name = "Display", Face = Enum.NormalId.Front, SizingMode = Enum.SurfaceGuiSizingMode.FixedSize, CanvasSize = canvas,
        LightInfluence = 0, Brightness = 1.5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, AlwaysOnTop = false,
        ClipsDescendants = true, MaxDistance = 40,
    }, part)
    local root = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = PANEL, BorderSizePixel = 0 }, gui)
    -- Faint grid
    local grid = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 1 }, root)
    for x = 40, canvas.X - 1, 40 do
        box(grid, UDim2.fromOffset(x, 0), UDim2.new(0, 1, 1, 0), CYAN, 0.94)
    end
    for y = 40, canvas.Y - 1, 40 do
        box(grid, UDim2.fromOffset(0, y), UDim2.new(1, 0, 0, 1), CYAN, 0.94)
    end
    -- Header
    local header = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = CYAN_DIM, BackgroundTransparency = 0.72, BorderSizePixel = 0, ZIndex = 3 }, root)
    label(header, title, UDim2.fromOffset(16, 0), UDim2.new(0.62, 0, 1, 0), { Font = FONT_TITLE, TextSize = 20, TextColor3 = CYAN, ZIndex = 4 })
    local tag = label(header, "STANDBY", UDim2.new(0.55, 0, 0, 0), UDim2.new(0.45, -16, 1, 0), { TextXAlignment = Enum.TextXAlignment.Right, TextSize = 20, TextColor3 = DIM_TEXT, ZIndex = 4 })
    box(root, UDim2.fromOffset(0, 44), UDim2.new(1, 0, 0, 2), CYAN, 0.1)
    -- Corner brackets
    for _, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
        local anchor = Vector2.new(c[1], c[2])
        box(root, UDim2.new(c[1], 0, c[2], 0), UDim2.fromOffset(26, 3), CYAN, 0.2).AnchorPoint = anchor
        box(root, UDim2.new(c[1], 0, c[2], 0), UDim2.fromOffset(3, 26), CYAN, 0.2).AnchorPoint = anchor
    end
    local content = new("Frame", { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 1, -48), BackgroundTransparency = 1, ZIndex = 2, Visible = false }, root)
    -- Slow scan bar (one engine-driven tween, no per-frame script cost)
    local scan = box(root, UDim2.fromOffset(0, 46), UDim2.new(1, 0, 0, 3), CYAN, 0.88)
    scan.ZIndex = 8
    TweenService:Create(scan, TweenInfo.new(5.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), { Position = UDim2.new(0, 0, 1, -6) }):Play()
    -- Boot layer
    local boot = new("Frame", { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 1, -48), BackgroundColor3 = PANEL, BorderSizePixel = 0, ZIndex = 6, Visible = true }, root)
    label(boot, "DISPLAY  " .. key, UDim2.fromScale(0.5, 0.4), UDim2.fromOffset(0, 30), { Font = FONT_TITLE, TextSize = 20, TextColor3 = DIM_TEXT, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, Name = "BootText", ZIndex = 7 })
    local barBack = box(boot, UDim2.fromScale(0.5, 0.52), UDim2.new(0.6, 0, 0, 8), CYAN, nil, 1)
    barBack.AnchorPoint = Vector2.new(0.5, 0.5)
    barBack.ZIndex = 7
    local bar = box(barBack, UDim2.fromOffset(0, 0), UDim2.fromScale(0, 1), CYAN, 0.1)
    bar.ZIndex = 8
    local display: Display = { key = key, gui = gui, root = root, content = content, boot = boot, bootBar = bar, tag = tag, state = "OFF", refresh = nil }
    displays[key] = display
    return display
end

local function statusTag(display: Display, status: string)
    display.tag.Text = status
    display.tag.TextColor3 = tagColor(status)
end

local function bar(parent: Instance, position: UDim2, size: UDim2, fraction: number, color: Color3): Frame
    local back = box(parent, position, size, color, nil, 1)
    local fill = box(back, UDim2.fromOffset(0, 0), UDim2.fromScale(math.clamp(fraction, 0, 1), 1), color, 0.15)
    fill.Name = "Fill"
    return back
end

local function setBar(back: Frame, fraction: number, color: Color3?)
    local fill = back:FindFirstChild("Fill") :: Frame
    fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
    if color then
        fill.BackgroundColor3 = color
        ;(back:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = color
    end
end

-- STRUCTURE (left MFD): schematic with per-section armor condition
local function buildStructure(display: Display)
    local c = display.content
    local origin = Vector2.new(24, 8)
    local center = 180 -- schematic centre line within its 360-wide area
    local function section(id: string, name: string, size: Vector2, x: number, y: number)
        local frame = box(c, UDim2.fromOffset(origin.X + center + x - size.X / 2, origin.Y + y), UDim2.fromOffset(size.X, size.Y), CYAN, 0.8, 1.5)
        frame.BackgroundTransparency = 0.8
        frame.Name = name
        sections[id] = sections[id] or {}
        table.insert(sections[id], frame)
        return frame
    end
    section("head", "Head", Vector2.new(46, 32), 0, 0)
    section("torso", "Torso", Vector2.new(116, 104), 0, 38)
    section("torso", "Waist", Vector2.new(84, 22), 0, 146)
    for _, s in ipairs({ { "L", -1 }, { "R", 1 } }) do
        local t, sign = s[1], s[2]
        section("arm" .. t, "Shoulder" .. t, Vector2.new(54, 44), sign * 92, 36)
        section("arm" .. t, "UpperArm" .. t, Vector2.new(28, 62), sign * 102, 84)
        section("arm" .. t, "Forearm" .. t, Vector2.new(30, 74), sign * 106, 150)
        section("leg" .. t, "Thigh" .. t, Vector2.new(42, 84), sign * 34, 172)
        section("leg" .. t, "Shin" .. t, Vector2.new(36, 84), sign * 36, 262)
        section("leg" .. t, "Foot" .. t, Vector2.new(54, 24), sign * 40, 352)
    end
    local rows = { { "TORSO", "torso" }, { "L ARM", "armL" }, { "R ARM", "armR" }, { "L LEG", "legL" }, { "R LEG", "legR" } }
    widgets.structureBars = {}
    for i, row in ipairs(rows) do
        local y = 20 + (i - 1) * 62
        label(c, row[1], UDim2.fromOffset(412, y), UDim2.fromOffset(200, 24), { TextSize = 20, TextColor3 = WHITE })
        widgets.structureBars[row[2]] = bar(c, UDim2.fromOffset(412, y + 28), UDim2.fromOffset(204, 14), 1, CYAN)
    end
    widgets.integrity = label(c, "INTEGRITY  ---", UDim2.fromOffset(412, 336), UDim2.fromOffset(216, 26), { TextSize = 20, TextColor3 = WHITE })
    widgets.structureNote = label(c, "ARMOR RATED  /  DAMAGE FEED: STANDBY", UDim2.fromOffset(412, 372), UDim2.fromOffset(216, 56), { TextSize = 18, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        widgets.integrity.Text = string.format("INTEGRITY  %.0f", Telemetry.Value("integrity.total", 0))
        statusTag(display, "STANDBY")
    end
end

-- REACTOR (centre MFD): power, cooling and heat
local function buildReactor(display: Display)
    local c = display.content
    widgets.reactorName = label(c, "CORE ---", UDim2.fromOffset(20, 10), UDim2.fromOffset(440, 28), { TextSize = 22, TextColor3 = WHITE })
    local function gauge(key: string, y: number, title: string, color: Color3)
        label(c, title, UDim2.fromOffset(20, y), UDim2.fromOffset(250, 24), { TextSize = 20, TextColor3 = DIM_TEXT })
        widgets[key .. "Value"] = label(c, "---", UDim2.fromOffset(190, y), UDim2.fromOffset(270, 24), { TextSize = 20, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right })
        widgets[key .. "Bar"] = bar(c, UDim2.fromOffset(20, y + 30), UDim2.fromOffset(440, 16), 0, color)
    end
    gauge("power", 56, "DEMAND / REACTOR u/s", CYAN)
    gauge("heatGen", 128, "CAPACITOR UNITS", CYAN)
    gauge("cooling", 200, "THERMAL LOAD %", AMBER)
    label(c, "SUPPLY / CAP FLOW", UDim2.fromOffset(20, 272), UDim2.fromOffset(250, 24), { TextSize = 20, TextColor3 = DIM_TEXT })
    widgets.heatStore = label(c, "STANDBY", UDim2.fromOffset(190, 272), UDim2.fromOffset(270, 24), { TextSize = 20, TextColor3 = DIM_TEXT, TextXAlignment = Enum.TextXAlignment.Right })
    widgets.energyDrive = label(c, "PROPULSION  ---", UDim2.fromOffset(20, 320), UDim2.fromOffset(440, 25), { TextSize = 20, TextColor3 = CYAN })
    widgets.energyShield = label(c, "SHIELD  ---", UDim2.fromOffset(20, 352), UDim2.fromOffset(440, 25), { TextSize = 20, TextColor3 = CYAN })
    widgets.energyWarning = label(c, "", UDim2.fromOffset(20, 390), UDim2.fromOffset(440, 48), { TextSize = 18, TextColor3 = AMBER, TextWrapped = true })
    display.refresh = function()
        local m = Telemetry.Value("loadout.metrics", nil)
        local systems = Telemetry.Value("loadout.systems", {})
        if m then
            local reactor = Components[systems.reactor or ""]
            widgets.reactorName.Text = "CORE  " .. string.upper(reactor and reactor.name or "UNKNOWN")
            local demand, output = Telemetry.Value("energy.demand",0), Telemetry.Value("energy.output",0)
            local charge, capacity = Telemetry.Value("energy.charge",0), Telemetry.Value("energy.capacity",160)
            local thermal, deficit = Telemetry.Value("energy.thermal",0), Telemetry.Value("energy.deficit",0)
            widgets.powerValue.Text = string.format("%.1f / %.1f", demand, output)
            setBar(widgets.powerBar, demand / math.max(output,1), if demand > output then AMBER else CYAN)
            widgets.heatGenValue.Text = string.format("%.1f / %.0f", charge, capacity)
            setBar(widgets.heatGenBar, charge / math.max(capacity,1), if charge < 25 then AMBER else CYAN)
            widgets.coolingValue.Text = string.format("%.1f%%", thermal)
            setBar(widgets.coolingBar, thermal/100, AMBER)
            widgets.energyDrive.Text = string.format("PROPULSION %.1f u/s  | SIM %.1f",Telemetry.Value("energy.propulsion",0),Telemetry.Value("energy.weaponDemand",0))
            widgets.energyShield.Text = string.format("SHIELD %s  %.1fs",Telemetry.Value("shield.state","READY"),Telemetry.Value("shield.cooldown",0))
            widgets.energyWarning.Text = if deficit > 0.1 then string.format("DEFICIT %.1f u/s / SPRINT LIMITED",deficit) elseif charge < 25 then "SHIELD UNAVAILABLE: CAPACITOR LOW" else Telemetry.Value("shield.reason","READY")
        end
        local capChannel = Telemetry.Get("energy.capRate")
        widgets.heatStore.Text = if capChannel.value ~= nil then string.format("%.1f / %+.1f",Telemetry.Value("energy.supply",0), capChannel.value) else "STANDBY"
        statusTag(display, Telemetry.Get("energy.charge").status)
    end
end

-- ARMAMENT (right MFD): hardpoints, groups, ammunition
local function buildArmament(display: Display)
    local c = display.content
    widgets.weaponRows = {}
    for i, socket in ipairs(SOCKETS) do
        local y = 8 + (i - 1) * 56
        local row = box(c, UDim2.fromOffset(16, y), UDim2.fromOffset(608, 50), CYAN, 0.9)
        local sel = box(row, UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), AMBER, nil, 2)
        sel.Visible = false
        label(row, tostring(i), UDim2.fromOffset(10, 0), UDim2.fromOffset(24, 50), { TextSize = 24, TextColor3 = AMBER })
        label(row, socket.label, UDim2.fromOffset(40, 0), UDim2.fromOffset(110, 50), { TextSize = 20, TextColor3 = DIM_TEXT })
        local name = label(row, "EMPTY", UDim2.fromOffset(150, 0), UDim2.fromOffset(300, 50), { TextSize = 21, TextColor3 = WHITE })
        local ammo = label(row, "AMMO  STBY", UDim2.fromOffset(440, 0), UDim2.fromOffset(160, 50), { TextSize = 18, TextColor3 = DIM_TEXT, TextXAlignment = Enum.TextXAlignment.Right })
        widgets.weaponRows[socket.id] = { row = row, sel = sel, name = name, ammo = ammo }
    end
    widgets.armamentFooter = label(c, "FIRE CONTROL: STANDBY  /  GROUPS: ARMS  SHOULDER  TORSO", UDim2.fromOffset(16, 350), UDim2.fromOffset(608, 88), { TextSize = 18, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        local mounts = Telemetry.Value("loadout.mounts", {})
        local selected = Telemetry.Value("weapons.selected", 1)
        for i, socket in ipairs(SOCKETS) do
            local w = widgets.weaponRows[socket.id]
            local component = Components[mounts[socket.id] or ""]
            w.name.Text = if component then string.upper(component.name) else "EMPTY"
            w.name.TextColor3 = if component then WHITE else DIM_TEXT
            local ammo = Telemetry.Value("weapons.magazines", {})[socket.id]
            w.ammo.Text = if not component or not component.combat then "UNAVAILABLE" elseif component.combat.magazine == 0 then "CAP POWER" else tostring(ammo or "--") .. " / " .. component.combat.magazine
            w.sel.Visible = i == selected
        end
        widgets.armamentFooter.Text = string.format("%s %s | %.1f u/shot\nMAX %.1f u/s / %.1f heat/s | RELOAD %.1fs / CD %.2fs | HITS %d / %.1f DMG", Telemetry.Value("weapons.mode","SAFE"),Telemetry.Value("weapons.state","SAFE"),Telemetry.Value("weapons.cost",0),Telemetry.Value("weapons.power",0),Telemetry.Value("weapons.heat",0),Telemetry.Value("weapons.reload",0),Telemetry.Value("weapons.cooldown",0),Telemetry.Value("weapons.hits",0),Telemetry.Value("weapons.lastDamage",0))
        statusTag(display, Telemetry.Get("weapons.state").status)
    end
end

-- DIAGNOSTICS (left console)
local function buildDiagnostics(display: Display)
    local c = display.content
    widgets.diagLines = label(c, "", UDim2.fromOffset(18, 12), UDim2.new(1, -30, 1, -24), { TextSize = 21, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = WHITE })
    display.refresh = function()
        local tests, rig = Telemetry.Value("diag.tests", nil), Telemetry.Value("diag.rig", nil)
        local m = Telemetry.Value("loadout.metrics", nil)
        local lines = {}
        if tests then
            table.insert(lines, string.format("SELF-TEST      %d/%d  %s", tests.passed, tests.total, if #tests.failed == 0 then "PASS" else "FAIL"))
        end
        if rig then
            table.insert(lines, string.format("RIG           %d PARTS", rig.parts))
            table.insert(lines, string.format("JOINTS        %d   LINKS %d", rig.joints, rig.links))
            table.insert(lines, string.format("SOCKETS       %d/%d", rig.socketsFilled, rig.socketsTotal))
            table.insert(lines, string.format("AI MESHES     %d", rig.meshParts or 0))
        end
        if m then
            table.insert(lines, string.format("MASS          %.1f/%.1f t", m.mass, m.massLimit))
            table.insert(lines, string.format("NOMINAL DPS   %.0f", m.nominalDps))
        end
        table.insert(lines, string.format("TORSO YAW     %+.1f DEG", Telemetry.Value("pilot.torsoYaw", 0)))
        table.insert(lines, "PILOT         " .. (if Telemetry.Value("pilot.safe", true) then "SAFE / UNTARGETABLE" else "CHECK"))
        widgets.diagLines.Text = table.concat(lines, "\n")
        statusTag(display, "LIVE")
    end
end

-- SENSORS (right console): radar with live bearing ring; no contacts exist yet
local function buildSensors(display: Display)
    local c = display.content
    local size, cx, cy = 340, 230, 190
    local scope = new("Frame", { Position = UDim2.fromOffset(cx - size / 2, cy - size / 2 + 4), Size = UDim2.fromOffset(size, size), BackgroundColor3 = CYAN_DIM, BackgroundTransparency = 0.9, BorderSizePixel = 0 }, c)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, scope)
    new("UIStroke", { Color = CYAN, Thickness = 2 }, scope)
    for _, f in ipairs({ 0.66, 0.33 }) do
        local ring = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(f, f), BackgroundTransparency = 1 }, scope)
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
        new("UIStroke", { Color = CYAN, Thickness = 1, Transparency = 0.6 }, ring)
    end
    box(scope, UDim2.fromScale(0.5, 0), UDim2.new(0, 1, 1, 0), CYAN, 0.7)
    box(scope, UDim2.fromScale(0, 0.5), UDim2.new(1, 0, 0, 1), CYAN, 0.7)
    -- Forward marker (always up: radar is mech-relative) and rotating sweep
    box(scope, UDim2.new(0.5, -6, 0, 6), UDim2.fromOffset(12, 4), AMBER, 0.1)
    local sweepHolder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, scope)
    local sweep = box(sweepHolder, UDim2.new(0.5, -1, 0, 4), UDim2.new(0, 3, 0.5, -4), CYAN, 0.1)
    new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }) }, sweep)
    widgets.sweep = sweepHolder
    widgets.bearing = {}
    for _, spec in ipairs({ { "N", 0 }, { "E", 90 }, { "S", 180 }, { "W", 270 } }) do
        widgets.bearing[spec[1]] = { angle = spec[2], label = label(c, spec[1], UDim2.fromOffset(0, 0), UDim2.fromOffset(30, 30), { TextSize = 22, TextColor3 = if spec[1] == "N" then AMBER else WHITE, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center }) }
    end
    widgets.radarCenter = Vector2.new(cx, cy + 4)
    widgets.radarRadius = size / 2 + 22
    widgets.contacts = label(c, "CONTACTS  0     SENSOR SWEEP: DEMO", UDim2.fromOffset(18, 396), UDim2.new(1, -30, 0, 28), { TextSize = 19, TextColor3 = AMBER })
    display.refresh = function()
        widgets.contacts.Text = string.format("CONTACTS  %d   SWEEP: DEMO", #Telemetry.Value("sensors.contacts", {}))
        statusTag(display, "DEMO")
    end
end

-- OVERHEAD: system list, final status line
local function buildOverhead(display: Display)
    local c = display.content
    local systems = {
        { "REACTOR", "reactor" }, { "COOLING", "cooling" }, { "HYDRAULICS", "hydraulics" }, { "LIFE SUPPORT", "life" },
        { "EJECTION", "ejection" }, { "LOCOMOTION", "drive" }, { "TARGETING", "standby" }, { "FIRE CONTROL", "standby" },
    }
    widgets.overheadItems = {}
    for i, sys in ipairs(systems) do
        local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
        local x = 20 + col * 238
        local y = 14 + row * 38
        local dot = box(c, UDim2.fromOffset(x, y + 8), UDim2.fromOffset(12, 12), CYAN, 0.1)
        label(c, sys[1], UDim2.fromOffset(x + 22, y), UDim2.fromOffset(128, 28), { TextSize = 18, TextColor3 = WHITE })
        local state = label(c, "---", UDim2.fromOffset(x + 142, y), UDim2.fromOffset(90, 28), { TextSize = 18, TextColor3 = CYAN })
        widgets.overheadItems[i] = { dot = dot, state = state, kind = sys[2] }
    end
    widgets.overheadStatus = label(c, "IF-42 BASTION", UDim2.fromOffset(20, 96), UDim2.new(1, -40, 0, 30), { Font = FONT_TITLE, TextSize = 20, TextColor3 = CYAN })
    display.refresh = function()
        local m = Telemetry.Value("loadout.metrics", nil)
        for _, item in ipairs(widgets.overheadItems) do
            local on = item.kind ~= "standby" and m ~= nil
            item.state.Text = if on then "ONLINE" else "STANDBY"
            if item.kind == "drive" then item.state.Text = Telemetry.Value("movement.drive", "IDLE") end
            if item.kind == "reactor" then item.state.Text = Telemetry.Value("reactor.state", "STANDBY") end
            item.state.TextColor3 = if on then CYAN else DIM_TEXT
            item.dot.BackgroundColor3 = if on then CYAN else AMBER
            item.dot.BackgroundTransparency = if on then 0.1 else 0.55
        end
        widgets.overheadStatus.Text = string.format("SHIELD %s / %.1fs / %s",Telemetry.Value("shield.state","READY"),Telemetry.Value("shield.cooldown",0),Telemetry.Value("shield.timing","AWAITING IMPACT"))
        statusTag(display, "LIVE")
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- ScreenGui overlay
-- ---------------------------------------------------------------------------------------------------------------

local overlay: ScreenGui, scaler: UIScale
local fade: Frame
local compass = { strip = nil :: Frame?, ticks = {} :: { { frame: Frame, label: TextLabel?, angle: number } } }
local heading = 0
local PX_PER_DEG = 4.2

local function buildOverlay(playerGui: PlayerGui)
    overlay = new("ScreenGui", { Name = "IronframeCockpitHud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20, Enabled = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, playerGui)
    scaler = new("UIScale", {}, overlay)

    -- Soft dark backplate so the compass and status text stay readable over any background
    local plate = new("Frame", { Name = "TopPlate", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(640, 150), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, overlay)
    new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.6, 0.6), NumberSequenceKeypoint.new(1, 1) }) }, plate)

    -- Compass tape (top centre)
    local tape = new("Frame", { Name = "Compass", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10), Size = UDim2.fromOffset(520, 62), BackgroundTransparency = 1, ClipsDescendants = true }, overlay)
    new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.18, 0), NumberSequenceKeypoint.new(0.82, 0), NumberSequenceKeypoint.new(1, 1) }) }, tape)
    local names = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }
    for deg = 0, 355, 5 do
        local major = deg % 15 == 0
        local tick = box(tape, UDim2.fromOffset(0, 26), UDim2.fromOffset(2, if major then 14 else 7), CYAN, if major then 0.1 else 0.45)
        local text: TextLabel? = nil
        if deg % 45 == 0 then
            text = label(tape, names[deg], UDim2.fromOffset(0, 44), UDim2.fromOffset(40, 18), { TextSize = 18, TextColor3 = if deg == 0 then AMBER else WHITE, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0) })
        elseif deg % 15 == 0 then
            text = label(tape, string.format("%03d", deg), UDim2.fromOffset(0, 44), UDim2.fromOffset(40, 18), { TextSize = 14, TextColor3 = DIM_TEXT, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0) })
        end
        table.insert(compass.ticks, { frame = tick, label = text, angle = deg })
    end
    box(overlay, UDim2.new(0.5, -1, 0, 8), UDim2.fromOffset(2, 12), AMBER, 0.05).Name = "CompassIndex"
    widgets.headingValue = label(overlay, "HDG 000", UDim2.new(0.5, 0, 0, 74), UDim2.fromOffset(200, 30), { Font = FONT_TITLE, TextSize = 22, TextColor3 = CYAN, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Center })
    widgets.modeLine = label(overlay, "SYS MODE  GARAGE LINK  /  STATIONARY", UDim2.new(0.5, 0, 0, 102), UDim2.fromOffset(520, 24), { TextSize = 17, TextColor3 = Color3.fromRGB(150, 196, 208), AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Center })

    -- Reticle (centre): minimal brackets and a stabilization ladder
    local reticle = new("Frame", { Name = "Reticle", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(180, 180), BackgroundTransparency = 1 }, overlay)
    for _, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
        local anchor = Vector2.new(c[1], c[2])
        box(reticle, UDim2.fromScale(c[1], c[2]), UDim2.fromOffset(28, 2), CYAN, 0.25).AnchorPoint = anchor
        box(reticle, UDim2.fromScale(c[1], c[2]), UDim2.fromOffset(2, 28), CYAN, 0.25).AnchorPoint = anchor
    end
    box(reticle, UDim2.new(0.5, -1, 0.5, -1), UDim2.fromOffset(3, 3), CYAN, 0.1)
    for _, s in ipairs({ -1, 1 }) do
        box(reticle, UDim2.new(0.5, s * 34 - (if s < 0 then 18 else 0), 0.5, -1), UDim2.fromOffset(18, 2), CYAN, 0.4)
        box(reticle, UDim2.new(0.5, s * 78 - 1, 0.5, -6), UDim2.fromOffset(2, 12), CYAN, 0.55)
    end
    widgets.stab = label(overlay, "STAB  IDLE  /  WEAPONS SAFE", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(300, 20), { TextSize = 15, TextColor3 = DIM_TEXT, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, -122), TextXAlignment = Enum.TextXAlignment.Center })

    -- Boot / status banner
    widgets.banner = label(overlay, "", UDim2.new(0.5, 0, 0.22, 0), UDim2.fromOffset(900, 44), { Font = FONT_TITLE, TextSize = 26, TextColor3 = CYAN, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1 })
    widgets.bootLog = label(overlay, "", UDim2.new(0.5, 0, 0.22, 34), UDim2.fromOffset(560, 150), { TextSize = 19, TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })

    -- Evacuation warning
    local alertGui = new("ScreenGui", { Name = "IronframeCockpitAlert", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 110, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, playerGui)
    new("UIScale", {}, alertGui)
    widgets.alertScale = alertGui:FindFirstChildOfClass("UIScale")
    local warn = new("Frame", { Name = "EvacWarning", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 30 }, alertGui)
    for _, edge in ipairs({ { UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, 14) }, { UDim2.new(0, 0, 1, -14), UDim2.new(1, 0, 0, 14) }, { UDim2.fromScale(0, 0), UDim2.new(0, 14, 1, 0) }, { UDim2.new(1, -14, 0, 0), UDim2.new(0, 14, 1, 0) } }) do
        box(warn, edge[1], edge[2], RED, 0.35).ZIndex = 31
    end
    widgets.evacTitle = label(warn, "EMERGENCY EVACUATION", UDim2.fromScale(0.5, 0.36), UDim2.fromOffset(900, 56), { Font = FONT_TITLE, TextSize = 38, TextColor3 = RED, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 32 })
    widgets.evacSub = label(warn, "PILOT SAFE  /  EJECTING", UDim2.fromScale(0.5, 0.43), UDim2.fromOffset(900, 30), { TextSize = 24, TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 32 })
    widgets.evacFrame = warn

    -- Hint strip
    widgets.hint = label(overlay, "V  Garage view     R  Recenter     Mouse / Arrows  Look     LMB Fire  1-6 Hardpoint  T Reload     X  Test ejection     ALT  Free cursor", UDim2.new(0.5, 0, 1, -34), UDim2.fromOffset(1100, 22), { TextSize = 15, TextColor3 = DIM_TEXT, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Center })

    -- Fade layer (separate gui so it covers everything, including the garage UI)
    local fadeGui = new("ScreenGui", { Name = "IronframeCockpitFade", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100 }, playerGui)
    fade = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, BorderSizePixel = 0, Active = false }, fadeGui)
    widgets.fadeText = label(fade, "", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(500, 30), { Font = FONT_TITLE, TextSize = 18, TextColor3 = CYAN, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1 })
end

local function wrap180(angle: number): number
    return (angle + 180) % 360 - 180
end

-- ---------------------------------------------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------------------------------------------

local built = false
local refreshAccumulator = 0
local dirty = true

function Hud.Build(cockpit, playerGui: PlayerGui)
    if built then
        return
    end
    built = true
    buildOverlay(playerGui)
    local part = function(key: string): Part
        return cockpit.screens[key].part
    end
    buildStructure(makeDisplay("MFD_L", part("MFD_L"), Vector2.new(640, 490), "STRUCTURE"))
    buildReactor(makeDisplay("MFD_C", part("MFD_C"), Vector2.new(480, 490), "REACTOR"))
    buildArmament(makeDisplay("MFD_R", part("MFD_R"), Vector2.new(640, 490), "ARMAMENT"))
    buildDiagnostics(makeDisplay("ConsoleL", part("ConsoleL"), Vector2.new(460, 482), "DIAGNOSTICS"))
    buildSensors(makeDisplay("ConsoleR", part("ConsoleR"), Vector2.new(460, 482), "SENSORS"))
    buildOverhead(makeDisplay("Overhead", part("Overhead"), Vector2.new(1000, 250), "SYSTEMS"))
    Telemetry.Subscribe(function()
        dirty = true
    end)
    local function rescale()
        local camera = workspace.CurrentCamera
        if camera then
            local size = camera.ViewportSize
            scaler.Scale = math.clamp(math.min(size.Y / 1080, size.X / 1600), 0.6, 1.7)
            widgets.alertScale.Scale = scaler.Scale
        end
    end
    rescale()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
    end
end

function Hud.SetOverlayVisible(visible: boolean)
    overlay.Enabled = visible
end

-- state: "OFF" (dark), "BOOT" (progress bar), "ON" (instrument content)
function Hud.SetDisplayState(key: string, state: string, progress: number?)
    local display = displays[key]
    if not display then
        return
    end
    display.state = state
    display.content.Visible = state == "ON"
    display.boot.Visible = state ~= "ON"
    display.bootBar.Size = UDim2.fromScale(if state == "BOOT" then math.clamp(progress or 0, 0, 1) else 0, 1)
    local text = display.boot:FindFirstChild("BootText") :: TextLabel
    text.Text = if state == "BOOT" then "INITIALIZING" else ""
    if state == "ON" then
        dirty = true
    end
end

function Hud.SetDisplayBrightness(brightness: number)
    for _, display in pairs(displays) do
        display.gui.Brightness = 1.5 * brightness
    end
end

function Hud.DisplayKeys(): { string }
    local keys = {}
    for key in pairs(displays) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

function Hud.SetBanner(text: string, color: Color3?, transparency: number?)
    widgets.banner.Text = text
    widgets.banner.TextColor3 = color or CYAN
    widgets.banner.TextTransparency = transparency or 0
end

function Hud.FadeBanner(duration: number)
    TweenService:Create(widgets.banner, TweenInfo.new(duration), { TextTransparency = 1 }):Play()
end

function Hud.SetBootLog(lines: { string })
    widgets.bootLog.Text = table.concat(lines, "\n")
end

function Hud.SetStatusLine(text: string)
    Hud.StatusLine = text
    widgets.modeLine.Text = "SYS MODE  " .. text
    dirty = true
end

function Hud.SetHintVisible(visible: boolean)
    widgets.hint.Visible = visible
end

function Hud.SetEvacuation(mode: string?)
    -- mode: "WARNING", "EVACUATED" or nil (hidden)
    local frame: Frame = widgets.evacFrame
    frame.Visible = mode ~= nil
    widgets.stab.Visible = mode == nil
    if mode == "WARNING" then
        widgets.evacTitle.Text = "EMERGENCY EVACUATION"
        widgets.evacTitle.TextColor3 = RED
        widgets.evacSub.Text = "PILOT SAFE  /  EJECTING"
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("Frame") then
                child.Visible = true
            end
        end
    elseif mode == "EVACUATED" then
        widgets.evacTitle.Text = "PILOT EVACUATED"
        widgets.evacTitle.TextColor3 = CYAN
        widgets.evacSub.Text = "PILOT SAFE  /  MECH DISABLED  /  REBUILD IN PROGRESS"
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("Frame") then
                child.Visible = false -- red edge bars are for the critical warning only
            end
        end
    end
end

-- Pulse for the critical-warning edge bars (called from the mode loop while WARNING is up).
function Hud.PulseEvacuation(t: number)
    local alpha = 0.3 + 0.35 * (0.5 + 0.5 * math.sin(t * 9))
    for _, child in ipairs((widgets.evacFrame :: Frame):GetChildren()) do
        if child:IsA("Frame") then
            child.BackgroundTransparency = alpha
        end
    end
end

-- Fade layer: 0 = clear, 1 = black. `text` is the small caption centred on the fade.
function Hud.SetFade(alpha: number, text: string?)
    fade.BackgroundTransparency = 1 - alpha
    widgets.fadeText.Text = text or ""
    widgets.fadeText.TextTransparency = 1 - math.clamp((alpha - 0.5) * 2, 0, 1)
end

-- Heading in degrees (0 = hangar north / -Z, clockwise)
function Hud.SetHeading(value: number)
    heading = value % 360
end

-- Per-frame cheap animation: compass tape, radar bearing ring and sweep.
function Hud.Step(dt: number, t: number)
    if widgets.stab then
        widgets.stab.Size = UDim2.fromOffset(600,20)
        widgets.stab.Text = string.format("%s | %s | HITS %d",Telemetry.Value("weapons.name","WEAPONS SAFE"),Telemetry.Value("weapons.state","SAFE"),Telemetry.Value("weapons.hits",0))
        widgets.stab.TextColor3 = if Telemetry.Value("weapons.state","") == "ENERGY LOW" then AMBER else CYAN
    end
    if widgets.modeLine then
        widgets.modeLine.Text = string.format("%s  /  %s  %.1f st/s  /  %s", Telemetry.Value("deployment.state", "STOWED"), Telemetry.Value("movement.direction", "STOP"), math.abs(Telemetry.Value("movement.speed", 0)), Telemetry.Value("movement.drive", "IDLE"))
    end
    if not overlay or not overlay.Enabled then
        return
    end
    for _, tick in ipairs(compass.ticks) do
        local offset = wrap180(tick.angle - heading) * PX_PER_DEG
        local visible = math.abs(offset) < 270
        tick.frame.Visible = visible
        if visible then
            tick.frame.Position = UDim2.fromOffset(260 + offset - 1, tick.frame.Position.Y.Offset)
            if tick.label then
                tick.label.Position = UDim2.fromOffset(260 + offset, 44)
            end
        elseif tick.label then
            tick.label.Visible = false
        end
        if visible and tick.label then
            tick.label.Visible = true
        end
    end
    widgets.headingValue.Text = string.format("HDG %03d", math.floor(heading + 0.5) % 360)
    local sensors = displays.ConsoleR
    if sensors and sensors.state == "ON" then
        widgets.sweep.Rotation = (t * 70) % 360
        for _, item in pairs(widgets.bearing) do
            local angle = math.rad(item.angle - heading)
            item.label.Position = UDim2.fromOffset(
                widgets.radarCenter.X + math.sin(angle) * widgets.radarRadius,
                widgets.radarCenter.Y - math.cos(angle) * widgets.radarRadius
            )
        end
    end
    refreshAccumulator += dt
    if refreshAccumulator >= 0.16 then
        refreshAccumulator = 0
        if dirty or Telemetry.Value("pilot.torsoYaw", nil) ~= nil then
            dirty = false
            for _, display in pairs(displays) do
                if display.state == "ON" and display.refresh then
                    display.refresh()
                end
            end
        end
    end
end

-- Hardpoint selection highlight etc. is data-driven; this just pushes the schematic condition colours.
function Hud.SetSectionCondition(id: string, fraction: number)
    local color = if fraction < 0.2 then RED elseif fraction < 0.5 then AMBER else CYAN
    for _, frame in ipairs(sections[id] or {}) do
        frame.BackgroundColor3 = color
        local stroke = frame:FindFirstChildOfClass("UIStroke")
        if stroke then
            stroke.Color = color
        end
    end
end

return Hud
