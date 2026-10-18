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
local Layouts = require(Shared:WaitForChild("CockpitLayouts"))

local Hud = {}

-- Palette (M11C). The two cockpit packages colour every instrument differently: STANDARD amber and green, RECON blue-white. The colours are
-- upvalues set by applyPalette, and the displays are rebuilt (Hud.Rebuild) when the installed package changes, so every label picks up the new set.
local COLORS = Config.COLORS
local FONT_TITLE, FONT_DATA = Enum.Font.Michroma, Enum.Font.RobotoMono
local CYAN, CYAN_DIM, AMBER, RED, WHITE, PANEL, DIM_TEXT = COLORS.cyan, COLORS.cyanDim, COLORS.amber, COLORS.red, COLORS.white, COLORS.panel, Color3.fromRGB(96, 140, 152)
local paletteId = "INDUSTRIAL"
local function rgb(t: { number }): Color3
    return Color3.fromRGB(t[1], t[2], t[3])
end
local function applyPalette(id: string)
    local p = Layouts.Palette(id)
    paletteId = p.name
    CYAN, CYAN_DIM, AMBER, RED, WHITE, PANEL, DIM_TEXT = rgb(p.primary), rgb(p.primaryDim), rgb(p.warn), rgb(p.crit), rgb(p.text), rgb(p.panel), rgb(p.dimText)
end
applyPalette("INDUSTRIAL")

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
    -- M10B: six live damage regions (core, weapon assemblies, legs, reactor housing) from the Telemetry "damage.regions" feed.
    local rows = { { "CORE TORSO", "torso" }, { "L WEAPON ASSY", "armL" }, { "R WEAPON ASSY", "armR" }, { "L LEG ASSY", "legL" }, { "R LEG ASSY", "legR" }, { "REACTOR HOUSING", "reactor" } }
    widgets.structureBars, widgets.structureLabels = {}, {}
    for i, row in ipairs(rows) do
        local y = 8 + (i - 1) * 53
        widgets.structureLabels[row[2]] = label(c, row[1], UDim2.fromOffset(412, y), UDim2.fromOffset(216, 24), { TextSize = 19, TextColor3 = WHITE })
        widgets.structureBars[row[2]] = bar(c, UDim2.fromOffset(412, y + 26), UDim2.fromOffset(204, 14), 1, CYAN)
    end
    widgets.integrity = label(c, "INTEGRITY  ---", UDim2.fromOffset(412, 334), UDim2.fromOffset(216, 26), { TextSize = 20, TextColor3 = WHITE })
    widgets.structureNote = label(c, "ARMOR RATED  /  DAMAGE FEED: STANDBY", UDim2.fromOffset(412, 366), UDim2.fromOffset(216, 70), { TextSize = 18, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    local REGION_OF = { torso = "CORE", armL = "ARM_L", armR = "ARM_R", legL = "LEG_L", legR = "LEG_R", reactor = "REACTOR" }
    display.refresh = function()
        local fractions = Telemetry.Value("damage.regions", nil)
        local worst = 1
        for key, region in pairs(REGION_OF) do
            local f = if fractions then fractions[region] or 1 else 1
            worst = math.min(worst, f)
            setBar(widgets.structureBars[key], f, if f <= 0.25 then RED elseif f <= 0.6 then AMBER else CYAN)
            if key ~= "reactor" then
                Hud.SetSectionCondition(key, f)
            end
        end
        local total = Telemetry.Value("integrity.total", 0)
        widgets.integrity.Text = string.format("INTEGRITY  %.0f", total * (if fractions then fractions.CORE or 1 else 1))
        local speed, reactor = Telemetry.Value("damage.speed", 1), Telemetry.Value("damage.reactor", 1)
        local disabled = Telemetry.Value("damage.disabled", "")
        local notes = {}
        table.insert(notes, if worst >= 0.999 then "ALL ASSEMBLIES NOMINAL" else "DAMAGE FEED: LIVE")
        if speed < 0.999 then table.insert(notes, string.format("DRIVE %d%%", math.floor(speed * 100 + 0.5))) end
        if reactor < 0.999 then table.insert(notes, string.format("REACTOR %d%%", math.floor(reactor * 100 + 0.5))) end
        if disabled ~= "" then table.insert(notes, "OFFLINE: " .. (string.gsub(disabled, "_", " "))) end
        widgets.structureNote.Text = table.concat(notes, "\n")
        widgets.structureNote.TextColor3 = if worst <= 0.25 then RED elseif worst < 0.999 then AMBER else CYAN
        statusTag(display, if fractions then "LIVE" else "STANDBY")
    end
end

-- REACTOR / POWER DISTRIBUTION (centre MFD): profile selector, reactor and capacitor flow, per-subsystem demand
local PROFILE_ORDER = { "MOBILITY", "BALANCED", "WEAPONS" }
local PROFILE_TAG = { MOBILITY = "MOB", BALANCED = "BAL", WEAPONS = "WPN" }
local FOCUS_ROW = { PROPULSION = "prop", WEAPONS = "weapons" }

local function buildReactor(display: Display)
    local c = display.content
    widgets.reactorName = label(c, "CORE ---", UDim2.fromOffset(20, 4), UDim2.fromOffset(440, 24), { TextSize = 19, TextColor3 = DIM_TEXT })
    -- Profile selector: three segments (informational here; the clickable strip lives in the HUD overlay).
    widgets.profSeg = {}
    for i, id in ipairs(PROFILE_ORDER) do
        local seg = box(c, UDim2.fromOffset(20 + (i - 1) * 148, 32), UDim2.fromOffset(140, 34), DIM_TEXT, nil, 1.5)
        local flash = box(seg, UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), AMBER, 1)
        flash.ZIndex = 3
        local text = label(seg, id, UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), { TextSize = 17, TextColor3 = DIM_TEXT, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 4 })
        widgets.profSeg[id] = { frame = seg, stroke = seg:FindFirstChildOfClass("UIStroke"), flash = flash, text = text }
    end
    widgets.profLine = label(c, "PROFILE ---", UDim2.fromOffset(20, 70), UDim2.fromOffset(440, 22), { TextSize = 17, TextColor3 = CYAN })
    widgets.profBar = bar(c, UDim2.fromOffset(20, 94), UDim2.fromOffset(440, 5), 0, CYAN)
    local function gauge(key: string, y: number, title: string, color: Color3)
        label(c, title, UDim2.fromOffset(20, y), UDim2.fromOffset(250, 22), { TextSize = 18, TextColor3 = DIM_TEXT })
        widgets[key .. "Value"] = label(c, "---", UDim2.fromOffset(190, y), UDim2.fromOffset(270, 22), { TextSize = 18, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right })
        widgets[key .. "Bar"] = bar(c, UDim2.fromOffset(20, y + 24), UDim2.fromOffset(440, 10), 0, color)
    end
    gauge("power", 106, "REACTOR  DEMAND / OUTPUT u/s", CYAN)
    gauge("heatGen", 150, "CAPACITOR", CYAN)
    widgets.heatStore = label(c, "STANDBY", UDim2.fromOffset(20, 188), UDim2.fromOffset(440, 20), { TextSize = 16, TextColor3 = DIM_TEXT, TextXAlignment = Enum.TextXAlignment.Right })
    widgets.rows = {}
    local rows = { { "prop", "PROPULSION" }, { "weapons", "WEAPONS" }, { "shield", "SHIELD" }, { "avionics", "AVIONICS" } }
    for i, row in ipairs(rows) do
        local y = 208 + (i - 1) * 40
        label(c, row[2], UDim2.fromOffset(20, y), UDim2.fromOffset(150, 22), { TextSize = 18, TextColor3 = WHITE })
        local tag = label(c, "", UDim2.fromOffset(160, y), UDim2.fromOffset(180, 22), { TextSize = 15, TextColor3 = CYAN, TextXAlignment = Enum.TextXAlignment.Right })
        local value = label(c, "---", UDim2.fromOffset(340, y), UDim2.fromOffset(120, 22), { TextSize = 18, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right })
        widgets.rows[row[1]] = { tag = tag, value = value, bar = bar(c, UDim2.fromOffset(20, y + 25), UDim2.fromOffset(440, 8), 0, CYAN) }
    end
    gauge("cooling", 372, "THERMAL LOAD %", AMBER)
    widgets.energyWarning = label(c, "", UDim2.fromOffset(20, 424), UDim2.fromOffset(440, 44), { TextSize = 16, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        local m = Telemetry.Value("loadout.metrics", nil)
        local systems = Telemetry.Value("loadout.systems", {})
        local output = Telemetry.Value("energy.output", 0)
        if m then
            local reactor = Components[systems.reactor or ""]
            widgets.reactorName.Text = "CORE  " .. string.upper(reactor and reactor.name or "UNKNOWN") .. "   POWER DISTRIBUTION"
            local demand = Telemetry.Value("energy.demand", 0)
            local charge, capacity = Telemetry.Value("energy.charge", 0), Telemetry.Value("energy.capacity", 160)
            local thermal, deficit = Telemetry.Value("energy.thermal", 0), Telemetry.Value("energy.deficit", 0)
            widgets.powerValue.Text = string.format("%.1f / %.1f", demand, output)
            setBar(widgets.powerBar, demand / math.max(output, 1), if demand > output then AMBER else CYAN)
            widgets.heatGenValue.Text = string.format("%.0f / %.0f", charge, capacity)
            setBar(widgets.heatGenBar, charge / math.max(capacity, 1), if charge < 25 then AMBER else CYAN)
            widgets.coolingValue.Text = string.format("%.1f%%", thermal)
            setBar(widgets.coolingBar, thermal / 100, AMBER)
            local flow = Telemetry.Value("energy.capRate", 0)
            widgets.heatStore.Text = string.format("%s  %+.1f u/s   SUPPLY %.1f", if flow > 0.5 then "CHARGING" elseif flow < -0.5 then "DISCHARGING" else "HOLDING", flow, Telemetry.Value("energy.supply", 0))
            widgets.heatStore.TextColor3 = if flow < -0.5 then AMBER else CYAN
            local limited = Telemetry.Value("energy.limited", "")
            if Telemetry.Value("avionics.factor", 1) < 0.7 and Telemetry.Value("avionics.demand", 0) > 0.05 then
                limited = if limited == "" then "AVIONICS" else limited .. "+AVIONICS"
            end
            local focus = FOCUS_ROW[Telemetry.Value("energy.focus", "")]
            local function row(key: string, demandValue: number, name: string, extra: string)
                local w = widgets.rows[key]
                w.value.Text = string.format("%.1f u/s", demandValue)
                local isLimited = string.find(limited, name, 1, true) ~= nil
                setBar(w.bar, demandValue / math.max(output, 1), if isLimited then AMBER else CYAN)
                local text, color = extra, CYAN
                if isLimited then text, color = "LIMITED  " .. extra, AMBER
                elseif focus == key then text = "PRIORITY  " .. extra end
                w.tag.Text, w.tag.TextColor3 = text, color
            end
            local sprint = Telemetry.Value("energy.sprintDemand", 0)
            row("prop", Telemetry.Value("energy.propulsion", 0), "SPRINT", if sprint > 0.5 then string.format("SPRINT %.0f", sprint) else "")
            row("weapons", math.max(Telemetry.Value("energy.weaponRate", 0), Telemetry.Value("energy.weaponDemand", 0)), "WEAPONS", Telemetry.Value("weapons.state", "SAFE"))
            row("shield", Telemetry.Value("energy.shieldDemand", 0), "SHIELD", Telemetry.Value("shield.state", "READY"))
            local avFactor = Telemetry.Value("avionics.factor", 1)
            local avDemand = Telemetry.Value("avionics.demand", 0)
            local avSpec = Telemetry.Value("avionics.spec", nil)
            row("avionics", avDemand * avFactor, "AVIONICS", if avDemand <= 0.05 and not (avSpec and avSpec.ratedPower > 0) then "NOT FITTED" elseif avDemand <= 0.05 then "STANDBY" elseif avFactor < 0.7 then string.format("STARVED %d%%", math.floor(avFactor * 100 + 0.5)) else string.format("%.1f REQ", avDemand))
            local reason = Telemetry.Value("shield.reason", "READY")
            widgets.energyWarning.Text = if limited == "AVIONICS" then "SENSORS STARVED  /  ADVANCED AVIONICS DEGRADED"
                elseif deficit > 0.1 then string.format("DEFICIT %.1f u/s  /  %s THROTTLED", deficit, if limited ~= "" then limited else "DISCRETIONARY LOADS")
                elseif limited ~= "" then string.format("%s HELD BY %s PROFILE", limited, Telemetry.Value("energy.profile", "BALANCED"))
                elseif charge < 25 then "CAPACITOR LOW  /  SHIELD UNAVAILABLE" else reason
        end
        local active, pending = Telemetry.Value("energy.profile", nil), Telemetry.Value("energy.profilePending", "")
        if active then
            local eta = Telemetry.Value("energy.profileEta", 0)
            local ack = os.clock() - (widgets.ackAt or -10) < 1.6
            widgets.profLine.Text = if pending ~= "" then string.format("ALLOCATING  %s  >  %s   %.1fs", active, pending, eta)
                elseif ack then string.format("ACKNOWLEDGED  /  %s PRIORITY ONLINE", active)
                else string.format("%s  /  %s", active, Telemetry.Value("energy.profileReason", "ACTIVE"))
            widgets.profLine.TextColor3 = if pending ~= "" then AMBER else CYAN
        else widgets.profLine.Text = "PROFILE  STANDBY  /  DEPLOY TO ENABLE" end
        statusTag(display, Telemetry.Get("energy.charge").status)
    end
end

-- Cheap per-frame segment animation: active glows amber, pending pulses cyan, a switch acknowledges with one soft flash.
local function animateProfile(t: number)
    if not widgets.profSeg then return end
    local active, pending = Telemetry.Value("energy.profile", nil), Telemetry.Value("energy.profilePending", "")
    local serial = Telemetry.Value("energy.profileSerial", 0)
    if widgets.lastSerial ~= serial then
        if widgets.lastSerial ~= nil and serial > 0 then widgets.ackAt = t end
        widgets.lastSerial = serial
    end
    local flash = math.clamp(1 - (t - (widgets.ackAt or -10)) / 0.7, 0, 1)
    local pulse = 0.5 + 0.5 * math.sin(t * 10)
    for id, seg in pairs(widgets.profSeg) do
        if id == active then
            seg.stroke.Color, seg.text.TextColor3 = AMBER, AMBER
            seg.stroke.Transparency = 0
            seg.frame.BackgroundColor3, seg.frame.BackgroundTransparency = AMBER, 0.82
            seg.flash.BackgroundTransparency = 1 - 0.55 * flash
        elseif id == pending then
            seg.stroke.Color, seg.text.TextColor3 = CYAN, CYAN
            seg.stroke.Transparency = 0.7 - 0.7 * pulse
            seg.frame.BackgroundTransparency, seg.flash.BackgroundTransparency = 1, 1
        else
            seg.stroke.Color, seg.text.TextColor3 = DIM_TEXT, DIM_TEXT
            seg.stroke.Transparency = 0.35
            seg.frame.BackgroundTransparency, seg.flash.BackgroundTransparency = 1, 1
        end
    end
    local eta = Telemetry.Value("energy.profileEta", 0)
    setBar(widgets.profBar, if pending ~= "" then 1 - eta / 0.5 else (if active then 1 else 0), if pending ~= "" then AMBER else CYAN)
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

-- Avionics state (M11C) --------------------------------------------------------------------------------------------------------
-- The AvionicsClient publishes the latest server packet on the bus ("avionics.state"). Everything below reads it; nothing is animated for show.
local BAND_SEGMENTS = { NOMINAL = 3, DAMAGED = 2, CRITICAL = 1, OFFLINE = 0 }
local chassisHeading = 0
local radarScaleIndex = 1
local RADAR_SCALES = { 1, 0.5, 0.25 }

local function avState(): any?
    return Telemetry.Value("avionics.state", nil)
end

local function bandColor(band: string): Color3
    return if band == "NOMINAL" then CYAN elseif band == "DAMAGED" then AMBER else RED
end

-- A component row: name, condition word and a three-segment bar (segments are the band, never a hidden number).
local function buildBandRows(parent: Instance, count: number, x: number, y0: number, step: number, width: number, textSize: number): { any }
    local rows = {}
    for i = 1, count do
        local y = y0 + (i - 1) * step
        local name = label(parent, "", UDim2.fromOffset(x, y), UDim2.fromOffset(width * 0.5, step - 2), { TextSize = textSize, TextColor3 = WHITE })
        local band = label(parent, "", UDim2.fromOffset(x + width * 0.5, y), UDim2.fromOffset(width * 0.32, step - 2), { TextSize = textSize - 2, TextColor3 = CYAN, TextXAlignment = Enum.TextXAlignment.Right })
        local segs = {}
        for k = 1, 3 do
            segs[k] = box(parent, UDim2.fromOffset(x + width * 0.86 + (k - 1) * (width * 0.05), y + (step - 2) * 0.5 - 4), UDim2.fromOffset(width * 0.04, 8), CYAN, 0.1)
        end
        rows[i] = { name = name, band = band, segs = segs }
    end
    return rows
end

local function fillBandRows(rows: { any }, parts: { any }?)
    for i, row in ipairs(rows) do
        local part = parts and parts[i]
        row.name.Visible, row.band.Visible = part ~= nil, part ~= nil
        for _, seg in ipairs(row.segs) do
            seg.Visible = part ~= nil
        end
        if part then
            local color = bandColor(part[2])
            row.name.Text, row.band.Text = part[1], part[2]
            row.band.TextColor3 = color
            local filled = BAND_SEGMENTS[part[2]] or 0
            for k, seg in ipairs(row.segs) do
                seg.BackgroundColor3 = color
                seg.BackgroundTransparency = if k <= filled then 0.1 else 0.85
            end
        end
    end
end

local function relBearing(bearing: number): number
    return (bearing - chassisHeading + 180) % 360 - 180
end

local function trackerLine(st: any): (string, Color3)
    local tr = st and st.tr
    if not tr then
        return "TRACKER  NOT FITTED", DIM_TEXT
    end
    local detail = if tr.dt >= 2 then "COMPONENT" elseif tr.dt == 1 then "STATUS" else "NONE"
    if not tr.av then
        return "TRACKER  OFFLINE  /  LOW POWER", RED
    end
    return string.format("TRACKER  RNG %d  /  ANALYSIS %s%s", tr.r, detail, if tr.dg then "  /  LIMITED" else ""), if tr.dg then AMBER else CYAN
end

-- TARGETING (left console): the locked target as the server tracker reports it. On the recon package the component analysis moves to its own display.
local function buildTargeting(display: Display, compact: boolean)
    local c = display.content
    widgets.tgtMode = label(c, "TRACKER  ---", UDim2.fromOffset(18, 6), UDim2.new(1, -30, 0, 24), { TextSize = 17, TextColor3 = DIM_TEXT })
    widgets.tgtId = label(c, "NO TARGET", UDim2.fromOffset(18, 34), UDim2.new(1, -30, 0, 36), { Font = FONT_TITLE, TextSize = 26, TextColor3 = WHITE })
    widgets.tgtLines = label(c, "", UDim2.fromOffset(18, 78), UDim2.new(1, -30, 0, 112), { TextSize = 19, TextColor3 = CYAN, TextYAlignment = Enum.TextYAlignment.Top })
    widgets.tgtSolution = label(c, "", UDim2.fromOffset(18, 196), UDim2.new(1, -30, 0, 24), { TextSize = 19, TextColor3 = CYAN })
    widgets.tgtWeapon = label(c, "", UDim2.fromOffset(18, 222), UDim2.new(1, -30, 0, 24), { TextSize = 17, TextColor3 = DIM_TEXT })
    widgets.tgtCompact = compact
    widgets.tgtRows = if compact then {} else buildBandRows(c, 6, 18, 256, 28, 424, 18)
    widgets.tgtFoot = label(c, "", UDim2.fromOffset(18, if compact then 262 else 428), UDim2.new(1, -30, 0, if compact then 190 else 48), { TextSize = 16, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        local st = avState()
        local lock = st and st.lock
        local line, color = trackerLine(st)
        widgets.tgtMode.Text, widgets.tgtMode.TextColor3 = line, color
        if lock and lock.nm then
            widgets.tgtId.Text = string.format("%s%s", lock.nm, if lock.ar then "  " .. lock.ar else "")
            widgets.tgtId.TextColor3 = if lock.st == "TRACK" then WHITE elseif lock.st == "COAST" then AMBER else RED
            local rel = relBearing(lock.b)
            local thermalLine = ""
            if st.th and st.th.on and lock.lv then
                thermalLine = string.format("\nTHERMAL  %s %.2f", if lock.lv >= 0.7 then "HOT" elseif lock.lv >= 0.4 then "WARM" elseif lock.lv >= 0.15 then "COOL" else "COLD", lock.lv)
            end
            widgets.tgtLines.Text = string.format("RANGE    %d ST\nBEARING  %03d   REL %+d\nSPEED    %.1f ST/S   HDG %03d\nSTATUS   %s%s", lock.d, lock.b, rel, lock.sp, lock.hd,
                if lock.ss == 3 then "DESTROYED" elseif lock.ss == 2 then "DISABLED" else "ACTIVE", thermalLine)
            widgets.tgtLines.TextColor3 = CYAN
            widgets.tgtSolution.Text = "SOLUTION  " .. (lock.rs or "TRACK")
            widgets.tgtSolution.TextColor3 = if lock.st == "TRACK" then CYAN elseif lock.st == "COAST" then AMBER else RED
            widgets.tgtWeapon.Text = if lock.wr == nil then "WEAPON  ---" elseif lock.wr then "WEAPON  TARGET IN RANGE" else "WEAPON  OUT OF RANGE"
            widgets.tgtWeapon.TextColor3 = if lock.wr then CYAN else AMBER
            if compact then
                widgets.tgtFoot.Text = if lock.cm then "COMPONENT ANALYSIS  >  TARGET ANALYSIS DISPLAY" else "STATUS ONLY  /  COMPONENT ANALYSIS NOT AVAILABLE"
            else
                fillBandRows(widgets.tgtRows, lock.cm)
                widgets.tgtFoot.Text = if lock.cm then "" else "STATUS ONLY  /  COMPONENT ANALYSIS NOT FITTED"
            end
        else
            fillBandRows(widgets.tgtRows, nil)
            widgets.tgtId.Text, widgets.tgtId.TextColor3 = "NO TARGET", DIM_TEXT
            local contacts = st and st.c or {}
            local nearest = contacts[1]
            widgets.tgtLines.Text = string.format("L  ACQUIRE TARGET IN SIGHT\nCONTACTS  %d%s", #contacts,
                if nearest then string.format("\nNEAREST  %s  %d ST  BRG %03d", nearest.nm or "UNKNOWN", nearest.d, nearest.b) else "")
            widgets.tgtLines.TextColor3 = DIM_TEXT
            widgets.tgtSolution.Text = ""
            widgets.tgtWeapon.Text = ""
            widgets.tgtFoot.Text = st and st.ms or ""
        end
        statusTag(display, if st then "LIVE" else "STANDBY")
    end
end

-- TARGET ANALYSIS (recon aux display): the component condition of the locked target, as bands, plus its thermal signature.
local function buildAnalysis(display: Display)
    local c = display.content
    widgets.anId = label(c, "NO TARGET", UDim2.fromOffset(18, 4), UDim2.new(1, -30, 0, 36), { Font = FONT_TITLE, TextSize = 26, TextColor3 = WHITE })
    widgets.anRows = buildBandRows(c, 6, 18, 44, 34, 560, 27)
    widgets.anSig = label(c, "SIGNATURE  ---", UDim2.fromOffset(18, 256), UDim2.new(1, -30, 0, 28), { TextSize = 23, TextColor3 = DIM_TEXT })
    widgets.anSigBar = bar(c, UDim2.fromOffset(18, 288), UDim2.fromOffset(560, 14), 0, AMBER)
    widgets.anNote = label(c, "", UDim2.fromOffset(18, 312), UDim2.new(1, -30, 0, 100), { TextSize = 22, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        local st = avState()
        local lock = st and st.lock
        if lock and lock.nm then
            widgets.anId.Text, widgets.anId.TextColor3 = lock.nm, if lock.st == "TRACK" then WHITE else AMBER
            fillBandRows(widgets.anRows, lock.cm)
            local thermalOn = st.th and st.th.on and lock.lv
            widgets.anSig.Text = if thermalOn then string.format("THERMAL SIGNATURE  %.2f", lock.lv) else "THERMAL SIGNATURE  IMAGER OFF"
            setBar(widgets.anSigBar, if thermalOn then lock.lv else 0, if thermalOn and lock.lv >= 0.7 then RED elseif thermalOn then AMBER else DIM_TEXT)
            widgets.anNote.Text = if lock.cm then "" else "COMPONENT ANALYSIS UNAVAILABLE  /  TRACKER LIMITED"
        else
            widgets.anId.Text, widgets.anId.TextColor3 = "NO TARGET", DIM_TEXT
            fillBandRows(widgets.anRows, nil)
            widgets.anSig.Text = "SIGNATURE  ---"
            setBar(widgets.anSigBar, 0, DIM_TEXT)
            widgets.anNote.Text = "ACQUIRE A TARGET (L) TO ANALYSE ITS COMPONENTS"
        end
        statusTag(display, if st and st.tr then "LIVE" else "STANDBY")
    end
end

-- SENSOR ARRAY (recon aux display): every installed module, its real state, and what the avionics bus is delivering.
local function buildArray(display: Display)
    local c = display.content
    widgets.arrLines = label(c, "", UDim2.fromOffset(18, 6), UDim2.new(1, -30, 0, 190), { TextSize = 25, TextColor3 = CYAN, TextYAlignment = Enum.TextYAlignment.Top })
    widgets.arrBus = label(c, "AVIONICS BUS", UDim2.fromOffset(18, 204), UDim2.new(1, -30, 0, 28), { TextSize = 22, TextColor3 = WHITE })
    widgets.arrBusBar = bar(c, UDim2.fromOffset(18, 236), UDim2.fromOffset(560, 14), 0, CYAN)
    widgets.arrNotes = label(c, "", UDim2.fromOffset(18, 262), UDim2.new(1, -30, 0, 150), { TextSize = 22, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    display.refresh = function()
        local st = avState()
        local spec = Telemetry.Value("avionics.spec", nil)
        local lines = {}
        local function add(name: string, state: string)
            table.insert(lines, string.format("%-9s %s", name, state))
        end
        if spec then
            add("RADAR", if st and st.rd then string.format("%s %s  %d ST", st.rd.m, st.rd.s, st.rd.r) elseif spec.radar then "STANDBY" else "NOT FITTED")
            add("OPTICS", if spec.optics then string.format("%.0fX MAX  %s", spec.optics.magnifications[#spec.optics.magnifications], if st and st.zm and st.zm > 1 then string.format("ACTIVE %.0fX", st.mag) else "1X") else "NOT FITTED")
            add("THERMAL", if not spec.thermal then "NOT FITTED" elseif st and st.th then (if st.th.on then "IMAGING" elseif st.th.av then "READY" else st.th.why) else "STANDBY")
            add("TRACKER", if not spec.tracker then "NOT FITTED" elseif st and st.tr then (if not st.tr.av then "OFFLINE" elseif st.lock then "LOCKED" else "READY") else "STANDBY")
            add("BAYS", string.format("%d / %d USED", Telemetry.Value("avionics.baysUsed", 0), Telemetry.Value("avionics.bays", 0)))
            add("RATED", string.format("%.1f U/S   MASS %.1f T", spec.ratedPower, spec.mass))
        end
        widgets.arrLines.Text = table.concat(lines, "\n")
        local demand, factor = Telemetry.Value("avionics.demand", 0), Telemetry.Value("avionics.factor", 1)
        widgets.arrBus.Text = string.format("AVIONICS BUS  %.1f U/S  /  %d%% DELIVERED", demand, math.floor(factor * 100 + 0.5))
        setBar(widgets.arrBusBar, factor, if factor < 0.7 then AMBER else CYAN)
        local notes = st and st.notes
        widgets.arrNotes.Text = if notes and #notes > 0 then table.concat(notes, "\n") else "ALL INSTALLED SENSORS NOMINAL"
        widgets.arrNotes.TextColor3 = if notes and #notes > 0 then AMBER else CYAN
        statusTag(display, if st then "LIVE" else "STANDBY")
    end
end

-- SENSORS (right console): the radar. Contacts come from the server's sensor model (SensorModel), refreshed at the radar's real scan rate; the
-- display only rotates them against the machine's heading each frame. Up is the mech's heading.
local SCOPE, CENTER = 340, 170
local BLIPS = 10
local function buildSensors(display: Display)
    local c = display.content
    local cx, cy = 230, 190
    local scope = new("Frame", { Position = UDim2.fromOffset(cx - SCOPE / 2, cy - SCOPE / 2 + 4), Size = UDim2.fromOffset(SCOPE, SCOPE), BackgroundColor3 = CYAN_DIM, BackgroundTransparency = 0.9, BorderSizePixel = 0 }, c)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, scope)
    new("UIStroke", { Color = CYAN, Thickness = 2 }, scope)
    widgets.rings = {}
    for _, f in ipairs({ 0.66, 0.33 }) do
        local ring = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(f, f), BackgroundTransparency = 1 }, scope)
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
        new("UIStroke", { Color = CYAN, Thickness = 1, Transparency = 0.6 }, ring)
        widgets.rings[f] = label(scope, "", UDim2.fromOffset(CENTER + 4, CENTER - f * SCOPE / 2 + 1), UDim2.fromOffset(60, 16), { TextSize = 15, TextColor3 = DIM_TEXT })
    end
    box(scope, UDim2.fromScale(0.5, 0), UDim2.new(0, 1, 1, 0), CYAN, 0.7)
    box(scope, UDim2.fromScale(0, 0.5), UDim2.new(1, 0, 0, 1), CYAN, 0.7)
    -- the mech: heading is straight up
    box(scope, UDim2.new(0.5, -6, 0, 6), UDim2.fromOffset(12, 4), AMBER, 0.1)
    local ship = box(scope, UDim2.fromOffset(CENTER - 4, CENTER - 4), UDim2.fromOffset(8, 8), WHITE, 0.05)
    ship.Rotation = 45
    -- a real scan ping: expands once per radar return (the AvionicsClient raises it when a packet carries a fresh scan)
    widgets.ping = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0, 0), BackgroundTransparency = 1 }, scope)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, widgets.ping)
    widgets.pingStroke = new("UIStroke", { Color = CYAN, Thickness = 2, Transparency = 1 }, widgets.ping)
    -- camera direction on the rim (where the pilot is looking, relative to the machine)
    widgets.view = box(scope, UDim2.fromOffset(CENTER, CENTER), UDim2.fromOffset(18, 4), AMBER, 0.2)
    widgets.view.AnchorPoint = Vector2.new(0.5, 0.5)
    widgets.bearing = {}
    for _, spec in ipairs({ { "N", 0 }, { "E", 90 }, { "S", 180 }, { "W", 270 } }) do
        widgets.bearing[spec[1]] = { angle = spec[2], label = label(c, spec[1], UDim2.fromOffset(0, 0), UDim2.fromOffset(30, 30), { TextSize = 22, TextColor3 = if spec[1] == "N" then AMBER else WHITE, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center }) }
    end
    widgets.radarCenter = Vector2.new(cx, cy + 4)
    widgets.radarRadius = SCOPE / 2 + 22
    widgets.blips = {}
    for i = 1, BLIPS do
        local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(26, 26), BackgroundTransparency = 1, Visible = false, ZIndex = 5 }, scope)
        local dir = box(holder, UDim2.fromOffset(12, -4), UDim2.fromOffset(2, 12), WHITE, 0.2) -- heading tick (only where the radar resolves heading)
        dir.Visible = false
        local shape = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(11, 11), BackgroundColor3 = CYAN, BackgroundTransparency = 0.05, BorderSizePixel = 0, ZIndex = 6 }, holder)
        local stroke = new("UIStroke", { Color = CYAN, Thickness = 1.5 }, shape)
        local glyph = label(holder, "", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(26, 26), { AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 20, TextColor3 = RED, ZIndex = 8 })
        local lockRing = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1, Visible = false, ZIndex = 7 }, holder)
        new("UIStroke", { Color = WHITE, Thickness = 1.5 }, lockRing)
        local text = label(scope, "", UDim2.fromOffset(0, 0), UDim2.fromOffset(140, 18), { TextSize = 16, TextColor3 = WHITE, ZIndex = 9, Visible = false, Font = Enum.Font.RobotoMono })
        widgets.blips[i] = { holder = holder, dir = dir, shape = shape, stroke = stroke, glyph = glyph, lock = lockRing, text = text }
    end
    widgets.radarInfo = label(c, "RADAR ---", UDim2.fromOffset(18, 370), UDim2.new(1, -30, 0, 24), { TextSize = 19, TextColor3 = CYAN })
    widgets.radarInfo2 = label(c, "", UDim2.fromOffset(18, 396), UDim2.new(1, -30, 0, 24), { TextSize = 19, TextColor3 = WHITE })
    widgets.radarInfo3 = label(c, "", UDim2.fromOffset(18, 422), UDim2.new(1, -30, 0, 40), { TextSize = 16, TextColor3 = AMBER, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    widgets.radarDirty = true
    widgets.noRadar = label(scope, "NO RADAR FITTED", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(300, 30), { AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 22, TextColor3 = DIM_TEXT, Visible = false, ZIndex = 10 })
    display.refresh = function()
        local st = avState()
        local rd = st and st.rd
        local spec = Telemetry.Value("avionics.spec", nil)
        widgets.noRadar.Visible = spec ~= nil and spec.radar == nil
        if rd then
            widgets.radarInfo.Text = string.format("%s %s  RNG %d ST  %.1f SCANS/S", rd.m, rd.s, rd.r, 1 / math.max(rd.i, 0.05))
            widgets.radarInfo.TextColor3 = if rd.s == "ONLINE" then CYAN else AMBER
        else
            widgets.radarInfo.Text = if spec and spec.radar then "RADAR STANDBY" else "RADAR NOT FITTED"
            widgets.radarInfo.TextColor3 = DIM_TEXT
        end
        local contacts = st and st.c or {}
        local scale = RADAR_SCALES[radarScaleIndex]
        local reach = if rd then rd.r * scale else 0
        widgets.radarInfo2.Text = string.format("CONTACTS %d   SCALE %d ST   [O]", #contacts, reach)
        widgets.radarInfo3.Text = (if st and st.notes and #st.notes > 0 then table.concat(st.notes, "  /  ") else "") .. (if st and st.ms then "\n" .. st.ms else "")
        for f, ring in pairs(widgets.rings) do
            ring.Text = if reach > 0 then string.format("%d", reach * f) else ""
        end
        widgets.radarDirty = true
        statusTag(display, if st then "LIVE" else "STANDBY")
    end
end

-- Positions the blips against the current chassis heading. Called every frame while the display is on; it writes properties only when the heading
-- moved by more than 0.15 degrees or a new packet arrived.
local lastHeadingDrawn = 1e9
local function placeBlips()
    if not widgets.blips then
        return
    end
    if not widgets.radarDirty and math.abs(((chassisHeading - lastHeadingDrawn) + 180) % 360 - 180) < 0.15 then
        return
    end
    lastHeadingDrawn = chassisHeading
    widgets.radarDirty = false
    local st = avState()
    local rd = st and st.rd
    local contacts = st and st.c or {}
    local reach = (if rd then rd.r else 1) * RADAR_SCALES[radarScaleIndex]
    local lockName = st and st.lock and st.lock.nm
    for i, blip in ipairs(widgets.blips) do
        local contact = contacts[i]
        if not contact or not rd then
            blip.holder.Visible, blip.text.Visible = false, false
        else
            local rel = math.rad(relBearing(contact.b))
            local r = contact.d / math.max(reach, 1)
            local outside = r > 1
            r = math.min(r, 1.02)
            local x, y = CENTER + math.sin(rel) * r * CENTER, CENTER - math.cos(rel) * r * CENTER
            blip.holder.Position = UDim2.fromOffset(x, y)
            blip.holder.Visible = true
            local identified = contact.nm ~= nil
            local color = if contact.ss == 3 then RED elseif contact.ss == 2 then AMBER else CYAN
            local fade = if contact.sl then 0.65 elseif outside then 0.55 else 0
            blip.shape.BackgroundColor3 = color
            blip.stroke.Color = color
            blip.shape.BackgroundTransparency = if identified and contact.ss == 1 then 0.05 + fade * 0.9 else 1
            blip.stroke.Transparency = fade
            blip.shape.Rotation = if contact.kd == 2 then 45 else 0
            blip.shape.Size = if contact.kd == 2 then UDim2.fromOffset(10, 10) else UDim2.fromOffset(11, 11)
            blip.glyph.Text = if contact.ss == 3 then "X" elseif contact.ss == 2 then "x" else ""
            blip.glyph.TextColor3 = color
            blip.glyph.TextTransparency = fade
            if contact.hd and contact.mv then
                blip.dir.Visible = true
                blip.holder.Rotation = relBearing(contact.hd)
                blip.dir.BackgroundColor3 = color
            else
                blip.dir.Visible = false
                blip.holder.Rotation = 0
            end
            blip.lock.Visible = lockName ~= nil and contact.nm == lockName
            blip.text.Visible = true
            blip.text.Position = UDim2.fromOffset(x + 11, y - 8)
            blip.text.Text = string.format("%s %d%s", contact.nm or "UNK", contact.d, if contact.sl then " ?" else "")
            blip.text.TextColor3 = color
            blip.text.TextTransparency = fade
        end
    end
end

-- OVERHEAD: system list. Every line is read from live state: nothing here is a static label.
local function buildOverhead(display: Display)
    local c = display.content
    local systems = {
        { "REACTOR", "reactor" }, { "COOLING", "cooling" }, { "HYDRAULICS", "hydraulics" }, { "EJECTION", "ejection" },
        { "LOCOMOTION", "drive" }, { "SENSORS", "sensors" }, { "TARGETING", "targeting" }, { "FIRE CONTROL", "fire" },
    }
    widgets.overheadItems = {}
    for i, sys in ipairs(systems) do
        local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
        local x = 20 + col * 238
        local y = 14 + row * 38
        local dot = box(c, UDim2.fromOffset(x, y + 8), UDim2.fromOffset(12, 12), CYAN, 0.1)
        label(c, sys[1], UDim2.fromOffset(x + 22, y), UDim2.fromOffset(128, 28), { TextSize = 18, TextColor3 = WHITE })
        local state = label(c, "---", UDim2.fromOffset(x + 142, y), UDim2.fromOffset(90, 28), { TextSize = 16, TextColor3 = CYAN })
        widgets.overheadItems[i] = { dot = dot, state = state, kind = sys[2] }
    end
    widgets.overheadStatus = label(c, "IF-42 BASTION", UDim2.fromOffset(20, 96), UDim2.new(1, -40, 0, 30), { Font = FONT_TITLE, TextSize = 20, TextColor3 = CYAN })
    widgets.overheadBuild = label(c, "", UDim2.fromOffset(20, 140), UDim2.new(1, -40, 0, 30), { TextSize = 17, TextColor3 = DIM_TEXT })
    display.refresh = function()
        local m = Telemetry.Value("loadout.metrics", nil)
        local st = avState()
        local thermal = Telemetry.Value("energy.thermal", 0)
        for _, item in ipairs(widgets.overheadItems) do
            local text, level = "STANDBY", 3 -- level: 0 ok, 1 caution, 2 fault, 3 not available
            if m then
                if item.kind == "reactor" then
                    local factor = Telemetry.Value("damage.reactor", 1)
                    text, level = Telemetry.Value("reactor.state", "STANDBY"), 0
                    if factor < 0.999 then
                        text, level = string.format("%d%%", math.floor(factor * 100 + 0.5)), if factor <= 0.5 then 2 else 1
                    end
                elseif item.kind == "cooling" then
                    text, level = if thermal >= 90 then "OVERHEAT" elseif thermal >= 70 then "HOT" else "NOMINAL", if thermal >= 90 then 2 elseif thermal >= 70 then 1 else 0
                elseif item.kind == "hydraulics" then
                    local speed = Telemetry.Value("damage.speed", 1)
                    text, level = if speed < 0.999 then string.format("%d%%", math.floor(speed * 100 + 0.5)) else "NOMINAL", if speed <= 0.5 then 2 elseif speed < 0.999 then 1 else 0
                elseif item.kind == "ejection" then
                    local state = Telemetry.Value("mech.state", "OPERATIONAL")
                    text, level = if state == "OPERATIONAL" then "ARMED" else "ACTIVE", 0
                elseif item.kind == "drive" then
                    text, level = Telemetry.Value("movement.drive", "IDLE"), 0
                elseif item.kind == "sensors" then
                    local rd = st and st.rd
                    text = if rd then rd.s else (if Telemetry.Value("avionics.hasRadar", false) then "STANDBY" else "NOT FITTED")
                    level = if rd and rd.s == "ONLINE" then 0 elseif rd then 1 else 3
                elseif item.kind == "targeting" then
                    local tr = st and st.tr
                    if not tr then
                        text, level = "NOT FITTED", 3
                    elseif not tr.av then
                        text, level = "OFFLINE", 2
                    elseif st.lock and st.lock.nm then
                        text, level = string.sub("LOCK " .. st.lock.nm, 1, 11), if st.lock.st == "TRACK" then 0 else 1
                    else
                        text, level = "READY", 0
                    end
                elseif item.kind == "fire" then
                    local w = Telemetry.Value("weapons.state", "SAFE")
                    text, level = w, if w == "ENERGY LOW" or w == "RESERVED" then 1 else 0
                end
            end
            item.state.Text = text
            local color = if level == 0 then CYAN elseif level == 1 then AMBER elseif level == 2 then RED else DIM_TEXT
            item.state.TextColor3 = color
            item.dot.BackgroundColor3 = color
            item.dot.BackgroundTransparency = if level == 3 then 0.6 else 0.1
        end
        widgets.overheadStatus.Text = string.format("SHIELD %s / %.1fs / %s", Telemetry.Value("shield.state", "READY"), Telemetry.Value("shield.cooldown", 0), Telemetry.Value("shield.timing", "AWAITING IMPACT"))
        widgets.overheadBuild.Text = Telemetry.Value("avionics.label", "")
        statusTag(display, "LIVE")
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- ScreenGui overlay
-- ---------------------------------------------------------------------------------------------------------------

local overlay: ScreenGui, scaler: UIScale
local fade: Frame
local guis: { Instance } = {}
local subscription: (() -> ())? = nil
local viewportConn: RBXScriptConnection? = nil
local compass = { strip = nil :: Frame?, ticks = {} :: { { frame: Frame, label: TextLabel?, angle: number } } }
local heading = 0
local PX_PER_DEG = 4.2

local function buildOverlay(playerGui: PlayerGui)
    overlay = new("ScreenGui", { Name = "IronframeCockpitHud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20, Enabled = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, playerGui)
    scaler = new("UIScale", {}, overlay)
    table.insert(guis, overlay)

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
    widgets.zoomText = label(overlay, "", UDim2.new(0.5, 100, 0.5, -10), UDim2.fromOffset(160, 22), { TextSize = 17, TextColor3 = AMBER, TextXAlignment = Enum.TextXAlignment.Left })
    widgets.avLine = label(overlay, "", UDim2.new(0.5, 0, 0.5, 100), UDim2.fromOffset(700, 22), { TextSize = 15, TextColor3 = CYAN, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Center })
    widgets.stab = label(overlay, "STAB  IDLE  /  WEAPONS SAFE", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(300, 20), { TextSize = 15, TextColor3 = DIM_TEXT, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, -122), TextXAlignment = Enum.TextXAlignment.Center })

    -- Boot / status banner
    widgets.banner = label(overlay, "", UDim2.new(0.5, 0, 0.22, 0), UDim2.fromOffset(900, 44), { Font = FONT_TITLE, TextSize = 26, TextColor3 = CYAN, AnchorPoint = Vector2.new(0.5, 0.5), TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1 })
    widgets.bootLog = label(overlay, "", UDim2.new(0.5, 0, 0.22, 34), UDim2.fromOffset(560, 150), { TextSize = 19, TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })

    -- Evacuation warning
    local alertGui = new("ScreenGui", { Name = "IronframeCockpitAlert", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 110, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, playerGui)
    table.insert(guis, alertGui)
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
    widgets.hint = label(overlay, "V  Garage view     R  Recenter     Mouse / Arrows  Look     LMB Fire  1-6 Hardpoint  T Reload     C  Power profile     X  Test ejection     ALT  Free cursor\nZ  Zoom     Y  Thermal     L  Lock / next target     U  Release     O  Radar scale", UDim2.new(0.5, 0, 1, -58), UDim2.fromOffset(1300, 44), { TextSize = 15, TextColor3 = DIM_TEXT, AnchorPoint = Vector2.new(0.5, 0), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top })

    -- Fade layer (separate gui so it covers everything, including the garage UI)
    local fadeGui = new("ScreenGui", { Name = "IronframeCockpitFade", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100 }, playerGui)
    table.insert(guis, fadeGui)
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

-- paletteName: "INDUSTRIAL" | "RECON" (the compiled cockpit package's palette). The recon fittings add two auxiliary displays.
function Hud.Build(cockpit, playerGui: PlayerGui, paletteName: string?)
    if built then
        return
    end
    built = true
    applyPalette(paletteName or "INDUSTRIAL")
    buildOverlay(playerGui)
    local part = function(key: string): Part
        return cockpit.screens[key].part
    end
    buildStructure(makeDisplay("MFD_L", part("MFD_L"), Vector2.new(640, 490), "STRUCTURE"))
    buildReactor(makeDisplay("MFD_C", part("MFD_C"), Vector2.new(480, 490), "REACTOR"))
    buildArmament(makeDisplay("MFD_R", part("MFD_R"), Vector2.new(640, 490), "ARMAMENT"))
    local recon = cockpit.screens.AuxL ~= nil
    buildTargeting(makeDisplay("ConsoleL", part("ConsoleL"), Vector2.new(460, 482), "TARGETING"), recon)
    buildSensors(makeDisplay("ConsoleR", part("ConsoleR"), Vector2.new(460, 482), "RADAR"))
    buildOverhead(makeDisplay("Overhead", part("Overhead"), Vector2.new(1000, 250), "SYSTEMS"))
    if recon then
        buildAnalysis(makeDisplay("AuxL", part("AuxL"), Vector2.new(600, 424), "TARGET ANALYSIS"))
        buildArray(makeDisplay("AuxR", part("AuxR"), Vector2.new(600, 424), "SENSOR ARRAY"))
    end
    subscription = Telemetry.Subscribe(function()
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
        viewportConn = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
    end
end

-- Tears down every ScreenGui this module made and forgets all display state, so Build can run again with another palette. (The SurfaceGuis die with
-- the old cockpit model, which the caller destroys.)
function Hud.Destroy()
    for _, g in ipairs(guis) do
        g:Destroy()
    end
    table.clear(guis)
    table.clear(displays)
    table.clear(sections)
    table.clear(widgets)
    table.clear(compass.ticks)
    if subscription then
        subscription()
        subscription = nil
    end
    if viewportConn then
        viewportConn:Disconnect()
        viewportConn = nil
    end
    built = false
    dirty = true
    lastHeadingDrawn = 1e9
end

function Hud.Rebuild(cockpit, playerGui: PlayerGui, paletteName: string?)
    local wasVisible = overlay ~= nil and overlay.Parent ~= nil and overlay.Enabled
    Hud.Destroy()
    Hud.Build(cockpit, playerGui, paletteName)
    overlay.Enabled = wasVisible
end

function Hud.Palette(): string
    return paletteId
end

function Hud.Colors(): { primary: Color3, warn: Color3, crit: Color3, text: Color3, dim: Color3 }
    return { primary = CYAN, warn = AMBER, crit = RED, text = WHITE, dim = DIM_TEXT }
end

-- Radar controls / readouts used by the avionics client and the camera mode.
function Hud.SetChassisHeading(value: number)
    chassisHeading = value % 360
end

function Hud.CycleRadarScale(): number
    radarScaleIndex = radarScaleIndex % #RADAR_SCALES + 1
    if widgets.radarDirty ~= nil then
        widgets.radarDirty = true
    end
    dirty = true
    return RADAR_SCALES[radarScaleIndex]
end

function Hud.RadarScale(): number
    return RADAR_SCALES[radarScaleIndex]
end

function Hud.RadarPing()
    widgets.pingAt = os.clock()
end

-- Compact text next to the reticle (zoom) and under it (modes): set only when the string changes.
function Hud.SetReadouts(zoom: string, modes: string, modesColor: Color3?)
    if widgets.zoomText and widgets.zoomText.Text ~= zoom then
        widgets.zoomText.Text = zoom
    end
    if widgets.avLine then
        if widgets.avLine.Text ~= modes then
            widgets.avLine.Text = modes
        end
        widgets.avLine.TextColor3 = modesColor or CYAN
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

-- Per-frame cheap animation: compass tape, radar bearing ring and contact placement (real contacts only).
function Hud.Step(dt: number, t: number)
    animateProfile(os.clock())
    if widgets.stab then
        widgets.stab.Size = UDim2.fromOffset(600,20)
        widgets.stab.Text = string.format("%s | %s | HITS %d | PWR %s",Telemetry.Value("weapons.name","WEAPONS SAFE"),Telemetry.Value("weapons.state","SAFE"),Telemetry.Value("weapons.hits",0),PROFILE_TAG[Telemetry.Value("energy.profile","")] or "--")
        widgets.stab.TextColor3 = if Telemetry.Value("weapons.state","") == "ENERGY LOW" or Telemetry.Value("weapons.state","") == "RESERVED" then AMBER else CYAN
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
        -- Radar: up is the machine's own heading (not the camera). Cardinal letters and every contact rotate against it.
        for _, item in pairs(widgets.bearing) do
            local angle = math.rad(item.angle - chassisHeading)
            item.label.Position = UDim2.fromOffset(
                widgets.radarCenter.X + math.sin(angle) * widgets.radarRadius,
                widgets.radarCenter.Y - math.cos(angle) * widgets.radarRadius
            )
        end
        local view = math.rad(relBearing(heading))
        widgets.view.Position = UDim2.fromOffset(CENTER + math.sin(view) * (CENTER - 3), CENTER - math.cos(view) * (CENTER - 3))
        widgets.view.Rotation = math.deg(view)
        placeBlips()
        local pingAge = os.clock() - (widgets.pingAt or -10)
        if pingAge < 0.7 then
            local p = pingAge / 0.7
            widgets.ping.Size = UDim2.fromScale(p, p)
            widgets.pingStroke.Transparency = 0.35 + 0.65 * p
        elseif widgets.pingStroke.Transparency < 1 then
            widgets.pingStroke.Transparency = 1
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
