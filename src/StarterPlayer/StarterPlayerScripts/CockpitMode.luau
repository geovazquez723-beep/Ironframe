-- The single coordinated camera-mode system (M06A).
--
-- Two viewing modes share one camera, one input model and one transition path:
--   GARAGE   existing exterior orbit camera (GarageCamera owns CurrentCamera while it is `active`)
--   COCKPIT  first-person pilot view, locked to the animated Torso joint with limited head-look
-- GarageCamera stays the only exterior controller and CockpitMode the only cockpit controller; CockpitMode flips
-- GarageCamera.SetActive() so exactly one of them writes the camera at any time. During a transition CockpitMode writes
-- the camera itself, blending between the two poses under a dip-to-black so the lens never visibly crosses the hull.
--
-- M11C: this is also the ONE camera controller for optical zoom. The AvionicsClient owns the zoom state (ZoomControl) and answers `Camera(baseFov)`;
-- no second controller touches the camera. Every path that ends the cockpit view calls `avionics.Reset`, so no zoom or thermal state survives it.
--
-- Safe ejection is NOT reimplemented: the server's Ejection state machine runs unchanged and publishes the mech's
-- `State` attribute. This module only reacts: warning, camera out of the mech, "PILOT EVACUATED", then restore.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Config = require(Shared:WaitForChild("CockpitConfig"))
local Telemetry = require(Shared:WaitForChild("Telemetry"))
local Builder = require(script.Parent:WaitForChild("CockpitBuilder"))
local Hud = require(script.Parent:WaitForChild("CockpitHud"))
local Audio = require(script.Parent:WaitForChild("CockpitAudio"))
local Warnings = require(Shared:WaitForChild("CockpitWarnings"))
local Avionics = require(Shared:WaitForChild("Avionics"))

local player = Players.LocalPlayer
local COLORS = Config.COLORS

local Mode = {}
Mode.GARAGE, Mode.COCKPIT = "GARAGE", "COCKPIT"

-- ----------------------------------------------------------------------------------------------------------------
-- State
-- ----------------------------------------------------------------------------------------------------------------
local deps: { garage: any, animator: any, remotes: Folder }
local mode = Mode.GARAGE
local transition: { t0: number, duration: number, to: string, fromCF: CFrame, fromFov: number, swapped: boolean, evac: boolean? }? = nil
local cockpit: Builder.Cockpit? = nil
local interiorActive = false
local lastTorsoCF: CFrame? = nil
local look = { yaw = 0, pitch = 0, targetYaw = 0, targetPitch = 0 }
local hidden: { BasePart } = {}
local hiddenFor: Model? = nil
local hiddenAt = 0
local bootDone = false
local boot: { t0: number, skipped: boolean, lines: number, bannerShown: boolean, displaysOn: { [string]: boolean } }? = nil
local evacuation: { t0: number, restoreCockpit: boolean, phase: string, exiting: boolean, exitAt: number }? = nil
local watched: Model? = nil
local watchConn: RBXScriptConnection? = nil
local lastTelemetry = 0
local lastBlip = 0
local hintToken = 0
local perf = { stepMs = 0, samples = 0 }
local modeButton: TextButton, ejectButton: TextButton, controlsGui: ScreenGui
local cursorFree = false
local avionics: any = nil -- AvionicsClient (set by IronframeClient): zoom state, thermal view, tracking
local packageInfo: { id: string, palette: string, equipment: { string } } = { id = "CKP_STANDARD", palette = "INDUSTRIAL", equipment = {} }
local pendingPackage: any = nil
local lastWarnAt = 0

local function now(): number
    return os.clock()
end

local function smooth(p: number): number
    p = math.clamp(p, 0, 1)
    return p * p * (3 - 2 * p)
end

local function getModel(): Model?
    local folder = workspace:FindFirstChild("IronframeMechs")
    local model = folder and folder:FindFirstChild(tostring(player.UserId))
    return if model and model:IsA("Model") then model else nil
end

local function comfort(): number
    local value = player:GetAttribute(Config.COMFORT_SCALE_ATTRIBUTE)
    return if type(value) == "number" then math.clamp(value, 0, 1) else 1
end

-- ----------------------------------------------------------------------------------------------------------------
-- Cursor and input state
-- ----------------------------------------------------------------------------------------------------------------
local function applyCursor()
    if mode == Mode.COCKPIT and not transition and not cursorFree and not evacuation then
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
        UserInputService.MouseIconEnabled = false
    else
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end
end

local function resetLook()
    look.yaw, look.pitch, look.targetYaw, look.targetPitch = 0, 0, 0, 0
end

-- ----------------------------------------------------------------------------------------------------------------
-- Exterior parts hidden locally while the pilot is inside
-- ----------------------------------------------------------------------------------------------------------------
local function restoreExterior()
    for _, part in ipairs(hidden) do
        if part.Parent then
            part.LocalTransparencyModifier = 0
        end
    end
    table.clear(hidden)
    hiddenFor = nil
end

-- Hides the mech's own chest/head hull around the pilot (centre inside the hide box, weapons and mounts kept).
-- Purely LocalTransparencyModifier: no server state, no other player sees any change.
local function hideExterior(model: Model, torsoCF: CFrame)
    restoreExterior()
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant:GetAttribute("Joint") and not descendant:GetAttribute("LinkId") then
            local name = descendant.Name
            if string.sub(name, 1, 7) ~= "Weapon_" and string.sub(name, 1, 6) ~= "Mount_" then
                local p = torsoCF:PointToObjectSpace(descendant.Position)
                local lo, hi = Config.HIDE_MIN, Config.HIDE_MAX
                if p.X > lo.X and p.X < hi.X and p.Y > lo.Y and p.Y < hi.Y and p.Z > lo.Z and p.Z < hi.Z then
                    descendant.LocalTransparencyModifier = 1
                    table.insert(hidden, descendant)
                end
            end
        end
    end
    hiddenFor = model
    hiddenAt = now()
end

-- ----------------------------------------------------------------------------------------------------------------
-- Local lighting adaptation. The hangar floodlights do not cast shadows and the mech's rear reactor lamp sits right
-- behind the pilot, so without help the interior is lit as if it had no roof. While inside, the lights near the mech get
-- shadows enabled and the mech's own reactor lamp is switched off. Client-only; every change is restored on exit.
-- ----------------------------------------------------------------------------------------------------------------
local savedLights: { [Light]: { enabled: boolean, shadows: boolean } } = {}

local function restoreLighting()
    for light, saved in pairs(savedLights) do
        if light.Parent then
            light.Enabled = saved.enabled
            light.Shadows = saved.shadows
        end
    end
    table.clear(savedLights)
end

local function adaptLighting()
    restoreLighting()
    local origin = (lastTorsoCF :: CFrame).Position
    local mechs = workspace:FindFirstChild("IronframeMechs")
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Light") and descendant.Parent and descendant.Parent:IsA("BasePart") and not descendant:IsDescendantOf(cockpit.model) then
            local holder = descendant.Parent :: BasePart
            if (holder.Position - origin).Magnitude < 70 then
                savedLights[descendant] = { enabled = descendant.Enabled, shadows = descendant.Shadows }
                if mechs and holder:IsDescendantOf(mechs) then
                    if holder.Name == "ReactorCore" then
                        descendant.Enabled = false
                    end
                elseif descendant:IsA("SpotLight") then
                    descendant.Shadows = true
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------------------------------------------
-- Interior lifecycle
-- ----------------------------------------------------------------------------------------------------------------
local function ensureBuilt()
    if cockpit then
        return
    end
    -- AI decoration is replicated by the server a moment after join; give it a short window so it is not skipped.
    ReplicatedStorage:WaitForChild("IronframeCockpitAssets", 5)
    cockpit = Builder.Build(packageInfo)
    Hud.Build(cockpit, player:WaitForChild("PlayerGui"), packageInfo.palette)
    Audio.Start()
    Audio.SetPackage(packageInfo.palette)
end

-- Equipment package (M11C): a different package is a different interior, so the model and the displays are rebuilt. This only happens in the
-- garage view (a package can only be installed while stowed); inside the cockpit the change waits until the pilot leaves.
local function rebuildPackage(info)
    local old = cockpit
    packageInfo = info
    cockpit = Builder.Build(info)
    Hud.Rebuild(cockpit, player:WaitForChild("PlayerGui"), info.palette)
    Audio.SetPackage(info.palette)
    if old then
        old.model:Destroy()
    end
    bootDone = false
    hiddenFor = nil
end

function Mode.ApplyPackage(info: any)
    if type(info) ~= "table" or type(info.id) ~= "string" or info.id == packageInfo.id then
        return
    end
    local clean = { id = info.id, palette = info.palette or "INDUSTRIAL", equipment = info.equipment or {} }
    if not cockpit then
        packageInfo = clean
    elseif interiorActive then
        pendingPackage = clean
    else
        rebuildPackage(clean)
    end
end

function Mode.PackageId(): string
    return packageInfo.id
end

local function setInterior(active: boolean)
    ensureBuilt()
    local c = cockpit :: Builder.Cockpit
    interiorActive = active
    c.model.Parent = if active then workspace:FindFirstChild("IronframeCockpitClient") or workspace else nil
    local garageGui = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("IronframeGarageUI")
    if garageGui then
        garageGui.Enabled = not active
    end
    Hud.SetOverlayVisible(active)
    controlsGui.Enabled = true
    ejectButton.Visible = active
    modeButton.Text = if active then "V   EXIT TO GARAGE" else "V   ENTER COCKPIT"
    Audio.SetCockpit(if active then 1 else 0)
    if active then
        adaptLighting()
    else
        restoreExterior()
        restoreLighting()
        if avionics then
            avionics.Reset("interior off", true)
        end
        if pendingPackage then
            local info = pendingPackage
            pendingPackage = nil
            rebuildPackage(info)
        end
    end
end

local function setLevelAll(value: number)
    local c = cockpit :: Builder.Cockpit
    Builder.SetLevel(c, value)
end

local function setAllIndicators(on: number)
    local c = cockpit :: Builder.Cockpit
    for _, entry in ipairs(c.indicators) do
        Builder.SetIndicator(entry, on)
    end
end

local function setAllDisplays(state: string)
    for _, key in ipairs(Hud.DisplayKeys()) do
        Hud.SetDisplayState(key, state)
    end
end

-- ----------------------------------------------------------------------------------------------------------------
-- Startup sequence
-- ----------------------------------------------------------------------------------------------------------------
-- Startup log (M11C): the line set follows the installed equipment; a sensor line appears only for a module that is really fitted.
local function bootLines(): { { number | string } }
    local spec = Telemetry.Value("avionics.spec", nil)
    local installed = spec and spec.installed or {}
    local function short(slot: string): string
        return Avionics.Short[installed[slot] or ""] or "---"
    end
    if packageInfo.palette == "RECON" then
        local lines = {
            { 0.5, "REACTOR CORE ........... STARTUP" },
            { 1.0, "COOLANT LOOPS .......... PRESSURIZED" },
            { 1.5, "SENSOR MAST ............ DEPLOYED" },
            { 2.0, string.format("RADAR %s ........... ALIGNED", short("radar")) },
        }
        local t = 2.5
        if installed.thermal then
            table.insert(lines, { t, string.format("THERMAL %s ........ FPA COOLDOWN", short("thermal")) })
            t += 0.5
        end
        if installed.optics then
            table.insert(lines, { t, string.format("OPTICS %s ........... CALIBRATED", short("optics")) })
            t += 0.5
        end
        table.insert(lines, { t, "RECON MFD LINK ........ SYNCHRONIZED" })
        t += 0.6
        table.insert(lines, { t, if installed.targeting then string.format("TRACKER %s .......... CALIBRATED", short("targeting")) else "FIRE CONTROL ........... STANDBY" })
        table.insert(lines, { 4.5, "PILOT RESTRAINTS ....... LOCKED" })
        table.insert(lines, { 5.1, "EJECTION SYSTEM ........ ARMED / PILOT SAFE" })
        return lines
    end
    local lines = {
        { 0.5, "REACTOR CORE ........... STARTUP" },
        { 1.2, "COOLANT LOOPS .......... PRESSURIZED" },
        { 1.9, "HYDRAULICS ............. NOMINAL" },
        { 2.6, if installed.radar then string.format("RADAR %s ........... ALIGNED", short("radar")) else "SENSOR ARRAY ........... NOT FITTED" },
        { 3.3, "FIRE CONTROL ........... STANDBY" },
        { 4.0, "LIFE SUPPORT ........... NOMINAL" },
        { 4.6, "PILOT RESTRAINTS ....... LOCKED" },
        { 5.1, "EJECTION SYSTEM ........ ARMED / PILOT SAFE" },
    }
    return lines
end
local DISPLAY_SCHEDULE = { Overhead = 2.2, MFD_L = 2.6, MFD_C = 2.9, MFD_R = 3.2, ConsoleL = 3.5, ConsoleR = 3.8, AuxL = 4.0, AuxR = 4.3 }
local function onlineText(): string
    return if packageInfo.palette == "RECON" then "IF-42 BASTION RC-7 \u{2014} SENSOR NET ONLINE" else "IF-42 BASTION \u{2014} SYSTEMS ONLINE"
end

local function finishBoot()
    boot = nil
    bootDone = true
    setLevelAll(1)
    setAllIndicators(1)
    Audio.SetSpool(1)
    setAllDisplays("ON")
    Hud.SetDisplayBrightness(1)
    Hud.SetBootLog({})
    Hud.SetStatusLine("SYSTEMS ONLINE")
end

local function startBoot(full: boolean)
    ensureBuilt()
    Hud.SetBootLog({})
    Hud.SetBanner("", Hud.Colors().primary, 1)
    if full then
        bootDone = false
        boot = { t0 = now(), skipped = false, lines = 0, bannerShown = false, displaysOn = {} }
        setLevelAll(0.08)
        setAllIndicators(0)
        setAllDisplays("OFF")
        Hud.SetStatusLine("REACTOR STARTUP")
        Audio.SetSpool(0)
    else
        -- Subsequent entries: a quick relink instead of the full sequence.
        boot = nil
        setAllDisplays("OFF")
        setLevelAll(0.2)
        setAllIndicators(0.2)
        Hud.SetStatusLine("RELINK")
        Audio.SetSpool(1)
        task.delay(0.35, function()
            if interiorActive and (mode == Mode.COCKPIT or transition) then
                finishBoot()
                Hud.SetBanner(onlineText(), Hud.Colors().primary, 0)
                task.delay(1.4, function()
                    Hud.FadeBanner(1.0)
                end)
            end
        end)
    end
end

local function stepBoot()
    if not boot then
        return
    end
    local b = boot
    local t = now() - b.t0
    if b.skipped or t >= Config.BOOT_DURATION + 3 then
        finishBoot()
        Hud.SetBanner(onlineText(), Hud.Colors().primary, 0)
        task.delay(1.4, function()
            Hud.FadeBanner(1.0)
        end)
        return
    end
    -- Reactor spool and interior illumination (with a little instability early on)
    Audio.SetSpool(smooth((t - 0.3) / 3.0))
    local base = 0.08 + 0.92 * smooth((t - 1.0) / 3.2)
    local flicker = if t < 4 then (math.noise(t * 11, 3.7) * 0.18) * (1 - t / 4) else 0
    setLevelAll(math.clamp(base + flicker, 0.04, 1))
    Hud.SetDisplayBrightness(math.clamp(0.7 + 0.3 * smooth((t - 2.5) / 2) + (if t < 5 then math.noise(t * 7, 9.1) * 0.12 else 0), 0.3, 1))

    -- Indicator lights come up progressively in rank order
    local c = cockpit :: Builder.Cockpit
    local maxOrder = 1
    for _, entry in ipairs(c.indicators) do
        maxOrder = math.max(maxOrder, entry.order)
    end
    for _, entry in ipairs(c.indicators) do
        local onAt = 1.4 + (entry.order / maxOrder) * 2.8
        local amount = smooth((t - onAt) / 0.35)
        if amount > 0 and amount < 1 and now() - lastBlip > 0.22 then
            lastBlip = now()
            Audio.Blip(1.6 + (entry.order / maxOrder) * 1.2)
        end
        Builder.SetIndicator(entry, amount * (0.8 + 0.2 * math.noise(t * 5, entry.order)))
    end

    -- Displays initialize one by one: progress bar, then content
    for key, startAt in pairs(DISPLAY_SCHEDULE) do
        if t >= startAt then
            local progress = (t - startAt) / 1.2
            if progress >= 1 then
                if not b.displaysOn[key] then
                    b.displaysOn[key] = true
                    Hud.SetDisplayState(key, "ON")
                end
            else
                Hud.SetDisplayState(key, "BOOT", progress)
            end
        end
    end

    -- Diagnostics log
    local lines = {}
    for _, entry in ipairs(bootLines()) do
        if t >= entry[1] then
            table.insert(lines, entry[2])
        end
    end
    if #lines ~= b.lines then
        b.lines = #lines
        Hud.SetBootLog(lines)
    end
    if t >= 5.6 and not b.bannerShown then
        b.bannerShown = true
        Hud.SetStatusLine("SYSTEMS ONLINE")
        Hud.SetBanner(onlineText(), Hud.Colors().primary, 0)
    end
    if t >= Config.BOOT_DURATION + 2.2 then
        Hud.FadeBanner(1.2)
    end
    if t >= Config.BOOT_DURATION + 2.8 then
        finishBoot()
        Hud.SetBootLog({})
    end
end

-- ----------------------------------------------------------------------------------------------------------------
-- Transitions
-- ----------------------------------------------------------------------------------------------------------------
local function currentCameraCF(): (CFrame, number)
    local camera = workspace.CurrentCamera
    return camera.CFrame, camera.FieldOfView
end

local function beginTransition(to: string, duration: number?, evac: boolean?)
    local cf, fov = currentCameraCF()
    -- When leaving a garage-controlled view, capture the garage pose (identical to the live camera).
    if mode == Mode.GARAGE and not transition then
        local gcf, gfov = deps.garage.GetCFrame()
        if gcf then
            cf, fov = gcf, gfov
        end
    end
    ensureBuilt() -- the fade layer and displays live in the HUD; build before the first transition frame
    if avionics and to == Mode.GARAGE then
        avionics.Reset("leave cockpit", true) -- 1x, imager off, lock released, before the camera pose is captured
    end
    deps.garage.SetActive(false) -- hands over cleanly: drags released, keys ignored
    resetLook()
    transition = { t0 = now(), duration = duration or Config.TRANSITION, to = to, fromCF = cf, fromFov = fov, swapped = false, evac = evac }
    applyCursor()
    Hud.SetHintVisible(false)
end

local function eyeCFrame(torsoCF: CFrame, t: number): (CFrame, number)
    local scale = comfort() * (if avionics then avionics.ShakeScale() else 1)
    local sway = Config.SWAY * scale
    local vib = Config.VIBRATION * scale
    local swayYaw = sway * (math.sin(t * 0.37) + 0.6 * math.sin(t * 0.91 + 1.3))
    local swayPitch = sway * (math.sin(t * 0.43 + 0.5) + 0.5 * math.sin(t * 1.1))
    local jitter = Vector3.new(math.noise(t * 14, 0.3), math.noise(t * 17, 5.2), math.noise(t * 11, 8.4)) * vib
    local base = torsoCF * CFrame.new(Config.EYE_OFFSET + jitter)
    local rotated = base * CFrame.Angles(Config.BASE_PITCH + look.pitch + swayPitch, -(look.yaw + swayYaw), 0)
    -- Vertical FOV is reduced on ultrawide viewports so the horizontal field stays at MAX_HFOV or less.
    local camera = workspace.CurrentCamera
    local aspect = camera.ViewportSize.X / math.max(camera.ViewportSize.Y, 1)
    local capped = 2 * math.deg(math.atan(math.tan(math.rad(Config.MAX_HFOV / 2)) / aspect))
    local baseFov = math.clamp(math.min(Config.FOV, capped), 40, Config.FOV)
    -- M11C optical zoom: true magnification of the baseline field of view (tan(fov / 2) shrinks m-fold); 1x leaves it untouched
    return rotated, if avionics then avionics.Camera(baseFov) else baseFov
end

local function swapIn()
    local model = getModel()
    if avionics then
        avionics.Reset("enter cockpit", false)
    end
    setInterior(true)
    if model and lastTorsoCF then
        hideExterior(model, lastTorsoCF)
    end
    startBoot(not bootDone)
end

local function swapOut()
    setInterior(false)
    Hud.SetOverlayVisible(false)
end

local function finishTransition()
    local t = transition :: any
    transition = nil
    mode = t.to
    if mode == Mode.GARAGE then
        deps.garage.SetActive(true)
        Hud.SetHintVisible(true)
        modeButton.Text = "V   ENTER COCKPIT"
    else
        -- Control hints are shown for a few seconds after entering, then get out of the way.
        Hud.SetHintVisible(true)
        hintToken += 1
        local token = hintToken
        task.delay(9, function()
            if token == hintToken and mode == Mode.COCKPIT then
                Hud.SetHintVisible(false)
            end
        end)
    end
    Hud.SetFade(0)
    applyCursor()
end

local function stepTransition(camera: Camera, torsoCF: CFrame?, t: number)
    local tr = transition :: any
    local p = (now() - tr.t0) / tr.duration
    local entering = tr.to == Mode.COCKPIT
    local peak = if entering then 0.7 else 0.3
    local targetCF, targetFov
    if entering then
        targetCF, targetFov = eyeCFrame(torsoCF or lastTorsoCF :: CFrame, t)
    else
        local gcf, gfov = deps.garage.GetCFrame()
        targetCF, targetFov = gcf or tr.fromCF, gfov
    end
    local q = smooth(p)
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = tr.fromCF:Lerp(targetCF, q)
    camera.FieldOfView = tr.fromFov + (targetFov - tr.fromFov) * q
    -- Dip to black so the lens crossing the hull is never visible
    local alpha
    if p < peak then
        alpha = smooth((p - (peak - 0.35)) / 0.35)
    else
        alpha = 1 - smooth((p - peak) / (1 - peak))
        if p - peak < 0.06 then
            alpha = 1
        end
    end
    if tr.evac then
        alpha = alpha * 0.6 -- keep the evacuation warning readable through the dip
    end
    Hud.SetFade(alpha, if entering then "PILOT LINK" else nil)
    if not tr.swapped and p >= peak then
        tr.swapped = true
        if entering then
            swapIn()
        else
            swapOut()
        end
    end
    if p >= 1 then
        if not tr.swapped then
            tr.swapped = true
            if entering then
                swapIn()
            else
                swapOut()
            end
        end
        finishTransition()
    end
end

-- ----------------------------------------------------------------------------------------------------------------
-- Ejection integration
-- ----------------------------------------------------------------------------------------------------------------
local function beginEvacuationExit()
    local ev = evacuation :: any
    ev.exiting = true
    -- The server marked the pilot safe before this attribute changed; the camera leaves the mech well before the
    -- server disables it (Ejection.DISABLE_DELAY = 1.0 s).
    deps.garage.SetView(158, 14, 42, 9)
    beginTransition(Mode.GARAGE, 0.7, true)
    cursorFree = true
    applyCursor()
end

local function onEvacuated()
    -- Only relevant when the pilot is in (or entering) the cockpit; garage mode keeps the existing garage presentation.
    if evacuation then
        return
    end
    local entering = transition ~= nil and (transition :: any).to == Mode.COCKPIT
    if mode ~= Mode.COCKPIT and not entering then
        return
    end
    evacuation = { t0 = now(), restoreCockpit = true, phase = "WARNING", exiting = false, exitAt = now() + 0.45 }
    if avionics then
        avionics.Reset("safe ejection", false)
    end
    Hud.SetEvacuation("WARNING")
    Hud.SetStatusLine("EVACUATION")
    Audio.Blip(0.9)
    if entering then
        beginEvacuationExit() -- still mid-transition: leave immediately
    end
end

local function watchModel(model: Model?)
    if model == watched then
        return
    end
    if watchConn then
        watchConn:Disconnect()
        watchConn = nil
    end
    watched = model
    if avionics then
        avionics.Reset("machine changed", false) -- a rebuilt machine (loadout install, ejection rebuild, respawn) starts at 1x
    end
    if model then
        watchConn = model:GetAttributeChangedSignal("State"):Connect(function()
            if model:GetAttribute("State") == "PILOT_EVACUATED" then
                onEvacuated()
            end
        end)
        Telemetry.Publish("mech.state", model:GetAttribute("State"), "LIVE")
    end
end

local function stepEvacuation(t: number)
    local ev = evacuation :: any
    local elapsed = now() - ev.t0
    if not ev.exiting then
        -- Critical warning: indicators and cabin lights pulse red for the first beat, camera still in the cockpit.
        Builder.SetAlert(cockpit :: Builder.Cockpit, 0.5 + 0.5 * math.sin(t * 16))
        if now() >= ev.exitAt then
            Builder.SetAlert(cockpit :: Builder.Cockpit, 0)
            beginEvacuationExit()
        end
    end
    if ev.phase == "WARNING" then
        Hud.PulseEvacuation(t)
        if elapsed > 1.0 then
            ev.phase = "EVACUATED"
            Hud.SetEvacuation("EVACUATED")
        end
    end
    -- Recovery: a fresh OPERATIONAL mech with a posed torso. Restore the cockpit the pilot ejected from.
    local model = getModel()
    if elapsed > 3.0 and model and model:GetAttribute("State") == "OPERATIONAL" and deps.animator.TorsoCF(model) and not transition then
        evacuation = nil
        Hud.SetEvacuation(nil)
        cursorFree = false
        mode = Mode.GARAGE
        applyCursor()
        if ev.restoreCockpit then
            lastTorsoCF = deps.animator.TorsoCF(model)
            beginTransition(Mode.COCKPIT)
        end
    end
end

-- ----------------------------------------------------------------------------------------------------------------
-- Public controls
-- ----------------------------------------------------------------------------------------------------------------
function Mode.Toggle()
    if transition or evacuation then
        return
    end
    if mode == Mode.GARAGE then
        local model = getModel()
        local torso = model and model:GetAttribute("State") == "OPERATIONAL" and deps.animator.TorsoCF(model)
        if not torso then
            return
        end
        lastTorsoCF = torso
        beginTransition(Mode.COCKPIT)
    else
        beginTransition(Mode.GARAGE)
    end
end

function Mode.Recenter()
    look.targetYaw, look.targetPitch = 0, 0
end

-- Debug/test hook (also used by the Studio verification): set head-look target in degrees.
function Mode.SetLookDegrees(yaw: number, pitch: number)
    look.targetYaw = math.clamp(math.rad(yaw), -Config.MAX_YAW, Config.MAX_YAW)
    look.targetPitch = math.clamp(math.rad(pitch), -Config.MAX_PITCH_DOWN, Config.MAX_PITCH_UP)
end

function Mode.Current(): string
    return mode
end

function Mode.IsTransitioning(): boolean
    return transition ~= nil
end

function Mode.IsEvacuating(): boolean
    return evacuation ~= nil
end

function Mode.SkipBoot()
    if boot then
        boot.skipped = true
    end
end

function Mode.Stats()
    local c = cockpit
    return {
        mode = mode,
        bootDone = bootDone,
        interiorActive = interiorActive,
        parts = c and c.stats.parts or 0,
        meshParts = c and c.stats.meshParts or 0,
        aiAssets = c and c.stats.aiAssets or {},
        screens = c and c.stats.screens or 0,
        indicators = c and c.stats.indicators or 0,
        lights = c and c.stats.lights or 0,
        hiddenExteriorParts = #hidden,
        stepMs = perf.stepMs,
        look = { yaw = math.deg(look.yaw), pitch = math.deg(look.pitch) },
        audio = Audio.Report(),
        displays = Hud.DisplayKeys(),
        package = packageInfo.id, palette = Hud.Palette(), equipment = packageInfo.equipment,
        annunciators = if cockpit then #Warnings.Keys else 0,
    }
end

-- ----------------------------------------------------------------------------------------------------------------
-- Annunciators (M11C): six dash lamps from real telemetry, and the recon sensor bank's status lamps
-- ----------------------------------------------------------------------------------------------------------------
function Mode.UpdateWarnings(t: number)
    local c = cockpit
    if not c then
        return
    end
    local fractions = Telemetry.Value("damage.regions", nil)
    local capacity = math.max(Telemetry.Value("energy.capacity", 160), 1)
    local st = Telemetry.Value("avionics.state", nil)
    local rd = st and st.rd
    local arms = 0
    if fractions then
        arms = (if (fractions.ARM_L or 1) <= 0 then 1 else 0) + (if (fractions.ARM_R or 1) <= 0 then 1 else 0)
    end
    local levels = Warnings.Evaluate({
        deployed = Telemetry.Value("deployment.state", "STOWED") == "ACTIVE",
        capFraction = Telemetry.Value("energy.charge", capacity) / capacity,
        reactorFraction = fractions and fractions.REACTOR or 1, reactorFactor = Telemetry.Value("damage.reactor", 1),
        coreFraction = fractions and fractions.CORE or 1, thermal = Telemetry.Value("energy.thermal", 0),
        radarFitted = Telemetry.Value("avionics.hasRadar", false), radarState = rd and rd.s or nil,
        impaired = st ~= nil and st.notes ~= nil and #st.notes > 0, armsFailed = arms,
    })
    local blink = if (t * 2.5) % 1 < 0.5 then 1 else 0.15
    for key, level in pairs(levels) do
        Builder.SetAnnunciator(c, key, level, blink)
    end
    Builder.SetStatusLamp(c, "RADAR", rd ~= nil and rd.s == "ONLINE")
    Builder.SetStatusLamp(c, "THERMAL", st ~= nil and st.th ~= nil and st.th.on == true)
    Builder.SetStatusLamp(c, "OPTICS", st ~= nil and (st.zm or 1) > 1)
    Builder.SetStatusLamp(c, "LOCK", st ~= nil and st.lock ~= nil and st.lock.st == "TRACK")
end

function Mode.SetAvionics(client: any)
    avionics = client
end

-- ----------------------------------------------------------------------------------------------------------------
-- Frame step
-- ----------------------------------------------------------------------------------------------------------------
local function step(dt: number)
    local started = os.clock()
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    local t = now()
    local model = getModel()
    watchModel(model)
    local torsoCF = model and model:GetAttribute("State") == "OPERATIONAL" and deps.animator.TorsoCF(model) or nil
    if torsoCF then
        lastTorsoCF = torsoCF
    end

    -- Head-look from the arrow keys (mouse deltas arrive through InputChanged)
    if mode == Mode.COCKPIT and not transition then
        local key = UserInputService.IsKeyDown
        local dx = (key(UserInputService, Enum.KeyCode.Right) and 1 or 0) - (key(UserInputService, Enum.KeyCode.Left) and 1 or 0)
        local dy = (key(UserInputService, Enum.KeyCode.Up) and 1 or 0) - (key(UserInputService, Enum.KeyCode.Down) and 1 or 0)
        local lookScale = if avionics then avionics.LookScale() else 1
        look.targetYaw += dx * dt * Config.LOOK_KEY_RATE * lookScale
        look.targetPitch += dy * dt * Config.LOOK_KEY_RATE * lookScale
        look.targetYaw = math.clamp(look.targetYaw, -Config.MAX_YAW, Config.MAX_YAW)
        look.targetPitch = math.clamp(look.targetPitch, -Config.MAX_PITCH_DOWN, Config.MAX_PITCH_UP)
        local alpha = 1 - math.exp(-Config.LOOK_SMOOTH * dt)
        look.yaw += (look.targetYaw - look.yaw) * alpha
        look.pitch += (look.targetPitch - look.pitch) * alpha
    end

    if transition then
        stepTransition(camera, torsoCF, t)
    elseif mode == Mode.COCKPIT and not (evacuation and evacuation.exiting) then
        if lastTorsoCF then
            local cf, fov = eyeCFrame(lastTorsoCF, t)
            camera.CameraType = Enum.CameraType.Scriptable
            camera.CFrame = cf
            camera.FieldOfView = fov
        end
    end

    if interiorActive and cockpit and lastTorsoCF then
        Builder.Place(cockpit, lastTorsoCF)
        stepBoot()
        -- Re-assert the hidden exterior set a few times a second (a rebuilt mech or ArmorGrade can reset it)
        if model and (model ~= hiddenFor or now() - hiddenAt > 0.5) and torsoCF then
            if model ~= hiddenFor then
                if (model:GetAttribute("PartCount") or 0) > 0 then
                    hideExterior(model, torsoCF)
                end
            else
                hiddenAt = now()
                for _, part in ipairs(hidden) do
                    part.LocalTransparencyModifier = 1
                end
            end
        end
        local look3 = camera.CFrame.LookVector
        Hud.SetHeading(math.deg(math.atan2(look3.X, -look3.Z)))
        if model then
            local chassisCF = deps.animator.ChassisCF(model)
            if typeof(chassisCF) == "CFrame" then
                local forward = chassisCF.LookVector
                Hud.SetChassisHeading(math.deg(math.atan2(forward.X, -forward.Z)))
            end
        end
        Hud.Step(dt, t)
        if t - lastWarnAt > 0.1 then
            lastWarnAt = t
            Mode.UpdateWarnings(t)
        end
    end
    if avionics then
        avionics.Step(dt, interiorActive and mode == Mode.COCKPIT and not transition and not evacuation)
        if cockpit then
            Builder.SetCanopyClear(cockpit, avionics.ThermalActive())
        end
    end
    if evacuation then
        stepEvacuation(t)
    end

    -- Telemetry published by the cockpit itself (10 Hz)
    if t - lastTelemetry > 0.1 and lastTorsoCF and model then
        lastTelemetry = t
        local baseCF = deps.animator.ChassisCF(model)
        if typeof(baseCF) == "CFrame" then
            local _, yaw = baseCF:ToObjectSpace(lastTorsoCF):ToOrientation()
            Telemetry.Publish("pilot.torsoYaw", math.floor(math.deg(yaw) * 10 + 0.5) / 10, "LIVE")
        end
    end

    perf.samples += 1
    perf.stepMs += ((os.clock() - started) * 1000 - perf.stepMs) * 0.05
end

-- ----------------------------------------------------------------------------------------------------------------
-- Start
-- ----------------------------------------------------------------------------------------------------------------
local function buildControls()
    controlsGui = Instance.new("ScreenGui")
    controlsGui.Name = "IronframeModeSwitch"
    controlsGui.ResetOnSpawn = false
    controlsGui.IgnoreGuiInset = true
    controlsGui.DisplayOrder = 30
    controlsGui.Parent = player:WaitForChild("PlayerGui")

    local function styled(button: TextButton, accent: Color3)
        button.BackgroundColor3 = COLORS.panel
        button.BackgroundTransparency = 0.15
        button.AutoButtonColor = true
        button.BorderSizePixel = 0
        button.Font = Enum.Font.Michroma
        button.TextSize = 14
        button.TextColor3 = accent
        local stroke = Instance.new("UIStroke")
        stroke.Color = accent
        stroke.Thickness = 1.5
        stroke.Parent = button
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 3)
        corner.Parent = button
    end

    modeButton = Instance.new("TextButton")
    modeButton.Name = "ModeSwitch"
    modeButton.AnchorPoint = Vector2.new(1, 0)
    modeButton.Position = UDim2.new(1, -24, 0, 24)
    modeButton.Size = UDim2.fromOffset(250, 44)
    modeButton.Text = "V   ENTER COCKPIT"
    styled(modeButton, COLORS.cyan)
    modeButton.Parent = controlsGui
    modeButton.MouseButton1Click:Connect(Mode.Toggle)

    ejectButton = Instance.new("TextButton")
    ejectButton.Name = "CockpitEject"
    ejectButton.AnchorPoint = Vector2.new(0, 1)
    ejectButton.Position = UDim2.new(0, 24, 1, -60)
    ejectButton.Size = UDim2.fromOffset(250, 40)
    ejectButton.Text = "X   TEST SAFE EJECTION"
    ejectButton.Visible = false
    styled(ejectButton, COLORS.amber)
    ejectButton.Parent = controlsGui
    ejectButton.MouseButton1Click:Connect(function()
        Mode.RequestEject()
    end)
end

function Mode.RequestEject()
    if mode ~= Mode.COCKPIT or transition or evacuation then
        return
    end
    local remote = deps.remotes:FindFirstChild("RequestTestEject")
    if remote then
        (remote :: RemoteEvent):FireServer()
    end
end

function Mode.CyclePreset(direction: number)
    if mode ~= Mode.COCKPIT or transition or evacuation then
        return
    end
    local order = Telemetry.Value("mech.presetOrder", nil)
    local current = Telemetry.Value("mech.preset", nil)
    local remote = deps.remotes:FindFirstChild("SetPreset")
    if order and current and remote then
        local index = table.find(order, current) or 1
        index = (index - 1 + direction) % #order + 1
        ;(remote :: RemoteEvent):FireServer(order[index])
    end
end

function Mode.Start(dependencies)
    deps = dependencies
    local folder = Instance.new("Folder")
    folder.Name = "IronframeCockpitClient" -- client-created: never replicated to the server or other players
    folder.Parent = workspace
    buildControls()
    Audio.Start()
    Telemetry.Subscribe(function(key, channel)
        if key == "loadout.cockpit" then
            Mode.ApplyPackage(channel.value)
        end
    end)
    local current = Telemetry.Value("loadout.cockpit", nil)
    if current then
        Mode.ApplyPackage(current)
    end
    task.defer(ensureBuilt) -- pre-build the interior during the garage view so entering never hitches

    -- Studio verification interface (client-side only): drive the same public functions the keys and buttons use.
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeCockpitControl"
    control.OnInvoke = function(command: string, a: any, b: any)
        if command == "toggle" then
            Mode.Toggle()
        elseif command == "look" then
            Mode.SetLookDegrees(a, b)
        elseif command == "recenter" then
            Mode.Recenter()
        elseif command == "eject" then
            Mode.RequestEject()
        elseif command == "preset" then
            Mode.CyclePreset(a or 1)
        elseif command == "skipBoot" then
            Mode.SkipBoot()
        elseif command == "stats" then
            return Mode.Stats()
        end
        return nil
    end
    control.Parent = player:WaitForChild("PlayerScripts")

    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end
        local code = input.KeyCode
        if code == Enum.KeyCode.V then
            Mode.Toggle()
        elseif mode == Mode.COCKPIT and not transition then
            if code == Enum.KeyCode.R then
                Mode.Recenter()
            elseif code == Enum.KeyCode.X then
                Mode.RequestEject()
            elseif code == Enum.KeyCode.Space then
                Mode.SkipBoot()
            elseif code == Enum.KeyCode.Q then
                Mode.CyclePreset(-1)
            elseif code == Enum.KeyCode.E then
                Mode.CyclePreset(1)
            elseif code == Enum.KeyCode.LeftAlt then
                cursorFree = true
                applyCursor()
            end
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.LeftAlt and not evacuation then
            cursorFree = false
            applyCursor()
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement and mode == Mode.COCKPIT and not transition and not cursorFree and not evacuation then
            local lookScale = if avionics then avionics.LookScale() else 1
            look.targetYaw = math.clamp(look.targetYaw + input.Delta.X * Config.LOOK_SENSITIVITY * lookScale, -Config.MAX_YAW, Config.MAX_YAW)
            look.targetPitch = math.clamp(look.targetPitch - input.Delta.Y * Config.LOOK_SENSITIVITY * lookScale, -Config.MAX_PITCH_DOWN, Config.MAX_PITCH_UP)
        end
    end)
    RunService:BindToRenderStep("IronframeCockpitMode", Enum.RenderPriority.Camera.Value + 2, step)
end

return Mode
