local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Loadouts = require(Shared:WaitForChild("Loadouts"))
local Compiler = require(Shared:WaitForChild("LoadoutCompiler"))
local Factory = require(script.Parent.MechFactory)
local WorldBuilder = require(script.Parent.WorldBuilder)

local sessions = {}
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
        message = message or "System nominal",
    }
end

local function assemble(player)
    local session = sessions[player]
    if not session then return end
    if session.mech then
        session.mech:Destroy()
    end
    local model = Factory.Create(player.UserId, Loadouts.presets[session.presetId], session.bayPosition)
    model.Parent = workspace.IronframeMechs
    session.mech = model
    session.machineState = "OPERATIONAL"
    StateChanged:FireClient(player, publicState(player, "Loadout installed"))
    print(string.format("[IF-STEP-03] Assembled %s for userId %d", session.presetId, player.UserId))
end

WorldBuilder.Initialize()
validatePresets()

GetGarageState.OnServerInvoke = function(player)
    return publicState(player)
end

SetPreset.OnServerEvent:Connect(function(player, presetId)
    local session = sessions[player]
    if not session or session.machineState ~= "OPERATIONAL" then return end
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

    -- SAFETY INVARIANT: The pilot is confirmed evacuated BEFORE any mech effects run.
    -- Pilot HP does not exist; the capsule cannot be targeted or harmed.
    session.pilotSafe = true
    session.machineState = "PILOT_EVACUATED"
    session.mech:SetAttribute("State", "PILOT_EVACUATED")
    StateChanged:FireClient(player, publicState(player, "PILOT SAFE — EMERGENCY EJECTION"))

    local pod = Instance.new("Part")
    pod.Name = "InvulnerableEscapeCapsule"
    pod.Shape = Enum.PartType.Ball
    pod.Size = Vector3.new(2.1, 3.0, 2.1)
    pod.Color = Color3.fromRGB(255, 179, 65)
    pod.Material = Enum.Material.Metal
    pod.Anchored = true
    pod.CanCollide = false
    pod.Position = session.bayPosition + Vector3.new(0, 15.5, 0)
    pod.Parent = workspace
    local tween = TweenService:Create(pod, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = pod.Position + Vector3.new(0, 27, -6)
    })
    tween:Play()
    print(string.format("[IF-STEP-04] Guaranteed safe ejection for userId %d", player.UserId))

    task.delay(1.0, function()
        if sessions[player] ~= session then
            pod:Destroy()
            return
        end
        session.machineState = "MECH_DISABLED"
        if session.mech then
            session.mech:Destroy()
            session.mech = nil
        end
        StateChanged:FireClient(player, publicState(player, "Mech disabled. Pilot safe. Rebuilding..."))
    end)
    task.delay(4.0, function()
        pod:Destroy()
        if sessions[player] ~= session then return end
        session.pilotSafe = true
        assemble(player)
    end)
end)

local function playerAdded(player)
    bayCounter += 1
    local position = WorldBuilder.BuildBay(bayCounter)
    sessions[player] = {
        bayPosition = position,
        presetId = "BALANCED",
        lastChange = -1000,
        lastEject = -1000,
        machineState = "INIT",
        pilotSafe = true,
    }
    assemble(player)
    print(string.format("[IF-STEP-05] Garage ready for userId %d; bay=%d", player.UserId, bayCounter))
end

Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(function(player)
    local session = sessions[player]
    if session and session.mech then session.mech:Destroy() end
    sessions[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
    playerAdded(player)
end
