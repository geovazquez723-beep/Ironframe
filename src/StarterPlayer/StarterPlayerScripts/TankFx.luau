-- Client presentation of enemy tank fire (M10B). Cosmetic only: every position here comes from the server's `fire` / `end` events
-- or from replicated attributes; nothing the client computes can hit anything.
--
--   * Telegraph   a tank in AIM (replicated AiState / AiAimAt / AiWarn) grows a glowing charge at its muzzle, and for the last
--                 part of the warning projects a thin red targeting beam along the barrel. Turret slewing is the first cue.
--   * Shell       a pooled neon tracer with a ribbon trail, light and smoke, flown as origin + velocity * serverTime (one
--                 CFrame per frame, no physics, no per-shell instances created after warm-up)
--   * Impact      a pooled burst (flash, sparks, smoke, shock ring) coloured by what happened: shield perfect / guard / bypass / world
--
-- Budgets (all pooled): 8 shells, 6 impact bursts, 3 tank telegraphs, 4 sound emitters.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local DestructionConfig = require(Shared:WaitForChild("DestructionConfig"))
local WeaponPresentation = require(Shared:WaitForChild("WeaponPresentation"))

local TankFx = {}

local MAX_SHELLS, MAX_BURSTS = 8, 6
local AMBER = Color3.fromRGB(255, 176, 66)
local HOT = Color3.fromRGB(255, 232, 170)
local RED = Color3.fromRGB(255, 58, 44)
local GOLD = Color3.fromRGB(255, 214, 120)
local CYAN = Color3.fromRGB(70, 200, 255)

local function newPart(parent: Instance, name: string, size: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
    local p = Instance.new("Part")
    p.Name, p.Size, p.Color = name, size, color
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
    p.Material = material or Enum.Material.Neon
    if shape then
        p.Shape = shape
    end
    p.Transparency = 1
    p.Parent = parent
    return p
end

local function emitter(parent: Instance, texture: string, color: ColorSequence, size: NumberSequence, life: NumberRange, speed: NumberRange, spread: number, emission: number): ParticleEmitter
    local e = Instance.new("ParticleEmitter")
    e.Texture, e.Color, e.Size = texture, color, size
    e.Lifetime, e.Speed, e.SpreadAngle = life, speed, Vector2.new(spread, spread)
    e.LightEmission, e.Rate, e.Enabled = emission, 0, false
    e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
    e.Parent = parent
    return e
end

function TankFx.Start(remotes, hud)
    local player = Players.LocalPlayer
    local root = Instance.new("Folder")
    root.Name = "IronframeCombatFx"
    root.Parent = workspace

    -- Shell pool ----------------------------------------------------------------------------------------------------------------
    local shellFree: { any } = {}
    local shells: { [number]: any } = {}
    local function buildShell()
        local core = newPart(root, "ShellCore", Vector3.new(0.9, 0.9, 3), HOT)
        local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
        a0.Name, a1.Name = "TrailTop", "TrailBottom"
        a0.Parent, a1.Parent = core, core
        local trail = Instance.new("Trail")
        trail.Attachment0, trail.Attachment1 = a0, a1
        trail.Lifetime, trail.MinLength, trail.FaceCamera, trail.LightEmission = 0.5, 0.05, true, 0.9
        trail.Color = ColorSequence.new(HOT, Color3.fromRGB(170, 60, 18))
        trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
        trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.15) })
        trail.Enabled = false
        trail.Parent = core
        local smoke = emitter(core, "rbxasset://textures/particles/smoke_main.dds", ColorSequence.new(Color3.fromRGB(90, 86, 82), Color3.fromRGB(40, 40, 42)),
            NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 3.2) }), NumberRange.new(0.5, 0.9), NumberRange.new(0, 1), 20, 0)
        smoke.Rate = 40
        local light = Instance.new("PointLight")
        light.Color, light.Range, light.Brightness, light.Shadows, light.Enabled = AMBER, 14, 2.2, false, false
        light.Parent = core
        return { core = core, a0 = a0, a1 = a1, trail = trail, smoke = smoke, light = light, busy = false }
    end
    for _ = 1, MAX_SHELLS do
        table.insert(shellFree, buildShell())
    end
    local function releaseShell(rig)
        rig.busy = false
        rig.trail.Enabled = false
        rig.smoke.Enabled = false
        rig.light.Enabled = false
        rig.core.Transparency = 1
        table.insert(shellFree, rig)
    end

    -- Impact bursts --------------------------------------------------------------------------------------------------------------
    local burstFree: { any } = {}
    local bursts: { any } = {}
    local function buildBurst()
        local host = newPart(root, "ImpactBurst", Vector3.one * 0.2, HOT, Enum.Material.Neon, Enum.PartType.Ball)
        local sparks = emitter(host, "rbxasset://textures/particles/sparkles_main.dds", ColorSequence.new(HOT, AMBER),
            NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }), NumberRange.new(0.3, 0.8), NumberRange.new(20, 52), 180, 1)
        local smoke = emitter(host, "rbxasset://textures/particles/smoke_main.dds", ColorSequence.new(Color3.fromRGB(86, 84, 82), Color3.fromRGB(36, 36, 38)),
            NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 8) }), NumberRange.new(0.9, 1.6), NumberRange.new(2, 8), 180, 0)
        local light = Instance.new("PointLight")
        light.Range, light.Brightness, light.Shadows, light.Enabled = 26, 0, false, true
        light.Parent = host
        local ring = newPart(root, "ImpactRing", Vector3.new(0.15, 1, 1), HOT, Enum.Material.Neon, Enum.PartType.Cylinder)
        return { host = host, sparks = sparks, smoke = smoke, light = light, ring = ring, age = 0, life = 0.5 }
    end
    for _ = 1, MAX_BURSTS do
        table.insert(burstFree, buildBurst())
    end

    -- Sound (3D one-shots on throw-away emitters; at most ~4 live) -------------------------------------------------------------
    local lastSound = -1
    local function play(id: string, position: Vector3, volume: number, speed: number)
        if id == "" or os.clock() - lastSound < 0.04 then
            return
        end
        lastSound = os.clock()
        local holder = newPart(root, "TankSound", Vector3.one * 0.1, HOT)
        holder.CFrame = CFrame.new(position)
        local s = Instance.new("Sound")
        s.SoundId, s.Volume, s.PlaybackSpeed = id, volume, speed
        s.RollOffMode, s.RollOffMinDistance, s.RollOffMaxDistance = Enum.RollOffMode.InverseTapered, 20, 420
        s.Parent = holder
        s:Play()
        Debris:AddItem(holder, 3)
    end

    local function burst(position: Vector3, normal: Vector3, color: Color3, power: number, ringColor: Color3?)
        local rig = table.remove(burstFree)
        if not rig then
            rig = table.remove(bursts, 1) -- recycle the oldest
        end
        rig.age, rig.life = 0, 0.55
        rig.host.CFrame = CFrame.lookAt(position, position + normal)
        rig.host.Color, rig.host.Size = color, Vector3.one * (0.6 + power * 0.4)
        rig.host.Transparency = 0.1
        rig.sparks.Color = ColorSequence.new(HOT, color)
        rig.sparks:Emit(math.floor(10 + 14 * power))
        rig.smoke:Emit(math.floor(3 + 4 * power))
        rig.light.Color, rig.light.Brightness = color, 3 + 4 * power
        rig.ring.Color = ringColor or color
        rig.ring.CFrame = CFrame.lookAt(position, position + normal) * CFrame.Angles(0, math.pi / 2, 0)
        rig.ring.Size = Vector3.new(0.15, 1, 1)
        rig.ring.Transparency = 0.2
        rig.power = power
        table.insert(bursts, rig)
    end

    -- Events from the server -------------------------------------------------------------------------------------------------
    local function mechCFrame(): CFrame?
        local folder = workspace:FindFirstChild("IronframeMechs")
        local model = folder and folder:FindFirstChild(tostring(player.UserId))
        local chassis = model and model:FindFirstChild("Chassis")
        return chassis and chassis.CFrame
    end

    local function onFire(e)
        local rig = table.remove(shellFree)
        if not rig then
            return
        end
        local scale = if e.heavy then 1.8 else 1
        rig.busy = true
        rig.core.Size = Vector3.new(0.9 * scale, 0.9 * scale, 3.2 * scale)
        rig.a0.Position, rig.a1.Position = Vector3.new(0, 0.45 * scale, 0), Vector3.new(0, -0.45 * scale, 0)
        rig.core.Color = if e.heavy then Color3.fromRGB(255, 120, 60) else HOT
        rig.core.Transparency = 0
        rig.trail.Lifetime = if e.heavy then 0.8 else 0.5
        rig.trail.Enabled, rig.smoke.Enabled, rig.light.Enabled = true, true, true
        rig.light.Range = if e.heavy then 24 else 14
        shells[e.id] = { rig = rig, o = e.o, v = e.v, t = e.t, life = e.l, tank = e.tank, arch = e.arch, heavy = e.heavy, ended = false, radius = e.r }
        -- Muzzle discharge: flash, blast smoke along the barrel, report.
        burst(e.o + e.v.Unit * 2, e.v.Unit, HOT, if e.heavy then 1.4 else 0.8, nil)
        play(WeaponPresentation.audio.maulerAssetId, e.o, if e.heavy then 1.0 else 0.8, if e.heavy then 0.55 else 0.75)
        hud.OnFire(e)
    end

    local function onEnd(e)
        local shell = shells[e.id]
        if shell then
            shell.ended = true
            shell.endAt = os.clock()
            shell.rig.core.CFrame = CFrame.lookAt(e.p, e.p + shell.v.Unit)
            shell.rig.core.Transparency = 1
            shell.rig.smoke.Enabled, shell.rig.light.Enabled = false, false
        end
        local power = if e.heavy then 1.6 else 1
        if e.why == "WORLD" then
            burst(e.p, e.n or Vector3.yAxis, AMBER, power, nil)
        elseif e.why == "MECH" then
            local timing = e.timing
            if timing == "PERFECT" then
                burst(e.p, e.n, GOLD, power * 1.1, CYAN)
                play(DestructionConfig.audio.zap.id, e.p, 0.9, 1.2)
            elseif timing == "GUARD" then
                burst(e.p, e.n, CYAN, power, nil)
                play(DestructionConfig.audio.zap.id, e.p, 0.8, 0.9)
            else
                burst(e.p, e.n, RED, power * 1.25, AMBER)
                play(DestructionConfig.audio.metalHit.id, e.p, 1, 0.7)
            end
        elseif e.why == "EXPIRE" then
            burst(e.p, Vector3.yAxis, Color3.fromRGB(150, 150, 150), 0.3, nil)
        end
        hud.OnEnd(e)
    end

    remotes:WaitForChild("CombatFx").OnClientEvent:Connect(function(events)
        for _, e in ipairs(events) do
            if e.k == "fire" then
                onFire(e)
            elseif e.k == "end" then
                onEnd(e)
            end
        end
    end)

    -- Telegraph rigs, one per armed tank -----------------------------------------------------------------------------------------
    local tankRigs: { [Model]: any } = {}
    local tanks: { Model } = {}
    local lastScan = -10
    local function findTanks()
        table.clear(tanks)
        local hangar = workspace:FindFirstChild("IronframeHangar")
        if not hangar then
            return
        end
        for _, bay in ipairs(hangar:GetChildren()) do
            local ground = bay:FindFirstChild("ProvingGround")
            local d = ground and ground:FindFirstChild("TestingDistrict")
            if d and d:GetAttribute("OwnerUserId") == player.UserId then
                for _, child in ipairs(d:GetChildren()) do
                    if child:IsA("Model") and child:GetAttribute("AiType") then
                        table.insert(tanks, child)
                    end
                end
            end
        end
    end
    local function rigFor(model: Model)
        local rig = tankRigs[model]
        if rig then
            return rig
        end
        local charge = newPart(root, "MuzzleCharge", Vector3.one, HOT, Enum.Material.Neon, Enum.PartType.Ball)
        local light = Instance.new("PointLight")
        light.Range, light.Brightness, light.Shadows, light.Color = 20, 0, false, AMBER
        light.Parent = charge
        local beam = newPart(root, "TargetingBeam", Vector3.new(0.22, 0.22, 10), RED)
        rig = { charge = charge, light = light, beam = beam, pinged = false }
        tankRigs[model] = rig
        return rig
    end

    local perf = { ms = 0, worst = 0, frames = 0 }
    RunService.RenderStepped:Connect(function(dt)
        local now = os.clock()
        local serverNow = workspace:GetServerTimeNow()
        -- Shells
        for id, shell in pairs(shells) do
            local rig = shell.rig
            if shell.ended then
                if now - shell.endAt > 0.9 then
                    shells[id] = nil
                    releaseShell(rig)
                end
            else
                local age = serverNow - shell.t
                if age > shell.life + 0.5 then
                    shells[id] = nil
                    releaseShell(rig)
                else
                    local pos = shell.o + shell.v * math.max(age, 0)
                    rig.core.CFrame = CFrame.lookAt(pos, pos + shell.v)
                    shell.pos = pos
                end
            end
        end
        -- Bursts
        for i = #bursts, 1, -1 do
            local rig = bursts[i]
            rig.age += dt
            local f = rig.age / rig.life
            if f >= 1 then
                rig.host.Transparency, rig.ring.Transparency, rig.light.Brightness = 1, 1, 0
                table.remove(bursts, i)
                table.insert(burstFree, rig)
            else
                rig.host.Transparency = 0.1 + 0.9 * f
                rig.light.Brightness = (3 + 4 * (rig.power or 1)) * (1 - f) ^ 2
                local radius = (2 + 9 * (rig.power or 1)) * (1 - (1 - f) ^ 2)
                rig.ring.Size = Vector3.new(0.15, radius * 2, radius * 2)
                rig.ring.Transparency = 0.2 + 0.8 * f
            end
        end
        -- Telegraphs
        if now - lastScan > 0.75 then
            lastScan = now
            findTanks()
        end
        local mine = mechCFrame()
        for _, model in ipairs(tanks) do
            if not model.Parent then
                continue
            end
            local rig = tankRigs[model]
            local state = model:GetAttribute("AiState")
            local turret = model:FindFirstChild("TurretRoot")
            local muzzleLocal = turret and turret:GetAttribute("MuzzleLocal")
            if state == "AIM" and turret and muzzleLocal then
                rig = rig or rigFor(model)
                local warn = model:GetAttribute("AiWarn") or 1
                local f = math.clamp((serverNow - (model:GetAttribute("AiAimAt") or serverNow)) / warn, 0, 1)
                local muzzle = (turret :: BasePart).CFrame * muzzleLocal
                local heavy = model:GetAttribute("AiType") == "HEAVY"
                local size = (0.4 + 1.5 * f ^ 1.5) * (if heavy then 1.45 else 1)
                rig.charge.Size = Vector3.one * size
                rig.charge.CFrame = muzzle
                rig.charge.Color = AMBER:Lerp(HOT, f)
                rig.charge.Transparency = 0.4 - 0.3 * f
                rig.light.Brightness = 1 + 4 * f
                rig.light.Color = AMBER:Lerp(HOT, f)
                -- Targeting beam: the last 45 % of the warning, along the barrel, flickering faster as the shot nears.
                if f > 0.55 and mine then
                    local distance = math.clamp((mine.Position - muzzle.Position).Magnitude, 20, 300)
                    rig.beam.Size = Vector3.new(0.2 + 0.1 * f, 0.2 + 0.1 * f, distance)
                    rig.beam.CFrame = muzzle * CFrame.new(0, 0, -distance / 2)
                    rig.beam.Transparency = 0.35 + 0.35 * math.sin(now * (14 + 40 * f)) ^ 2
                else
                    rig.beam.Transparency = 1
                end
            elseif rig then
                if state == "FIRE" and turret and muzzleLocal then
                    rig.charge.CFrame = (turret :: BasePart).CFrame * muzzleLocal
                    rig.charge.Transparency = math.min(1, rig.charge.Transparency + dt * 6)
                else
                    rig.charge.Transparency = 1
                end
                rig.beam.Transparency = 1
                rig.light.Brightness = math.max(0, rig.light.Brightness - dt * 30)
            end
        end
        for model, rig in pairs(tankRigs) do
            if not model.Parent then
                rig.charge:Destroy()
                rig.beam:Destroy()
                tankRigs[model] = nil
            end
        end
        local spent = (os.clock() - now) * 1000
        perf.ms += (spent - perf.ms) * 0.05
        perf.worst = math.max(perf.worst, spent)
        perf.frames += 1
    end)

    local api = {}
    -- Shells still in flight (for the HUD): { id, pos, v, t, tank, arch, heavy }
    function api.Active()
        local list = {}
        for id, shell in pairs(shells) do
            if not shell.ended and shell.pos then
                table.insert(list, { id = id, pos = shell.pos, v = shell.v, tank = shell.tank, arch = shell.arch, heavy = shell.heavy, r = shell.radius })
            end
        end
        return list
    end
    function api.Stats()
        local free, busy = #shellFree, 0
        for _ in pairs(shells) do
            busy += 1
        end
        return { shellsFree = free, shellsBusy = busy, burstsFree = #burstFree, bursts = #bursts, descendants = #root:GetDescendants(), ms = perf.ms, worstMs = perf.worst, frames = perf.frames }
    end
    return api
end

return TankFx
