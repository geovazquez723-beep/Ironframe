-- Engineering bay (M11A): the garage's customization interface. Right-hand panel, visible while the Bastion is STOWED in the hangar.
--
--   tabs         WEAPONS (four hardpoints) | REACTOR | DRIVE (leg actuators) | ARMOR | COCKPIT (equipment package) | AVIONICS (radar, optics, thermal, targeting)
--   list         the components the registry offers for that place (LoadoutCompiler.Catalog: nothing is hard-coded here)
--   comparison   installed vs candidate, only the numbers that change: arrows and percentages, green = gain, amber = price
--   INSTALL      sends component ids only; the server validates and rebuilds the machine (the model on the pad changes at once)
--   REVERT       swaps back to the configuration before the last install
--   LAST SORTIE  compact engineering feedback from the previous sortie (damage dealt / received, energy, ROOK result, parts lost)
--
-- Presentation only. The client compiles candidates with the same shared LoadoutCompiler to preview legality and deltas; the server never
-- trusts that and compiles again.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Compiler = require(Shared:WaitForChild("LoadoutCompiler"))
local Components = require(Shared:WaitForChild("ComponentRegistry"))
local Avionics = require(Shared:WaitForChild("Avionics"))

local Panel = {}

local AMBER = Color3.fromRGB(255, 178, 66)
local CYAN = Color3.fromRGB(134, 222, 244)
local GREEN = Color3.fromRGB(110, 226, 150)
local RED = Color3.fromRGB(255, 96, 78)
local WHITE = Color3.fromRGB(230, 241, 246)
local DIM = Color3.fromRGB(128, 158, 170)
local BG = Color3.fromRGB(14, 22, 29)
local BTN = Color3.fromRGB(28, 42, 52)
local BTN_ON = Color3.fromRGB(52, 74, 88)

local TABS = { { "WEAPONS", "weapons" }, { "REACTOR", "reactor" }, { "DRIVE", "actuators" }, { "ARMOR", "armor" }, { "COCKPIT", "cockpit" }, { "AVIONICS", "avionics" } }
local AV_SLOTS = { { "radar", "RADAR" }, { "optics", "OPTICS" }, { "thermal", "THERMAL" }, { "targeting", "TRACKER" } }
local FACTORY = "FACTORY"
local SOCKET_LABEL = { left_arm = "L ARM", right_arm = "R ARM", left_shoulder = "L SHLDR", right_shoulder = "R SHLDR" }

-- Comparison rows per category: { label, stat key, format, higherIsBetter }
local ROWS = {
    reactor = {
        { "OUTPUT", "output", "%.0f u/s", true }, { "CAPACITOR", "capacity", "%.0f u", true }, { "HEAT / ENERGY", "thermalPerEnergy", "%.3f", false },
        { "CHARGE RATE", "chargeRate", "%.0f u/s", true }, { "MASS", "mass", "%.1f t", false },
    },
    actuators = {
        { "TOP SPEED", "topSpeed", "%.1f st/s", true }, { "SPRINT", "sprintSpeed", "%.1f st/s", true }, { "ACCEL", "accel", "%.1f", true },
        { "TURN RATE", "turnRate", "%.0f deg/s", true }, { "MOVE ENERGY", "moveEnergy", "x%.2f", false }, { "LEG STRUCT", "legStructure", "%.0f", true }, { "MASS", "mass", "%.1f t", false },
    },
    armor = {
        { "CORE STRUCT", "coreStructure", "%.0f", true }, { "LEG STRUCT", "legStructure", "%.0f", true }, { "ARM STRUCT", "armStructure", "%.0f", true },
        { "REACTOR STRUCT", "reactorStructure", "%.0f", true }, { "TOP SPEED", "topSpeed", "%.1f st/s", true }, { "ACCEL", "accel", "%.1f", true },
        { "MOVE ENERGY", "moveEnergy", "x%.2f", false }, { "MASS", "mass", "%.1f t", false },
    },
}
-- Cockpit / avionics comparison (the compiled sensor numbers; a row only shows when the candidate changes it)
local SENSOR_ROWS = {
    { "RADAR RANGE", "radarRange", "%.0f st", true }, { "SCAN RATE", "radarRate", "%.1f /s", true }, { "IDENT RANGE", "identRange", "%.0f st", true },
    { "MAX ZOOM", "zoomMax", "x%.0f", true }, { "THERMAL RNG", "thermalRange", "%.0f st", true }, { "TRACK RANGE", "trackRange", "%.0f st", true },
    { "TRACK DETAIL", "trackDetail", "%d", true }, { "AVIONICS MASS", "avionicsMass", "%.1f t", false }, { "RATED POWER", "avionicsPower", "%.1f u/s", false },
    { "BAYS USED", "baysUsed", "%d", false },
}
local WEAPON_ROWS = {
    { "DAMAGE", "damage", "%.0f", true }, { "FIRE RATE", "rate", "%.1f /s", true }, { "DPS", "dps", "%.0f", true },
    { "MAGAZINE", "magazine", "%s", true }, { "RELOAD", "reload", "%.1f s", false }, { "ENERGY", "energyRate", "%.1f u/s", false }, { "MASS", "mass", "%.1f t", false },
}

local function compareLines(rows, a: { [string]: any }, b: { [string]: any }): ({ { text: string, color: Color3 } }, boolean)
    local lines, any = {}, false
    for _, row in ipairs(rows) do
        local x, y = a[row[2]], b[row[2]]
        if x ~= nil and y ~= nil and (x ~= y) and not (type(x) == "number" and math.abs(x - y) < 1e-6) then
            any = true
            local text
            if type(x) == "number" and type(y) == "number" then
                if math.abs(x) > 1e-9 then
                    text = string.format("%-13s " .. row[3] .. " > " .. row[3] .. "  (%+.0f%%)", row[1], x, y, (y - x) / math.abs(x) * 100)
                else
                    text = string.format("%-13s " .. row[3] .. " > " .. row[3] .. "  (new)", row[1], x, y)
                end
            else
                text = string.format("%-13s %s > %s", row[1], tostring(x), tostring(y))
            end
            local better = (type(x) == "number" and type(y) == "number") and ((y > x) == row[4]) or false
            table.insert(lines, { text = text, color = if better then GREEN else AMBER })
        end
    end
    return lines, any
end

local function weaponStats(w): { [string]: any }?
    if not w then
        return nil
    end
    return { damage = w.damage, rate = 1 / w.interval, dps = w.dps, magazine = if w.magazine == 0 then "CAP" else tostring(w.magazine), reload = w.reload, energyRate = w.energyRate, mass = w.mass }
end

function Panel.Start(remotes, cameraMode)
    local player = Players.LocalPlayer
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "IronframeEngineeringUI", false, 21, true
    gui.Parent = player:WaitForChild("PlayerGui")
    local scale = Instance.new("UIScale")
    scale.Parent = gui

    local frame = Instance.new("Frame")
    frame.Name, frame.AnchorPoint, frame.Position, frame.Size = "Panel", Vector2.new(1, 0.5), UDim2.new(1, -22, 0.5, 52), UDim2.fromOffset(396, 704)
    frame.BackgroundColor3, frame.BackgroundTransparency, frame.BorderSizePixel, frame.Visible = BG, 0.08, 0, false
    frame.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local function label(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, color: Color3, textSize: number, font: Enum.Font?): TextLabel
        local l = Instance.new("TextLabel")
        l.Name, l.Text, l.Position, l.Size = name, text, pos, size
        l.BackgroundTransparency, l.TextColor3, l.TextSize, l.Font = 1, color, textSize, font or Enum.Font.Code
        l.TextXAlignment, l.TextYAlignment, l.TextWrapped = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top, true
        l.Parent = parent
        return l
    end
    local function button(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, textSize: number?): TextButton
        local b = Instance.new("TextButton")
        b.Name, b.Text, b.Position, b.Size = name, text, pos, size
        b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = BTN, WHITE, Enum.Font.GothamBold, textSize or 13
        b.AutoButtonColor = true
        b.Parent = parent
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = b
        return b
    end

    label(frame, "Brand", "ENGINEERING BAY  /  IF-42 CONFIGURATION", UDim2.fromOffset(16, 12), UDim2.fromOffset(364, 20), AMBER, 15, Enum.Font.GothamBold)
    local buildLabel = label(frame, "BuildLabel", "", UDim2.fromOffset(16, 36), UDim2.fromOffset(364, 34), CYAN, 13)
    local massLabel = label(frame, "Mass", "", UDim2.fromOffset(16, 72), UDim2.fromOffset(364, 18), WHITE, 13)

    -- Tabs
    local tabButtons: { [string]: TextButton } = {}
    for i, tab in ipairs(TABS) do
        local b = button(frame, "Tab_" .. tab[2], tab[1], UDim2.fromOffset(16 + (i - 1) * 61, 96), UDim2.fromOffset(58, 30), 9)
        b.TextScaled = true
        local limit = Instance.new("UITextSizeConstraint")
        limit.MaxTextSize = 11
        limit.Parent = b
        tabButtons[tab[2]] = b
    end

    -- Weapon slot selector (only on the WEAPONS tab)
    local slotButtons: { [string]: TextButton } = {}
    for i, socket in ipairs(Compiler.ConfigurableSockets) do
        local b = button(frame, "Slot_" .. socket, SOCKET_LABEL[socket], UDim2.fromOffset(16 + (i - 1) * 91, 134), UDim2.fromOffset(86, 40), 11)
        b.TextWrapped = true
        slotButtons[socket] = b
    end

    -- Avionics slot selector (only on the AVIONICS tab)
    local avButtons: { [string]: TextButton } = {}
    for i, spec in ipairs(AV_SLOTS) do
        local b = button(frame, "AvSlot_" .. spec[1], spec[2], UDim2.fromOffset(16 + (i - 1) * 91, 134), UDim2.fromOffset(86, 40), 11)
        b.TextWrapped = true
        avButtons[spec[1]] = b
    end

    -- Option rows
    local MAX_ROWS = 5
    local rows: { { button: TextButton, name: TextLabel, sub: TextLabel } } = {}
    for i = 1, MAX_ROWS do
        local b = button(frame, "Option" .. i, "", UDim2.fromOffset(16, 182 + (i - 1) * 54), UDim2.fromOffset(364, 50), 12)
        b.Text = ""
        local name = label(b, "Name", "", UDim2.fromOffset(10, 4), UDim2.fromOffset(344, 18), WHITE, 14, Enum.Font.GothamBold)
        local sub = label(b, "Sub", "", UDim2.fromOffset(10, 24), UDim2.fromOffset(344, 24), DIM, 11)
        rows[i] = { button = b, name = name, sub = sub }
    end
    local compareTitle = label(frame, "CompareTitle", "", UDim2.fromOffset(16, 456), UDim2.fromOffset(364, 16), AMBER, 12, Enum.Font.GothamBold)
    local compare = label(frame, "Compare", "", UDim2.fromOffset(16, 474), UDim2.fromOffset(364, 112), WHITE, 13)
    local message = label(frame, "Message", "", UDim2.fromOffset(16, 588), UDim2.fromOffset(364, 18), RED, 12)
    local install = button(frame, "Install", "INSTALL", UDim2.fromOffset(16, 610), UDim2.fromOffset(250, 32), 14)
    local revert = button(frame, "Revert", "REVERT", UDim2.fromOffset(274, 610), UDim2.fromOffset(106, 32), 13)
    local sortie = label(frame, "Sortie", "", UDim2.fromOffset(16, 648), UDim2.fromOffset(364, 52), DIM, 11)

    -- State
    local state: { loadout: any?, canRevert: boolean, lastSortie: any?, deployment: string } = { loadout = nil, canRevert = false, lastSortie = nil, deployment = "STOWED" }
    local tab, slot, selected = "weapons", "left_arm", nil :: string?
    local avSlot = "radar"
    local options: { { id: string?, name: string } } = {}
    local candidate: any = nil
    local pendingMessage, pendingAt = "", -10

    local function request(): any?
        if not selected and tab ~= "weapons" then
            return nil
        end
        if tab == "weapons" then
            if selected == nil then
                return nil
            end
            return { mounts = { [slot] = if selected == "EMPTY" then false else selected } }
        end
        if tab == "cockpit" then
            if selected == FACTORY then
                return { cockpit = "CKP_STANDARD", avionics = { radar = "AV_RADAR_BASIC", optics = false, thermal = false, targeting = false } }
            end
            return { cockpit = selected }
        elseif tab == "avionics" then
            return { avionics = { [avSlot] = if selected == "EMPTY" then false else selected } }
        end
        return { systems = { [tab] = selected } }
    end

    local function installedId(): string?
        local l = state.loadout
        if not l then
            return nil
        end
        if tab == "weapons" then
            return l.mounts[slot] or "EMPTY"
        elseif tab == "cockpit" then
            return (Compiler.CockpitOf(l))
        elseif tab == "avionics" then
            local _, installed = Compiler.CockpitOf(l)
            return (installed and installed[avSlot]) or "EMPTY"
        end
        return l.systems[tab] or (if tab == "actuators" then "ACT_STANDARD" else nil)
    end

    local function refresh()
        local l = state.loadout
        if not l then
            frame.Visible = false
            return
        end
        local current = Compiler.Compile(l)
        buildLabel.Text = string.format("%s\n%s", Compiler.Label(l), if current.valid then "BUILD VALID" else "BUILD INVALID: " .. tostring(current.issues[1]))
        local m = current.metrics
        massLabel.Text = string.format("MASS %.1f / %.1f t   |   POWER DRAW %.0f / %.0f   |   STRUCT %.0f", m.mass, m.massLimit, m.powerDraw, m.powerOutput, m.integrity)
        massLabel.TextColor3 = if m.remainingMass < 1 then AMBER else WHITE
        for id, b in pairs(tabButtons) do
            b.BackgroundColor3 = if id == tab then BTN_ON else BTN
        end
        for socket, b in pairs(slotButtons) do
            b.Visible = tab == "weapons"
            local w = l.mounts[socket]
            b.Text = SOCKET_LABEL[socket] .. "\n" .. (if w then string.match(Components[w].name, "^(%S+)") or w else "EMPTY")
            b.BackgroundColor3 = if socket == slot then BTN_ON else BTN
        end
        local _, installedAv = Compiler.CockpitOf(l)
        for key, b in pairs(avButtons) do
            b.Visible = tab == "avionics"
            local id = installedAv and installedAv[key]
            b.Text = string.upper(key == "targeting" and "TRACKER" or key) .. "\n" .. (if id then Avionics.Short[id] or id else "EMPTY")
            b.BackgroundColor3 = if key == avSlot then BTN_ON else BTN
        end
        -- option list for the current place
        options = {}
        if tab == "weapons" then
            for _, id in ipairs(Compiler.WeaponOptions(l.chassisId, slot)) do
                table.insert(options, { id = id, name = Components[id].name })
            end
            table.insert(options, { id = "EMPTY", name = "EMPTY HARDPOINT" })
        elseif tab == "cockpit" then
            for _, id in ipairs(Compiler.CockpitOptions(l.chassisId)) do
                table.insert(options, { id = id, name = Components[id].name })
            end
            table.insert(options, { id = FACTORY, name = "FACTORY EQUIPMENT" })
        elseif tab == "avionics" then
            for _, id in ipairs(Compiler.AvionicsOptions(l.chassisId, avSlot)) do
                table.insert(options, { id = id, name = Components[id].name })
            end
            table.insert(options, { id = "EMPTY", name = "EMPTY BAY" })
        else
            for _, id in ipairs(Compiler.SystemOptions(tab)) do
                table.insert(options, { id = id, name = Components[id].name })
            end
        end
        local installed = installedId()
        for i, row in ipairs(rows) do
            local o = options[i]
            row.button.Visible = o ~= nil
            if o then
                local c = Components[o.id :: string]
                row.name.Text = (if o.id == installed then "[INSTALLED]  " else "") .. o.name
                row.name.TextColor3 = if o.id == installed then CYAN else WHITE
                if o.id == FACTORY then
                    row.sub.Text = "Industrial cockpit, RS-4 radar only. Clears every avionics module."
                elseif o.id == "EMPTY" and tab == "avionics" then
                    row.sub.Text = "Nothing in this bay. Frees mass, power and a bay."
                elseif tab == "cockpit" and c then
                    row.sub.Text = string.format("%s  %.1f t  %.1f u/s  %d bays", c.summary or "", c.mass, c.powerDraw, c.bays)
                elseif tab == "avionics" and c then
                    row.sub.Text = string.format("%s  %.1f t  %.1f u/s", c.summary or "", c.mass, c.powerDraw)
                elseif o.id == "EMPTY" then
                    row.sub.Text = "No weapon. Saves mass and power draw."
                elseif tab == "weapons" and c and c.combat then
                    local cb = c.combat
                    row.sub.Text = string.format("%s  DMG %d  %.1f/s  MAG %s  %.1f u/s  %.1f t", string.upper(c.family), cb.damage, 1 / cb.interval, if cb.magazine == 0 then "CAP" else tostring(cb.magazine), cb.energy / cb.interval, c.mass)
                else
                    row.sub.Text = (c and c.summary) or ""
                end
                row.button.BackgroundColor3 = if o.id == selected then BTN_ON elseif o.id == installed then Color3.fromRGB(20, 52, 64) else BTN
            end
        end
        -- comparison / legality of the candidate
        candidate = nil
        local req = request()
        local lines, ok = {}, false
        local why = ""
        if req and selected and selected ~= installed then
            local out, reason = Compiler.ApplyRequest(l, req)
            if out then
                candidate = out
                local cc = Compiler.Compile(out)
                if tab == "weapons" then
                    lines = compareLines(WEAPON_ROWS, weaponStats(current.weapons[slot]) or { mass = 0 }, weaponStats(cc.weapons[slot]) or { mass = 0 })
                    local dm = cc.metrics.mass - current.metrics.mass
                    if #lines == 0 then
                        table.insert(lines, { text = "NO CHANGE", color = DIM })
                    end
                    table.insert(lines, { text = string.format("BUILD MASS    %.1f > %.1f t", current.metrics.mass, cc.metrics.mass), color = if dm > 0 then AMBER else GREEN })
                elseif tab == "cockpit" or tab == "avionics" then
                    lines = compareLines(SENSOR_ROWS, current.stats, cc.stats)
                    local dm = cc.metrics.mass - current.metrics.mass
                    table.insert(lines, { text = string.format("BUILD MASS    %.1f > %.1f t", current.metrics.mass, cc.metrics.mass), color = if dm > 0 then AMBER else GREEN })
                    if #lines == 1 then
                        table.insert(lines, 1, { text = "NO SENSOR CHANGE", color = DIM })
                    end
                else
                    lines = compareLines(ROWS[tab], current.stats, cc.stats)
                end
                ok = true
            else
                why = reason or "NOT AVAILABLE"
                -- Show what the part would do anyway, with the reason it cannot go in.
                local forced = Compiler.Normalize(l)
                if tab == "weapons" then
                    forced.mounts[slot] = if selected == "EMPTY" then nil else selected
                elseif tab == "cockpit" then
                    forced.cockpit = if selected == FACTORY then "CKP_STANDARD" else selected
                elseif tab == "avionics" then
                    forced.avionics[avSlot] = if selected == "EMPTY" then nil else selected
                else
                    forced.systems[tab] = selected
                end
                local fc = Compiler.Compile(forced)
                if fc.stats and (tab == "cockpit" or tab == "avionics") then
                    lines = compareLines(SENSOR_ROWS, current.stats, fc.stats)
                elseif fc.stats and tab ~= "weapons" then
                    lines = compareLines(ROWS[tab], current.stats, fc.stats)
                elseif fc.weapons and tab == "weapons" then
                    lines = compareLines(WEAPON_ROWS, weaponStats(current.weapons[slot]) or { mass = 0 }, weaponStats(fc.weapons[slot]) or { mass = 0 })
                end
                if fc.metrics then
                    table.insert(lines, { text = string.format("BUILD MASS    %.1f > %.1f t  (limit %.1f)", current.metrics.mass, fc.metrics.mass, fc.metrics.massLimit), color = RED })
                end
            end
            compareTitle.Text = "INSTALLED  >  " .. string.upper(if selected == FACTORY then "FACTORY EQUIPMENT" else (Components[selected] and Components[selected].name or "EMPTY"))
        else
            compareTitle.Text = if selected == installed and selected then "INSTALLED" else "SELECT A COMPONENT TO COMPARE"
        end
        local text = {}
        for _, line in ipairs(lines) do
            table.insert(text, string.format('<font color="#%s">%s</font>', line.color:ToHex(), line.text))
        end
        compare.RichText = true
        compare.Text = table.concat(text, "\n")
        compare.TextColor3 = WHITE
        message.Text = if why ~= "" then why elseif os.clock() - pendingAt < 6 then pendingMessage else ""
        message.TextColor3 = if why ~= "" then RED else AMBER
        install.Active = ok
        install.AutoButtonColor = ok
        install.BackgroundColor3 = if ok then Color3.fromRGB(70, 110, 60) else BTN
        install.TextTransparency = if ok then 0 else 0.55
        install.Text = if ok then "INSTALL" else "INSTALL"
        revert.Active, revert.AutoButtonColor = state.canRevert, state.canRevert
        revert.TextTransparency = if state.canRevert then 0 else 0.55
        local s = state.lastSortie
        if s then
            sortie.Text = string.format("LAST SORTIE  %s\n%s  %ds | DEALT %d  TAKEN %d  ENERGY %d  PEAK HEAT %d%%\nROOK: %s%s", s.config, s.outcome, s.seconds, s.dealt, s.received, s.spent, s.peakThermal, s.rook,
                if #s.disabled > 0 then "  LOST: " .. table.concat(s.disabled, ", ") else "")
        else
            sortie.Text = "LAST SORTIE  none yet. Deploy, fight, return."
        end
    end

    for id, b in pairs(tabButtons) do
        b.MouseButton1Click:Connect(function()
            tab, selected = id, nil
            refresh()
        end)
    end
    for socket, b in pairs(slotButtons) do
        b.MouseButton1Click:Connect(function()
            slot, selected = socket, nil
            refresh()
        end)
    end
    for key, b in pairs(avButtons) do
        b.MouseButton1Click:Connect(function()
            avSlot, selected = key, nil
            refresh()
        end)
    end
    for i, row in ipairs(rows) do
        row.button.MouseButton1Click:Connect(function()
            local o = options[i]
            if o then
                selected = o.id
                refresh()
            end
        end)
    end
    local function performInstall()
        local req = request()
        if candidate and req then
            remotes.RequestLoadout:FireServer(req)
            selected = nil
            pendingMessage, pendingAt = "INSTALLING...", os.clock()
        end
    end
    install.MouseButton1Click:Connect(performInstall)
    revert.MouseButton1Click:Connect(function()
        if state.canRevert then
            remotes.RequestLoadoutRevert:FireServer()
            selected = nil
        end
    end)

    local function onState(data)
        if not data or not data.ready then
            return
        end
        state.loadout, state.canRevert, state.lastSortie, state.deployment = data.loadout, data.canRevert == true, data.lastSortie, data.deployment or "STOWED"
        if type(data.message) == "string" and string.find(data.message, "REJECTED", 1, true) then
            pendingMessage, pendingAt = data.message, os.clock()
        elseif pendingMessage == "INSTALLING..." then
            pendingMessage = ""
        end
        refresh()
    end
    remotes.StateChanged.OnClientEvent:Connect(onState)
    task.spawn(function()
        local ok, result = pcall(function() return remotes.GetGarageState:InvokeServer() end)
        if ok then
            onState(result)
        end
    end)

    RunService.Heartbeat:Connect(function()
        local camera = workspace.CurrentCamera
        if camera then
            local size = camera.ViewportSize
            scale.Scale = math.clamp(math.min(size.Y / 1080, size.X / 1920), 0.6, 1.3)
        end
        local folder = workspace:FindFirstChild("IronframeMechs")
        local mech = folder and folder:FindFirstChild(tostring(player.UserId))
        local stowed = mech ~= nil and mech:GetAttribute("Deployment") == "STOWED"
        frame.Visible = stowed and state.loadout ~= nil and cameraMode.Current() ~= "COCKPIT"
    end)

    -- Client-only test interface (no authority): scripted playtests read and drive the panel the way a mouse would.
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeEngineeringControl"
    control.OnInvoke = function(command, a, b)
        if command == "state" then
            return { visible = frame.Visible, tab = tab, slot = slot, selected = selected, build = buildLabel.Text, mass = massLabel.Text, compare = compare.Text, message = message.Text,
                installEnabled = install.Active, canRevert = state.canRevert, sortie = sortie.Text, options = #options }
        elseif command == "tab" then
            tab, selected = a, nil
            refresh()
        elseif command == "slot" then
            slot, selected = a, nil
            refresh()
        elseif command == "avslot" then
            avSlot, selected = a, nil
            refresh()
        elseif command == "install" then
            performInstall()
        elseif command == "select" then
            selected = a
            refresh()
        end
        return nil
    end
    control.Parent = player:WaitForChild("PlayerScripts")
    return Panel
end

return Panel
