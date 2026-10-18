local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Loadouts = require(Shared:WaitForChild("Loadouts"))
local Compiler = require(Shared:WaitForChild("LoadoutCompiler"))
local Factory = require(script.Parent.MechFactory)
local Ejection = require(script.Parent.EjectionSequence)
local SelfTest = require(script.Parent.SelfTest)
local WorldBuilder = require(script.Parent.WorldBuilder)
local Locomotion = require(script.Parent.Locomotion)
local Deployment = require(script.Parent.Deployment)
local BayControl = require(script.Parent.BayControl)
local RunService = game:GetService("RunService")
local EnergySystems = require(script.Parent.EnergySystems)

local Weapons = require(script.Parent.Weapons)
local CombatTargets = require(script.Parent.CombatTargets)
local Destructibles = require(script.Parent.Destructibles)
local RangeControl = require(script.Parent.RangeControl)
local TankCombat = require(script.Parent.TankCombat) -- M10B
local SortieReport = require(script.Parent.SortieReport) -- M11A
local BastionDamage = require(script.Parent.BastionDamage) -- M10B
local AvionicsService = require(script.Parent.AvionicsService) -- M11C
local sessions = {}
local selfTestResult = { passed = 0, total = 0, failed = {} }
local bayCounter = 0
local remotes = Instance.new("Folder")
remotes.Name = "IronframeRemotes"
remotes.Parent = ReplicatedStorage

local function remote(className, name)
    local obj = Instance.new(className)
    obj.Name = name
    obj.Parent = remotes
    return obj
end
local GetGarageState = remote("RemoteFunction", "GetGarageState")
local SetPreset = remote("RemoteEvent", "SetPreset")
local RequestTestEject = remote("RemoteEvent", "RequestTestEject")
local StateChanged = remote("RemoteEvent", "StateChanged")
local RequestDeploy = remote("RemoteEvent", "RequestDeploy")
local RequestReturn = remote("RemoteEvent", "RequestReturn")
local DriveInput = remote("RemoteEvent", "DriveInput") -- (throttle, steer), sanitised and clamped server-side
local RequestShield = remote("RemoteEvent", "RequestShield")
local RequestEnergyTest = remote("RemoteEvent", "RequestEnergyTest")
local RequestEnergyProfile = remote("RemoteEvent", "RequestEnergyProfile") -- (profileId) validated against EnergyProfiles
local RequestLoadout = remote("RemoteEvent", "RequestLoadout") -- M11A: { mounts = {socket = id|false}, systems = {slot = id} }, validated by LoadoutCompiler.ApplyRequest
local RequestLoadoutRevert = remote("RemoteEvent", "RequestLoadoutRevert") -- M11A: swap back to the configuration before the last install

local RequestAvionics = remote("RemoteEvent", "RequestAvionics") -- M11C: (command, a, b) validated by AvionicsService.Command: "zoom" | "thermal" | "acquire" | "release"
local AvionicsUpdate = remote("RemoteEvent", "AvionicsUpdate") -- M11C: server -> owner, one bounded packet (contacts, lock, thermal list, modes) at most 10 per second

local WeaponIntent = remote("RemoteEvent", "WeaponIntent")
local WeaponEffects = remote("RemoteEvent", "WeaponEffects")
local DestructionFx = remote("RemoteEvent", "DestructionFx") -- M10A: batched cosmetic destruction events (server -> owner)
local RequestRangeReset = remote("RemoteEvent", "RequestRangeReset") -- M10A: "ALL" | "VEHICLES" | "STRUCTURES"
local CombatFx = remote("RemoteEvent", "CombatFx") -- M10B: server -> owner, arrays of cosmetic shell events (fire / end)
local RequestCombatMode = remote("RemoteEvent", "RequestCombatMode") -- M10B/M10C: "PASSIVE" | "ACTIVE" | "MECH" (allow-listed, validated)

local function validatePresets()
    local count = 0
    for _, id in ipairs(Loadouts.order) do
        local loadout = Loadouts.presets[id]
        assert(loadout ~= nil, "Missing loadout " .. id)
        local compiled = Compiler.Compile(loadout)
        assert(compiled.valid, id .. " is invalid: " .. table.concat(compiled.issues, "; "))
        count += 1
        print(string.format("[IF-STEP-02] %s | mass=%.1f/%.1ft power=%.1f/%.1f heat=%.1f/%.1f",
            id, compiled.metrics.mass, compiled.metrics.massLimit,
            compiled.metrics.powerDraw, compiled.metrics.powerOutput,
            compiled.metrics.heatPerSecond, compiled.metrics.coolingPerSecond))
    end
    print("[IF-STEP-02] Verified loadouts: " .. count)
end

local presetNames = {}
for _, id in ipairs(Loadouts.order) do presetNames[id] = Loadouts.presets[id].name end

local function publicState(player, message)
    local session = sessions[player]
    if not session then
        return { ready = false, message = "Garage is initializing" }
    end
    local loadout = session.loadout
    return {
        ready = true,
        presetId = session.presetId,
        presetName = presetNames[session.presetId] .. (if session.customized then " (ENGINEERED)" else ""),
        presetOrder = Loadouts.order,
        presetNames = presetNames,
        -- M11A: the session's actual configuration and its compiled effective specification (the client compares candidates against it)
        loadout = Compiler.Clone(loadout),
        customized = session.customized == true,
        canRevert = session.previousLoadout ~= nil,
        lastSortie = session.lastSortie,
        compiled = session.compiled,
        machineState = session.machineState,
        pilotSafe = session.pilotSafe,
        deployment = session.deployment or "STOWED",
        reactor = Deployment.ReactorFor(session.deployment),
        canDeploy = (Deployment.ValidateDeploy(session, session.compiled)),
        diagnostics = {
            tests = selfTestResult,
            rig = Factory.Describe(session.mech),
        },
        message = message or "System nominal",
    }
end

-- Drops the drive controller and puts the bay back in showroom state. Safe to call at any time (ejection rebuilds,
-- player leaving, preset reassembly): the loadout lives in session.presetId and is never touched here.
local function resetDeployment(session)
    if session.controller then
        Locomotion.Destroy(session.controller)
        session.controller = nil
    end
    session.deployment = "STOWED"
    session.deployAt, session.recallAt, session.dockUntil = nil, nil, nil
    if session.bay and BayControl.AreDoorsOpen(session.bay) then
        BayControl.SetDoors(session.bay, false)
    end
end

local function setDeploymentAttributes(session)
    local mech = session.mech
    if mech then
        mech:SetAttribute("Deployment", session.deployment)
        mech:SetAttribute("Deployed", Deployment.IsDeployed(session.deployment))
        mech:SetAttribute("ReactorState", Deployment.ReactorFor(session.deployment))
    end
end

local function assemble(player, message)
    local session = sessions[player]
    if not session then return end
    resetDeployment(session)
    if session.mech then
        session.mech:Destroy()
    end
    -- M11A: the session owns its loadout (a copy of a factory preset, or the engineered build). It is compiled ONCE here; the deployed
    -- runtime (energy, drive, structure, weapons) is built from that single result and nothing recompiles per frame.
    if not session.loadout then
        session.loadout = Compiler.Clone(Loadouts.presets[session.presetId])
    end
    local compiled = Compiler.Compile(session.loadout)
    if not compiled.valid then
        warn("[IF] session loadout invalid, restoring the factory preset:", table.concat(compiled.issues, "; "))
        session.loadout, session.customized = Compiler.Clone(Loadouts.presets[session.presetId]), false
        compiled = Compiler.Compile(session.loadout)
    end
    session.compiled = compiled
    local model = Factory.Create(player.UserId, if session.customized then "CUSTOM" else session.presetId, session.loadout, session.bayPosition)
    model.Parent = workspace.IronframeMechs
    session.mech = model
    session.machineState = "OPERATIONAL"
    model:SetAttribute("BuildLabel", compiled.label)
    model:SetAttribute("TopSpeed", compiled.locomotion.maxForward)
    session.power = EnergySystems.Create(model, compiled.energy)
    Weapons.Create(session)
    session.damageCapacity = compiled.structure
    BastionDamage.Create(session) -- fresh, fully repaired components (at the build's own structure) for every assembly
    AvionicsService.Attach(session) -- M11C: the sensor runtime of this build (fresh tracker, no lock, 1x, thermal off); the equipment is session.loadout's
    EnergySystems.Publish(session.power, true)
    setDeploymentAttributes(session)
    StateChanged:FireClient(player, publicState(player, message or "Loadout installed"))
    print(string.format("[IF-STEP-03] Assembled %s for userId %d", session.presetId, player.UserId))
end

AvionicsService.Init({ remote = AvionicsUpdate, sessions = sessions })
RequestAvionics.OnServerEvent:Connect(AvionicsService.Command)
RangeControl.Init(DestructionFx, RequestRangeReset, sessions)
TankCombat.Init({ sessions = sessions, fx = CombatFx, weaponFx = WeaponEffects })
WorldBuilder.Initialize()
validatePresets()
selfTestResult = SelfTest.Run()

GetGarageState.OnServerInvoke = function(player)
    return publicState(player)
end

SetPreset.OnServerEvent:Connect(function(player, presetId)
    local session = sessions[player]
    if not session or session.machineState ~= "OPERATIONAL" then return end
    if not Deployment.AllowsLoadoutChange(session.deployment) then return end -- loadouts are a hangar activity
    if type(presetId) ~= "string" or #presetId > 32 then return end
    if not Loadouts.presets[presetId] then return end -- Only server-authored presets accepted.
    if os.clock() - session.lastChange < 0.25 then return end
    session.lastChange = os.clock()
    local compiled = Compiler.Compile(Loadouts.presets[presetId])
    if not compiled.valid then
        warn("[IF] Rejected invalid preset " .. presetId)
        return
    end
    session.presetId = presetId
    -- A factory preset restores every weapon / reactor / drive / armour slot. M11C: it does not touch the cockpit package or the avionics (a preset
    -- is a weapon loadout). If the retained equipment would not fit the preset's mass or power budget the factory cockpit equipment is restored instead.
    local fresh = Compiler.Clone(Loadouts.presets[presetId])
    local keptCockpit, keptAvionics = session.loadout and session.loadout.cockpit, session.loadout and session.loadout.avionics
    fresh.cockpit, fresh.avionics = keptCockpit, if keptAvionics then table.clone(keptAvionics) else nil
    local message = "Loadout installed"
    if (keptCockpit ~= nil or keptAvionics ~= nil) and not Compiler.Compile(fresh).valid then
        fresh.cockpit, fresh.avionics = nil, nil
        message = "COCKPIT EQUIPMENT RESET: DOES NOT FIT THIS PRESET"
    end
    session.loadout, session.customized, session.previousLoadout = fresh, not Compiler.Same(fresh, Loadouts.presets[presetId]), nil
    assemble(player, message)
end)

-- M11A: engineering. The client sends component ids only; LoadoutCompiler.ApplyRequest validates every field against the registry catalog
-- (whitelisted sockets / slots, offered components, hardpoint fit, mass and power budgets) and nothing numeric is ever accepted.
RequestLoadout.OnServerEvent:Connect(function(player, request)
    local session = sessions[player]
    if not session or session.machineState ~= "OPERATIONAL" or not Deployment.AllowsLoadoutChange(session.deployment) then return end
    if os.clock() - session.lastChange < 0.25 then return end
    session.lastChange = os.clock()
    local out, why = Compiler.ApplyRequest(session.loadout, request)
    if not out then
        StateChanged:FireClient(player, publicState(player, "REJECTED: " .. tostring(why)))
        return
    end
    session.previousLoadout = session.loadout
    session.loadout = out
    session.customized = not Compiler.Same(out, Loadouts.presets[session.presetId])
    assemble(player)
end)

RequestLoadoutRevert.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or not session.previousLoadout or session.machineState ~= "OPERATIONAL" or not Deployment.AllowsLoadoutChange(session.deployment) then return end
    if os.clock() - session.lastChange < 0.25 then return end
    session.lastChange = os.clock()
    session.loadout, session.previousLoadout = session.previousLoadout, nil
    session.customized = not Compiler.Same(session.loadout, Loadouts.presets[session.presetId])
    assemble(player)
end)

-- Runs the existing guaranteed-safe ejection sequence. `forced` marks a combat core failure (M10B) instead of the manual test
-- request: it skips the manual rate limit and keeps the abandoned machine standing about a second longer, so its terminal
-- shutdown (sparks, smoke, lights failing, final burst) is actually seen before it is removed.
local function runEjection(player, session, forced)
    if not session or session.machineState ~= "OPERATIONAL" or not session.mech then return end
    session.lastEject = os.clock()
    local extra = if forced then 1.2 else 0
    local delayFn = function(seconds, fn) return task.delay(seconds + extra, fn) end

    local pod
    -- SAFETY INVARIANT (enforced inside Ejection.Run): pilotSafe is set before any hook below runs.
    Ejection.Run(session, {
        onPilotSafe = function()
            SortieReport.Finish(session, if forced then "EJECTED - CORE FAILURE" else "EJECTED")
            session.mech:SetAttribute("State", "PILOT_EVACUATED")
            pcall(Weapons.Cancel, session)
            if session.power then pcall(EnergySystems.Cancel, session.power) end
            -- Where the mech is right now (the capsule rises from here, deployed or not). Read before anything can fail.
            local origin = session.bayPosition
            if session.controller then
                origin = Locomotion.Position(session.controller)
            end
            -- Movement can never get in the way of ejection: lock the drive first, and isolate it from everything below.
            local okAbort, abortErr = pcall(function()
                if session.controller then
                    session.controller.autopilot = nil
                    session.controller.input.throttle, session.controller.input.steer = 0, 0
                    Locomotion.SetLocked(session.controller, true)
                end
                if Deployment.Transition(session, "EJECTED") then
                    setDeploymentAttributes(session)
                end
            end)
            if not okAbort then
                warn("[IF-DEPLOY] drive lock during ejection failed (ejection continues):", abortErr)
            end
            StateChanged:FireClient(player, publicState(player, "PILOT SAFE - EMERGENCY EJECTION"))
            pod = Instance.new("Part")
            pod.Name = "InvulnerableEscapeCapsule"
            pod.Shape = Enum.PartType.Ball
            pod.Size = Vector3.new(2.1, 3.0, 2.1)
            pod.Color = Color3.fromRGB(255, 179, 65)
            pod.Material = Enum.Material.Metal
            pod.Anchored = true
            pod.CanCollide = false
            pod.CanQuery = false
            pod.CanTouch = false
            pod:SetAttribute("Targetable", false)
            pod.Position = origin + Vector3.new(0, 15.5, 0)
            pod.Parent = workspace
            TweenService:Create(pod, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = pod.Position + Vector3.new(0, 27, -6)
            }):Play()
            print(string.format("[IF-STEP-04] Guaranteed safe ejection for userId %d", player.UserId))
        end,
        onMechDisabled = function()
            -- The abandoned machine goes out with a final burst where it stood (cosmetic, owner only).
            local district = session.bay and Destructibles.Get(session.bay)
            if district and session.controller then
                local at = Locomotion.Position(session.controller) + Vector3.new(0, 9, 0)
                Destructibles.Emit(district, { t = "x", f = "machine", k = "explosion", cf = CFrame.new(at), s = Vector3.new(12, 10, 12), c = Color3.fromRGB(70, 70, 70), mat = Enum.Material.Metal, e = 2.4 }, true)
            end
            if session.controller then
                Locomotion.Destroy(session.controller)
                session.controller = nil
            end
            if session.mech then
                session.mech:Destroy()
                session.mech = nil
            end
            StateChanged:FireClient(player, publicState(player, "Mech disabled. Pilot safe. Rebuilding..."))
        end,
        onCleanup = function()
            if pod then pod:Destroy() end
        end,
        onRebuild = function()
            assemble(player)
        end,
        isStale = function()
            return sessions[player] ~= session
        end,
    }, delayFn)
end

RequestTestEject.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or session.machineState ~= "OPERATIONAL" or not session.mech then return end
    if os.clock() - session.lastEject < 8 then return end
    runEjection(player, session, false)
end)

-- M10B: core failure on the Bastion is answered by the same guaranteed-safe ejection. It never depends on pilot state (there is none).
BastionDamage.onCoreFailure = function(session)
    if session.player and sessions[session.player] == session then
        runEjection(session.player, session, true)
    end
end

RequestCombatMode.OnServerEvent:Connect(function(player, mode)
    local session = sessions[player]
    if not session or type(mode) ~= "string" or (mode ~= "PASSIVE" and mode ~= "ACTIVE" and mode ~= "MECH") then return end
    if session.deployment ~= "ACTIVE" or session.machineState ~= "OPERATIONAL" or not session.bay then return end
    if os.clock() - (session.lastCombatMode or -100) < 0.4 then return end
    session.lastCombatMode = os.clock()
    local district = Destructibles.Get(session.bay)
    if district then
        TankCombat.SetMode(district, mode, "pilot request")
    end
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- M07 deployment: showroom -> walking mech -> back. The loadout (session.presetId) is only read, never rewritten, and the
-- mech model is the SAME instance throughout (no duplicate mechs); only a drive controller + hull part come and go.
-- ---------------------------------------------------------------------------------------------------------------------
local function notify(player, message)
    StateChanged:FireClient(player, publicState(player, message))
end

local function finishDock(player, session)
    if session.controller then
        Locomotion.Destroy(session.controller)
        session.controller = nil
    end
    if Deployment.Transition(session, "STOWED") then
        SortieReport.Finish(session, "DOCKED")
        BastionDamage.Repair(session) -- the hangar rebuilds every component between sorties
        session.deployAt, session.recallAt, session.dockUntil = nil, nil, nil
        BayControl.SetDoors(session.bay, false)
        session.mech:SetAttribute("DockMode", nil)
        setDeploymentAttributes(session)
        notify(player, "Docked. Hangar mode restored")
        print(string.format("[IF-DEPLOY] userId %d docked; showroom restored", player.UserId))
    end
end

RequestDeploy.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or os.clock() - session.lastDeploy < 1 then return end
    session.lastDeploy = os.clock()
    local compiled = session.compiled
    local ok, reason = Deployment.ValidateDeploy(session, compiled)
    if not ok then
        notify(player, "DEPLOY REFUSED: " .. tostring(reason))
        print(string.format("[IF-DEPLOY] refused for userId %d: %s", player.UserId, tostring(reason)))
        return
    end
    Deployment.Transition(session, "DEPLOYING")
    session.controller = Locomotion.Create(session.mech, session.mech:GetAttribute("ChassisId"), session.bayPosition, 0, compiled.locomotion)
    session.controller.energySystems = session.power
    SortieReport.Begin(session)
    EnergySystems.ResetProfile(session.power)
    BastionDamage.Apply(session)
    session.deployAt = os.clock() + math.max(Deployment.STARTUP_TIME, BayControl.DOOR_TIME)
    BayControl.SetDoors(session.bay, true)
    setDeploymentAttributes(session)
    notify(player, "Reactor starting. Doors opening behind you (+Z); turn around to exit")
    print(string.format("[IF-DEPLOY] userId %d deploying preset %s", player.UserId, session.presetId))
end)

RequestReturn.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or session.deployment ~= "ACTIVE" or not session.controller then return end
    local c = session.controller
    Deployment.Transition(session, "DOCKING")
    Weapons.Cancel(session)
    EnergySystems.Cancel(session.power)
    c.input.throttle, c.input.steer = 0, 0
    local inside = math.abs(c.state.z - session.bayPosition.Z) < 55 and math.abs(c.state.x - session.bayPosition.X) < 60
    if inside then
        Locomotion.SetAutopilot(c, { x = session.bayPosition.X, z = session.bayPosition.Z, yaw = 0 })
        session.dockUntil = os.clock() + Deployment.DOCK_TIMEOUT
        session.mech:SetAttribute("DockMode", "AUTOPILOT")
        notify(player, "Returning to hangar. Autopilot engaged")
    else
        Locomotion.SetLocked(c, true)
        session.recallAt = os.clock() + Deployment.RECALL_FADE
        session.mech:SetAttribute("DockMode", "RECALL")
        notify(player, "Recalling to hangar")
    end
    setDeploymentAttributes(session)
end)

DriveInput.OnServerEvent:Connect(function(player, throttle, steer, sprint)
    local session = sessions[player]
    if not session or not session.controller then return end
    local now = os.clock()
    if now - session.lastDriveInput < 0.02 then return end -- rate limit (clients send ~10-20 Hz)
    session.lastDriveInput = now
    if not Deployment.AcceptsInput(session.deployment) then return end
    Locomotion.SetInput(session.controller, throttle, steer, sprint)
end)

RequestShield.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or not session.power or session.machineState ~= "OPERATIONAL" then return end
    if os.clock() - (session.lastShield or -100) < 0.15 then return end
    session.lastShield = os.clock()
    EnergySystems.Activate(session.power, session.deployment == "ACTIVE")
end)
RequestEnergyProfile.OnServerEvent:Connect(function(player, profileId)
    local session = sessions[player]
    if not session or not session.power or session.deployment ~= "ACTIVE" or session.machineState ~= "OPERATIONAL" then return end
    if os.clock() - (session.lastProfileRequest or -100) < 0.1 then return end -- packet limit; the real interval lives in EnergyProfiles
    session.lastProfileRequest = os.clock()
    EnergySystems.RequestProfile(session.power, profileId)
end)
RequestEnergyTest.OnServerEvent:Connect(function(player, patternId)
    local session = sessions[player]
    if not session or session.deployment ~= "ACTIVE" or session.machineState ~= "OPERATIONAL" or not session.controller then return end
    if os.clock() - (session.lastEnergyTestRequest or -100) < 0.1 then return end
    session.lastEnergyTestRequest = os.clock()
    EnergySystems.RequestTest(session.power, patternId, session.controller.state.yaw, Locomotion.Position(session.controller))
end)

WeaponIntent.OnServerEvent:Connect(function(player, index, held, aim, reload)
    local session = sessions[player]
    if session then Weapons.Intent(session,index,held,aim,reload) end
end)

-- One loop drives every deployed mech. dt is clamped inside MechDrive, so a hitch cannot launch anything.
local driveStats = { stepMs = 0, active = 0 }
RunService.Heartbeat:Connect(function(dt)
    local started = os.clock()
    local active = 0
    for player, session in pairs(sessions) do
        local c = session.controller
        if session.power and (not c or session.machineState ~= "OPERATIONAL" or (session.deployment == "DOCKING" and session.recallAt)) then
            EnergySystems.Step(session.power, math.min(dt, 0.25), nil, 0, 0, false, false)
        end
        if c and session.machineState == "OPERATIONAL" then
            active += 1
            SortieReport.Tick(session, dt)
            local state = session.deployment
            if state == "DEPLOYING" and session.deployAt and os.clock() >= session.deployAt then
                if Deployment.Transition(session, "ACTIVE") then
                    Locomotion.SetLocked(c, false)
                    setDeploymentAttributes(session)
                    notify(player, "Reactor online. Drive enabled")
                end
            end
            if state == "DOCKING" and session.recallAt then
                if os.clock() >= session.recallAt then
                    Locomotion.Teleport(c, session.bayPosition, 0)
                    session.recallAt = nil
                    finishDock(player, session)
                end
            else
                local events, arrived = Locomotion.Step(c, dt)
                if events.fellOut then
                    warn("[IF-DEPLOY] mech left the world; recalling")
                    Locomotion.Teleport(c, session.bayPosition, 0)
                end
                if state == "DOCKING" and (arrived or (session.dockUntil and os.clock() > session.dockUntil)) then
                    Locomotion.Teleport(c, session.bayPosition, 0)
                    finishDock(player, session)
                end
            end
        end
    end
    -- Weapon bursts spend only after all propulsion/shield substeps have settled. No second budget.
    for _, session in pairs(sessions) do Weapons.Step(session,WeaponEffects) end
    AvionicsService.Step(os.clock()) -- M11C: radar scan, lock, thermal visibility, avionics energy demand, one packet to the owner
    CombatTargets.Step(os.clock())
    Destructibles.Step(os.clock(), dt)
    TankCombat.Step(os.clock(), dt)
    RangeControl.Step()
    driveStats.active = active
    if active > 0 then
        driveStats.stepMs += ((os.clock() - started) * 1000 - driveStats.stepMs) * 0.05
        ReplicatedStorage:SetAttribute("IronframeDriveStepMs", driveStats.stepMs)
    end
end)

local function playerAdded(player)
    bayCounter += 1
    local position, bay = WorldBuilder.BuildBay(bayCounter)
    RangeControl.Attach(player, bay)
    sessions[player] = {
        player = player,
        bayPosition = position,
        bay = bay,
        deployment = "STOWED",
        lastDeploy = -1000,
        lastDriveInput = -1000,
        presetId = "BALANCED",
        lastChange = -1000,
        lastEject = -1000,
        machineState = "INIT",
        pilotSafe = true,
    }
    -- Park the (client-hidden) avatar at the operator station, away from the mech. Never harmed/removed.
    local function park(character)
        task.defer(function()
            if sessions[player] == nil or not character.Parent then return end
            character:PivotTo(CFrame.new(position + Vector3.new(0, 4, 26)))
        end)
    end
    player.CharacterAdded:Connect(park)
    if player.Character then park(player.Character) end
    assemble(player)
    print(string.format("[IF-STEP-05] Garage ready for userId %d; bay=%d", player.UserId, bayCounter))
end

Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(function(player)
    local session = sessions[player]
    if session then
        resetDeployment(session)
        if session.mech then session.mech:Destroy() end
        RangeControl.Detach(session.bay)
    end
    sessions[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
    playerAdded(player)
end
