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

local WeaponIntent = remote("RemoteEvent", "WeaponIntent")
local WeaponEffects = remote("RemoteEvent", "WeaponEffects")

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

local function publicState(player, message)
    local session = sessions[player]
    if not session then
        return { ready = false, message = "Garage is initializing" }
    end
    local loadout = Loadouts.presets[session.presetId]
    return {
        ready = true,
        presetId = session.presetId,
        presetName = loadout.name,
        presetOrder = Loadouts.order,
        presetNames = {
            BALANCED = Loadouts.presets.BALANCED.name,
            ENERGY = Loadouts.presets.ENERGY.name,
            MISSILE = Loadouts.presets.MISSILE.name,
        },
        compiled = Compiler.Compile(loadout),
        machineState = session.machineState,
        pilotSafe = session.pilotSafe,
        deployment = session.deployment or "STOWED",
        reactor = Deployment.ReactorFor(session.deployment),
        canDeploy = (Deployment.ValidateDeploy(session, Compiler.Compile(loadout))),
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

local function assemble(player)
    local session = sessions[player]
    if not session then return end
    resetDeployment(session)
    if session.mech then
        session.mech:Destroy()
    end
    local model = Factory.Create(player.UserId, session.presetId, Loadouts.presets[session.presetId], session.bayPosition)
    model.Parent = workspace.IronframeMechs
    session.mech = model
    session.loadout = Loadouts.presets[session.presetId]
    session.machineState = "OPERATIONAL"
    session.power = EnergySystems.Create(model, Compiler.Compile(session.loadout).energy)
    Weapons.Create(session)
    EnergySystems.Publish(session.power, true)
    setDeploymentAttributes(session)
    StateChanged:FireClient(player, publicState(player, "Loadout installed"))
    print(string.format("[IF-STEP-03] Assembled %s for userId %d", session.presetId, player.UserId))
end

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
    assemble(player)
end)

RequestTestEject.OnServerEvent:Connect(function(player)
    local session = sessions[player]
    if not session or session.machineState ~= "OPERATIONAL" or not session.mech then return end
    if os.clock() - session.lastEject < 8 then return end
    session.lastEject = os.clock()

    local pod
    -- SAFETY INVARIANT (enforced inside Ejection.Run): pilotSafe is set before any hook below runs.
    Ejection.Run(session, {
        onPilotSafe = function()
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
    })
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
    local compiled = Compiler.Compile(Loadouts.presets[session.presetId])
    local ok, reason = Deployment.ValidateDeploy(session, compiled)
    if not ok then
        notify(player, "DEPLOY REFUSED: " .. tostring(reason))
        print(string.format("[IF-DEPLOY] refused for userId %d: %s", player.UserId, tostring(reason)))
        return
    end
    Deployment.Transition(session, "DEPLOYING")
    session.controller = Locomotion.Create(session.mech, session.mech:GetAttribute("ChassisId"), session.bayPosition, 0)
    session.controller.energySystems = session.power
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
    CombatTargets.Step(os.clock())
    driveStats.active = active
    if active > 0 then
        driveStats.stepMs += ((os.clock() - started) * 1000 - driveStats.stepMs) * 0.05
        ReplicatedStorage:SetAttribute("IronframeDriveStepMs", driveStats.stepMs)
    end
end)

local function playerAdded(player)
    bayCounter += 1
    local position, bay = WorldBuilder.BuildBay(bayCounter)
    sessions[player] = {
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
    end
    sessions[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
    playerAdded(player)
end
