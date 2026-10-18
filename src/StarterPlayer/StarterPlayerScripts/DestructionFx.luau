-- Client-side destruction presentation (M10A). Purely cosmetic: it consumes the server's batched DestructionFx packets and never
-- decides anything. Every resource is pooled and bounded, so sustained MG-9 fire and repeated collapses cost the same:
--
--   emitter slots   N anchored invisible parts, each with dust / sparks / chips / smoke / flash / fire / shockwave emitters + a light
--   fragments       M pooled parts moved by one BulkMoveTo per frame with a tiny ballistic integrator (no physics solver)
--   scorch marks    K pooled discs that cool from ember-orange to black and fade
--   sound voices    V pooled 3D sounds (silent when a sound has no uploaded asset id)
--
-- Nothing is created per event after Start(); when a pool is exhausted the oldest entry is recycled.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.IronframeShared.DestructionConfig)
local Profile = require(ReplicatedStorage.IronframeShared.ImpactProfile)

local Fx = {}

local V3, CF = Vector3.new, CFrame.new
local client = Config.client
local rng = Random.new()
local GRAVITY = 120
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SQUARE = "rbxasset://textures/particles/SquareParticle.png"
local TEX_SHOCK = "rbxasset://textures/particles/explosion01_shockwave_main.dds"

local function rgb(t): Color3
    return Color3.fromRGB(t[1], t[2], t[3])
end

local function seq(a: number, b: number): NumberSequence
    return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

local function newEmitter(att: Attachment, name: string, texture: string, props)
    local e = Instance.new("ParticleEmitter")
    e.Name, e.Texture, e.Rate, e.Enabled = name, texture, 0, true
    e.EmissionDirection = Enum.NormalId.Front
    for k, v in pairs(props) do
        (e :: any)[k] = v
    end
    e.Parent = att
    return e
end

function Fx.Start(remotes, hud)
    local player = Players.LocalPlayer
    local root = Instance.new("Folder")
    root.Name = "IronframeDestructionFx"
    root.Parent = workspace

    local stats = { events = 0, hits = 0, destroyed = 0, bursts = 0, fragmentsSpawned = 0, fragmentsRecycled = 0, scorchSpawned = 0, soundsPlayed = 0, stepMs = 0, worstMs = 0, dropped = 0 }

    -- Emitter slots ------------------------------------------------------------------------------------------------------------
    local slots, nextSlot = {}, 1
    for i = 1, client.emitterSlots do
        local p = Instance.new("Part")
        p.Name = "Slot" .. i
        p.Size, p.Transparency, p.Anchored = V3(0.2, 0.2, 0.2), 1, true
        p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
        p.Parent = root
        local att = Instance.new("Attachment")
        att.Parent = p
        local slot = { part = p, light = Instance.new("PointLight"), lightRate = 0 }
        slot.light.Brightness, slot.light.Range, slot.light.Shadows, slot.light.Parent = 0, 18, false, p
        slot.dust = newEmitter(att, "Dust", TEX_SMOKE, { Lifetime = NumberRange.new(1.0, 2.0), Speed = NumberRange.new(3, 10), SpreadAngle = Vector2.new(75, 75), Drag = 2.5, Acceleration = V3(0, 1.5, 0), RotSpeed = NumberRange.new(-40, 40), Rotation = NumberRange.new(0, 360), LightInfluence = 1 })
        slot.sparks = newEmitter(att, "Sparks", TEX_SPARK, { Lifetime = NumberRange.new(0.2, 0.55), Speed = NumberRange.new(12, 36), SpreadAngle = Vector2.new(70, 70), Acceleration = V3(0, -90, 0), LightEmission = 1, Size = seq(0.34, 0) })
        slot.chips = newEmitter(att, "Chips", TEX_SQUARE, { Lifetime = NumberRange.new(0.6, 1.2), Speed = NumberRange.new(10, 30), SpreadAngle = Vector2.new(65, 65), Acceleration = V3(0, -GRAVITY, 0), Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-500, 500), Size = seq(0.5, 0.25), LightInfluence = 1 })
        slot.smoke = newEmitter(att, "Smoke", TEX_SMOKE, { Lifetime = NumberRange.new(1.6, 3.2), Speed = NumberRange.new(1, 5), SpreadAngle = Vector2.new(40, 40), Drag = 1.5, Acceleration = V3(0.8, 3.5, 0), RotSpeed = NumberRange.new(-25, 25), Rotation = NumberRange.new(0, 360), LightInfluence = 1 })
        slot.flash = newEmitter(att, "Flash", TEX_SPARK, { Lifetime = NumberRange.new(0.08, 0.14), Speed = NumberRange.new(0, 0), SpreadAngle = Vector2.new(0, 0), LightEmission = 1, Size = seq(3, 8), Transparency = seq(0.05, 1) })
        slot.fire = newEmitter(att, "Fire", TEX_FIRE, { Lifetime = NumberRange.new(0.45, 0.95), Speed = NumberRange.new(5, 20), SpreadAngle = Vector2.new(60, 60), LightEmission = 0.9, Color = ColorSequence.new(Color3.fromRGB(255, 200, 100), Color3.fromRGB(230, 70, 20)), Size = seq(4, 0.4), Transparency = seq(0.05, 1), Acceleration = V3(0, 8, 0) })
        slot.shock = newEmitter(att, "Shock", TEX_SHOCK, { Lifetime = NumberRange.new(0.26, 0.34), Speed = NumberRange.new(0, 0), SpreadAngle = Vector2.new(0, 0), LightEmission = 0.5, Size = seq(2, 16), Transparency = seq(0.35, 1), Orientation = Enum.ParticleOrientation.FacingCamera })
        slot.baseLife = {}
        for key, value in pairs(slot) do
            if typeof(value) == "Instance" and value:IsA("ParticleEmitter") then
                slot.baseLife[key] = value.Lifetime
            end
        end
        slots[i] = slot
    end
    local function takeSlot(pos: Vector3, normal: Vector3)
        local slot = slots[nextSlot]
        nextSlot = nextSlot % #slots + 1
        slot.part.CFrame = CFrame.lookAt(pos, pos + normal)
        return slot
    end

    -- Sound voices -------------------------------------------------------------------------------------------------------------
    local voices = {}
    for i = 1, client.soundVoices do
        local p = Instance.new("Part")
        p.Name = "Voice" .. i
        p.Size, p.Transparency, p.Anchored = V3(0.2, 0.2, 0.2), 1, true
        p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
        p.Parent = root
        local s = Instance.new("Sound")
        s.RollOffMode, s.RollOffMinDistance, s.RollOffMaxDistance = Enum.RollOffMode.InverseTapered, 30, 420
        s.Parent = p
        voices[i] = { part = p, sound = s, startedAt = -100 }
    end
    local lastSoundAt = {}
    local function play(name: string, pos: Vector3, volumeScale: number?, pitch: number?)
        local def = Config.audio[name]
        if not def or def.id == "" then
            return
        end
        local clock = os.clock()
        if clock - (lastSoundAt[name] or -1) < 0.06 then
            return
        end
        lastSoundAt[name] = clock
        local chosen
        for _, v in ipairs(voices) do
            if not v.sound.IsPlaying then
                chosen = v
                break
            end
            if not chosen or v.startedAt < chosen.startedAt then
                chosen = v
            end
        end
        chosen.startedAt = clock
        chosen.part.Position = pos
        local s = chosen.sound
        s.SoundId = def.id
        s.Volume = def.volume * (volumeScale or 1)
        s.PlaybackSpeed = (pitch or 1) * rng:NextNumber(0.93, 1.07)
        s.TimePosition = 0
        s:Play()
        stats.soundsPlayed += 1
    end

    -- Scorch marks -------------------------------------------------------------------------------------------------------------
    local scorch, scorchNext = {}, 1
    for i = 1, client.maxScorch do
        local p = Instance.new("Part")
        p.Name = "Scorch" .. i
        p.Shape, p.Size, p.Anchored = Enum.PartType.Cylinder, V3(0.06, 1, 1), true
        p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
        p.Material, p.Color, p.Transparency = Enum.Material.Neon, Color3.fromRGB(255, 120, 40), 1
        p.Parent = root
        scorch[i] = { part = p, born = -100, life = client.scorchLife }
    end
    local function mark(pos: Vector3, normal: Vector3, diameter: number)
        local s = scorch[scorchNext]
        scorchNext = scorchNext % #scorch + 1
        s.born = os.clock()
        s.part.Size = V3(0.06, diameter, diameter)
        s.part.CFrame = CFrame.lookAt(pos + normal * 0.06, pos + normal) * CFrame.Angles(0, math.pi / 2, 0)
        s.part.Color = Color3.fromRGB(255, 140, 50)
        s.part.Transparency = 0.1
        stats.scorchSpawned += 1
    end

    -- Fragments ----------------------------------------------------------------------------------------------------------------
    local pool, active = {}, {}
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.IgnoreWater = true
    local function refreshFilter()
        local filter = { root }
        local mechs = workspace:FindFirstChild("IronframeMechs")
        if mechs then
            table.insert(filter, mechs)
        end
        if player.Character then
            table.insert(filter, player.Character)
        end
        local weaponFx = workspace:FindFirstChild("IronframeWeaponEffects")
        if weaponFx then
            table.insert(filter, weaponFx)
        end
        local cockpit = workspace:FindFirstChild("IronframeCockpitClient")
        if cockpit then
            table.insert(filter, cockpit)
        end
        rayParams.FilterDescendantsInstances = filter
    end
    refreshFilter()
    for i = 1, client.maxFragments do
        local p = Instance.new("Part")
        p.Name = "Fragment" .. i
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.Transparency = 1
        p.Size = V3(1, 1, 1)
        p.Parent = root
        pool[i] = { part = p, busy = false }
    end
    local function takeFragment()
        for _, f in ipairs(pool) do
            if not f.busy then
                return f
            end
        end
        -- Exhausted: recycle the oldest active fragment.
        local oldest, index = nil, 0
        for i, f in ipairs(active) do
            if not oldest or f.born < oldest.born then
                oldest, index = f, i
            end
        end
        if oldest then
            table.remove(active, index)
            stats.fragmentsRecycled += 1
            return oldest
        end
        return nil
    end
    local function spawnFragment(pos: Vector3, velocity: Vector3, size: Vector3, color: Color3, material: Enum.Material, spin: number, life: number?)
        local f = takeFragment()
        if not f then
            return
        end
        f.busy = true
        f.born = os.clock()
        f.life = life or client.fragmentLife
        f.pos, f.vel = pos, velocity
        f.rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28))
        f.av = V3(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * spin
        f.radius = math.max(size.X, size.Y, size.Z) * 0.35
        f.settled = false
        local p = f.part
        p.Size = size
        p.Color = color
        p.Material = material
        p.Transparency = 0
        p.CastShadow = size.Magnitude > 2
        p.CFrame = CF(pos) * f.rot
        table.insert(active, f)
        stats.fragmentsSpawned += 1
    end
    local function releaseFragment(f)
        f.busy = false
        f.part.Transparency = 1
    end
    local moveParts, moveCFrames = {}, {}
    local function stepFragments(dt: number)
        local now = os.clock()
        local count = 0
        table.clear(moveParts)
        table.clear(moveCFrames)
        for i = #active, 1, -1 do
            local f = active[i]
            local age = now - f.born
            if age > f.life + client.fragmentFade then
                releaseFragment(f)
                table.remove(active, i)
                continue
            end
            if age > f.life then
                f.part.Transparency = math.clamp((age - f.life) / client.fragmentFade, 0, 1)
            end
            if not f.settled then
                f.vel += V3(0, -GRAVITY, 0) * dt
                local step = f.vel * dt
                local hit = workspace:Raycast(f.pos, step + step.Unit * f.radius, rayParams)
                if hit then
                    f.pos = hit.Position + hit.Normal * f.radius
                    local along = f.vel:Dot(hit.Normal)
                    f.vel = (f.vel - hit.Normal * along * 1.35) * 0.62
                    f.av *= 0.6
                    if f.vel.Magnitude < 5 and hit.Normal.Y > 0.5 then
                        f.settled = true
                        f.vel = Vector3.zero -- (M10A latent bug: V3 is Vector3.new, so V3.zero errored whenever a fragment settled)
                        f.part.CFrame = CF(f.pos) * f.rot
                        continue
                    end
                else
                    f.pos += step
                end
                f.rot = f.rot * CFrame.Angles(f.av.X * dt, f.av.Y * dt, f.av.Z * dt)
                count += 1
                moveParts[count] = f.part
                moveCFrames[count] = CF(f.pos) * f.rot
            end
        end
        if count > 0 then
            workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
        end
    end

    -- Bursts -------------------------------------------------------------------------------------------------------------------
    local function burst(slot, which: string, count: number, color: Color3?, size: number?, lifetimeScale: number?)
        local e = slot[which]
        if color then
            e.Color = ColorSequence.new(color)
        end
        if size then
            if which == "dust" or which == "smoke" then
                e.Size = seq(size * 0.5, size * 2.8)
                e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.6, 0.65), NumberSequenceKeypoint.new(1, 1) })
            elseif which == "chips" then
                e.Size = seq(size, size * 0.4)
            elseif which == "sparks" then
                e.Size = seq(size, 0)
            elseif which == "flash" then
                e.Size = seq(size * 0.5, size)
            elseif which == "fire" then
                e.Size = seq(size, size * 0.1)
            elseif which == "shock" then
                e.Size = seq(size * 0.2, size)
            end
        end
        -- Lifetimes are always derived from the emitter's own base value: a scale is per burst and never compounds across reuse of a slot.
        local base = slot.baseLife[which] or e.Lifetime
        e.Lifetime = if lifetimeScale then NumberRange.new(base.Min * lifetimeScale, base.Max * lifetimeScale) else base
        e:Emit(count)
        stats.bursts += 1
    end
    local function glowLight(slot, color: Color3, brightness: number, range: number, decay: number)
        slot.light.Color, slot.light.Brightness, slot.light.Range = color, brightness, range
        slot.lightRate = decay
    end

    local function nearCamera(pos: Vector3): boolean
        local camera = workspace.CurrentCamera
        return camera ~= nil and (camera.CFrame.Position - pos).Magnitude <= client.maxDistance
    end

    -- Impact on an armoured machine ("h" with a component: tank hull / turret / tracks / engine, mech regions). The recipe (ImpactProfile) is per
    -- weapon class and component family; the weapons must look and sound materially different, and a machine-gun round must not look like artillery.
    local function reflectDir(e): Vector3
        local n = e.n
        if e.i then
            local r = e.i - 2 * e.i:Dot(n) * n
            if r:Dot(n) > 0.05 then
                return (r * 0.7 + n * 0.3).Unit -- a glancing round throws its sparks along the reflected path
            end
        end
        return n
    end
    local TRACK_DIRT, SPARK_DEFAULT = Color3.fromRGB(128, 114, 92), NumberRange.new(12, 36)
    local machineHook: ((any) -> ())? = nil -- ROOK-01 / Bastion scorch marks (MechDamageFx), wired by IronframeClient
    local function machineImpact(e)
        stats.hits += 1
        if machineHook then
            machineHook(e)
        end
        local pos, normal = e.p, e.n
        if not nearCamera(pos) then
            stats.dropped += 1
            return
        end
        -- Pulse-shield interaction (ROOK-01): drawn where the path crosses the shield plane, in field colours, never as metal. A fully absorbed hit
        -- stops here; one that bled through continues as an armour impact below.
        if (e.sh == "PERFECT" or e.sh == "GUARD") then
            local at = e.sp or pos
            local shot = takeSlot(at, if e.i then -e.i else normal)
            local perfect = e.sh == "PERFECT"
            local color = if perfect then Color3.fromRGB(255, 214, 120) else Color3.fromRGB(70, 200, 255)
            burst(shot, "shock", 1, color, if perfect then 14 else 11)
            burst(shot, "flash", 1, color, 3.5)
            burst(shot, "sparks", 8, color, 0.22)
            glowLight(shot, color, 2.2, 14, 8)
            play("zap", at, if perfect then 0.9 else 0.8, if perfect then 1.2 else 0.9)
            if (e.m or 0) <= 0 then
                return
            end
        end
        local r = Profile.For(e.w, e.c)
        local slot = takeSlot(pos, if r.directional then reflectDir(e) else normal)
        slot.sparks.Speed = NumberRange.new(SPARK_DEFAULT.Min * r.sparkSpeed, SPARK_DEFAULT.Max * r.sparkSpeed)
        burst(slot, "sparks", r.sparks, rgb(r.sparkColor), r.sparkSize)
        slot.sparks.Speed = SPARK_DEFAULT
        if r.flash > 0 then
            burst(slot, "flash", 1, rgb(r.light.color), r.flash)
        end
        if r.shock > 0 then
            burst(slot, "shock", 1, nil, r.shock)
        end
        if r.arcs > 0 then
            burst(slot, "sparks", r.arcs, Color3.fromRGB(150, 220, 255), 0.24)
        end
        if r.dust > 0 then
            burst(slot, "dust", r.dust, if r.family == "TRACK" or r.family == "LEG" then TRACK_DIRT else rgb(Config.fx.metal.dust), r.dustSize)
        end
        if r.chips > 0 then
            burst(slot, "chips", r.chips, rgb(Config.fx.metal.debris), 0.5)
        end
        if r.smoke > 0 then
            burst(slot, "smoke", r.smoke, if r.steam then Color3.fromRGB(190, 200, 205) else Color3.fromRGB(46, 46, 48), 1.2 + r.smoke * 0.4)
        end
        local light = r.light
        glowLight(slot, rgb(light.color), light.brightness, light.range, light.decay)
        for _ = 1, r.fragments do
            local dir = (normal + V3(rng:NextNumber(-0.7, 0.7), rng:NextNumber(0, 0.7), rng:NextNumber(-0.7, 0.7))).Unit
            local s = rng:NextNumber(0.5, 1.1)
            spawnFragment(pos + normal * 0.5, dir * rng:NextNumber(22, 44), V3(s * 1.2, s * 0.22, s * 0.9), rgb(Config.fx.metal.debris):Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.3)), Enum.Material.Metal, 9, 2.0)
        end
        for _, key in ipairs({ "sound", "sound2" }) do
            local s = r[key]
            local def = s and Config.audio[s.name]
            if def then
                play(s.name, pos, s.volume / def.volume, s.pitch)
            end
        end
    end

    -- Impact on a surface ("h"). family: panel|concrete|metal|structure|machine; class: MG|LASER|HEAVY.
    local function impact(e)
        if e.c then
            return machineImpact(e)
        end
        stats.hits += 1
        local pos, normal = e.p, e.n
        if not nearCamera(pos) then
            stats.dropped += 1
            return
        end
        local fx = Config.fx[e.f] or Config.fx.metal
        local slot = takeSlot(pos, normal)
        local spark, debris, dust = rgb(fx.spark), rgb(fx.debris), rgb(fx.dust)
        local heavyMetal = e.f == "metal" or e.f == "panel" or e.f == "machine"
        if e.w == "MG" then
            burst(slot, "sparks", if heavyMetal then 6 else 3, spark, 0.26)
            if e.f == "concrete" or e.f == "structure" then
                burst(slot, "dust", 2, dust, 1.1)
                if rng:NextInteger(1, 3) == 1 then
                    burst(slot, "chips", 2, debris, 0.32)
                end
            elseif e.f == "machine" then
                burst(slot, "sparks", 3, Color3.fromRGB(150, 220, 255), 0.22)
            end
            play(if heavyMetal then "metalHit" else "concreteHit", pos, 0.45, 1.25)
        elseif e.w == "LASER" then
            burst(slot, "sparks", 12, Color3.fromRGB(255, 190, 90), 0.3, 1.4)
            burst(slot, "smoke", 1, Color3.fromRGB(60, 60, 62), 1.6)
            if e.f == "machine" then
                burst(slot, "sparks", 8, Color3.fromRGB(120, 215, 255), 0.26)
            end
            glowLight(slot, Color3.fromRGB(255, 160, 70), 1.4, 9, 9)
            if rng:NextInteger(1, 2) == 1 then
                mark(pos, normal, rng:NextNumber(0.9, 1.5))
            end
            play("laserSizzle", pos, 0.7, 1)
        else
            -- HEAVY: the Mauler. Big dust, rock/plate chips, a ring of pressure and a hard flash.
            burst(slot, "flash", 1, Color3.fromRGB(255, 226, 170), 7)
            burst(slot, "shock", 1, nil, 9)
            burst(slot, "sparks", if heavyMetal then 24 else 14, spark, 0.4)
            burst(slot, "dust", if e.f == "concrete" or e.f == "structure" then 12 else 6, dust, 3.2)
            burst(slot, "chips", 12, debris, 0.6)
            glowLight(slot, Color3.fromRGB(255, 200, 120), 3.2, 16, 14)
            mark(pos, normal, rng:NextNumber(2.4, 3.8))
            for _ = 1, 3 do
                local dir = (normal + V3(rng:NextNumber(-0.7, 0.7), rng:NextNumber(0, 0.6), rng:NextNumber(-0.7, 0.7))).Unit
                local s = rng:NextNumber(0.5, 1.2)
                spawnFragment(pos + normal * 0.5, dir * rng:NextNumber(24, 48), V3(s, s * rng:NextNumber(0.6, 1.2), s * rng:NextNumber(0.8, 1.4)), debris:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.3)), if e.f == "concrete" then Enum.Material.Concrete else Enum.Material.Metal, 9, 2.2)
            end
            play(if heavyMetal then "metalHit" else "concreteHit", pos, 1.0, 0.8)
        end
    end

    -- Stage change to DAMAGED ("s")
    local function stage(e)
        if not nearCamera(e.p) then
            return
        end
        local fx = Config.fx[e.f] or Config.fx.metal
        local slot = takeSlot(e.p, e.n)
        burst(slot, "dust", 5, rgb(fx.dust), 2.2)
        burst(slot, "chips", 5, rgb(fx.debris), 0.5)
        burst(slot, "sparks", 6, rgb(fx.spark), 0.3)
        play(if e.f == "concrete" or e.f == "structure" then "concreteHit" else "metalHit", e.p, 0.8, 0.9)
    end

    -- A module (or machine part) is gone ("x"): break, collapse, wreck or explosion.
    local function destroyed(e)
        stats.destroyed += 1
        local cf, size = e.cf, e.s
        local pos = cf.Position
        if not nearCamera(pos) then
            stats.dropped += 1
            return
        end
        local fx = Config.fx[e.f] or Config.fx.metal
        local power = math.clamp(e.e or 1, 0.4, 3.4)
        local color, material = e.c, e.mat
        local slot = takeSlot(pos, V3(0, 1, 0))
        slot.dust.SpreadAngle = Vector2.new(180, 180)
        if e.k == "explosion" then
            burst(slot, "flash", 1, Color3.fromRGB(255, 232, 190), 10 * power)
            burst(slot, "fire", 12 + math.floor(power * 6), nil, 5 * power)
            burst(slot, "shock", 1, nil, 22 * power)
            burst(slot, "smoke", 10, Color3.fromRGB(46, 46, 48), 6 * power)
            burst(slot, "sparks", 30, Color3.fromRGB(255, 190, 90), 0.5)
            burst(slot, "chips", 14, Color3.fromRGB(40, 40, 42), 0.7)
            glowLight(slot, Color3.fromRGB(255, 170, 80), 3.6, 28, 7)
            play("explosion", pos, math.min(1, 0.55 + power * 0.2), 1)
            for _ = 1, 4 do
                local dir = V3(rng:NextNumber(-1, 1), rng:NextNumber(0.5, 1.6), rng:NextNumber(-1, 1)).Unit
                local s = rng:NextNumber(0.6, 1.6) * math.min(power, 2)
                spawnFragment(pos, dir * rng:NextNumber(30, 60), V3(s, s * 0.6, s * 1.2), Color3.fromRGB(34, 34, 36), Enum.Material.Metal, 10, 3)
            end
        elseif e.k == "trackbreak" then
            -- A track lets go: a hard clang, sparks, a rolling dirt cloud and a handful of thrown links.
            local back = if e.v then (e.v - pos) else V3(0, 0, 1)
            back = if back.Magnitude > 0.1 then back.Unit else V3(0, 0, 1)
            slot.dust.SpreadAngle = Vector2.new(120, 120)
            burst(slot, "dust", 14, TRACK_DIRT, 5)
            burst(slot, "sparks", 28, Color3.fromRGB(255, 200, 100), 0.4)
            burst(slot, "smoke", 4, Color3.fromRGB(44, 44, 46), 3)
            burst(slot, "flash", 1, Color3.fromRGB(255, 226, 170), 6)
            burst(slot, "chips", 8, Color3.fromRGB(40, 41, 43), 0.5)
            glowLight(slot, Color3.fromRGB(255, 190, 110), 2.2, 16, 9)
            play("metalHit", pos, 1.0, 0.55)
            play("zap", pos, 0.6, 0.7)
            for _ = 1, 5 do
                local dir = (back * 0.8 + V3(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0.4, 1.1), rng:NextNumber(-0.5, 0.5))).Unit
                spawnFragment(pos, dir * rng:NextNumber(14, 30), V3(2.4, 0.2, 0.8), Color3.fromRGB(36, 37, 39), Enum.Material.Metal, 8, 2.6)
            end
        elseif e.k == "turretbreak" then
            -- The turret mechanism fails: an electrical burst at the gun mount and the ring, hatch pieces thrown up.
            burst(slot, "sparks", 30, Color3.fromRGB(140, 220, 255), 0.34)
            burst(slot, "sparks", 14, Color3.fromRGB(255, 200, 110), 0.3)
            burst(slot, "smoke", 6, Color3.fromRGB(40, 40, 42), 3.4)
            burst(slot, "flash", 1, Color3.fromRGB(200, 236, 255), 8)
            burst(slot, "shock", 1, nil, 12)
            glowLight(slot, Color3.fromRGB(150, 220, 255), 2.4, 18, 8)
            play("explosion", pos, 0.45, 1.6)
            play("zap", pos, 0.9, 0.9)
            for _ = 1, 3 do
                local dir = V3(rng:NextNumber(-0.6, 0.6), rng:NextNumber(0.9, 1.5), rng:NextNumber(-0.6, 0.6)).Unit
                local s = rng:NextNumber(0.7, 1.4)
                spawnFragment(pos + V3(0, 2, 0), dir * rng:NextNumber(18, 34), V3(s * 1.4, s * 0.25, s), Color3.fromRGB(72, 76, 72), Enum.Material.Metal, 9, 2.6)
            end
        elseif e.k == "hullbreak" then
            -- The turret ring fails in the hull explosion: shock ring, heavy chips and large plates thrown clear.
            burst(slot, "flash", 1, Color3.fromRGB(255, 232, 190), 12)
            burst(slot, "shock", 1, nil, 24)
            burst(slot, "fire", 10, nil, 5)
            burst(slot, "sparks", 36, Color3.fromRGB(255, 190, 90), 0.5)
            burst(slot, "chips", 14, Color3.fromRGB(40, 40, 42), 0.7)
            burst(slot, "smoke", 6, Color3.fromRGB(40, 40, 42), 6)
            glowLight(slot, Color3.fromRGB(255, 170, 80), 3.4, 26, 6)
            play("explosion", pos, 0.8, 1.1)
            for _ = 1, 5 do
                local dir = V3(rng:NextNumber(-1, 1), rng:NextNumber(0.7, 1.6), rng:NextNumber(-1, 1)).Unit
                local s = rng:NextNumber(1.1, 2.2)
                spawnFragment(pos, dir * rng:NextNumber(24, 48), V3(s * 1.6, s * 0.28, s * 1.1), Color3.fromRGB(72, 78, 72):Lerp(Color3.new(0, 0, 0), rng:NextNumber(0.1, 0.5)), Enum.Material.Metal, 8, 3.2)
            end
        elseif e.k == "mechfail" then
            -- A mech region failed. Arm: the weapon assembly dies in a spray of sparks and a small fire; leg: an actuator bursts, dust and smoke; reactor: a
            -- bright arc flash and a plume of coolant steam. (The darkened armour, fault lamps and smoke that follow are MechDamageFx.)
            local region = e.comp or ""
            local reactor = region == "REACTOR"
            local leg = string.find(region, "^LEG") ~= nil
            burst(slot, "flash", 1, if reactor then Color3.fromRGB(190, 235, 255) else Color3.fromRGB(255, 220, 160), if reactor then 9 else 6)
            burst(slot, "sparks", if reactor then 34 else 24, if reactor then Color3.fromRGB(150, 220, 255) else Color3.fromRGB(255, 190, 100), 0.34)
            burst(slot, "smoke", if reactor then 6 else 3, if reactor then Color3.fromRGB(190, 200, 205) else Color3.fromRGB(40, 40, 42), if reactor then 5 else 3)
            if leg then
                burst(slot, "dust", 10, TRACK_DIRT, 4)
            else
                burst(slot, "fire", 5, nil, 2.6)
            end
            burst(slot, "shock", 1, nil, 12)
            glowLight(slot, if reactor then Color3.fromRGB(160, 225, 255) else Color3.fromRGB(255, 180, 90), 2.6, 18, 8)
            play("explosion", pos, 0.5, 1.5)
            play("zap", pos, 0.7, 1.0)
            for _ = 1, if leg then 4 else 3 do
                local dir = V3(rng:NextNumber(-1, 1), rng:NextNumber(0.4, 1.3), rng:NextNumber(-1, 1)).Unit
                local s = rng:NextNumber(0.5, 1.2)
                spawnFragment(pos, dir * rng:NextNumber(14, 34), V3(s * 1.2, s * 0.3, s), Color3.fromRGB(70, 74, 72):Lerp(Color3.new(0, 0, 0), rng:NextNumber(0.1, 0.5)), Enum.Material.Metal, 9, 2.4)
            end
        elseif e.k == "cookoff" then
            burst(slot, "flash", 1, Color3.fromRGB(255, 220, 160), 7 * power)
            burst(slot, "fire", 6, nil, 3 * power)
            burst(slot, "shock", 1, nil, 12 * power)
            burst(slot, "sparks", 18, Color3.fromRGB(255, 200, 100), 0.4)
            burst(slot, "smoke", 3, Color3.fromRGB(44, 44, 46), 4)
            glowLight(slot, Color3.fromRGB(255, 180, 90), 2.6, 20, 8)
            play("explosion", pos, 0.5, 1.45)
        elseif e.k == "wreck" then
            burst(slot, "sparks", 26, Color3.fromRGB(130, 220, 255), 0.34, 1.5)
            burst(slot, "sparks", 12, Color3.fromRGB(255, 200, 110), 0.3)
            burst(slot, "smoke", 5, Color3.fromRGB(40, 40, 42), 3 * power)
            burst(slot, "flash", 1, Color3.fromRGB(190, 235, 255), 6 * power)
            glowLight(slot, Color3.fromRGB(150, 220, 255), 3, 22, 8)
            play("zap", pos, 0.9, 1)
            -- Delayed electrical crackle at the failed machine.
            for i = 1, 3 do
                task.delay(0.12 * i + rng:NextNumber(0, 0.08), function()
                    local s2 = takeSlot(pos + V3(rng:NextNumber(-2, 2), rng:NextNumber(0, 3), rng:NextNumber(-2, 2)), V3(0, 1, 0))
                    burst(s2, "sparks", 8, Color3.fromRGB(150, 225, 255), 0.26)
                end)
            end
        else
            local collapse = e.k == "collapse"
            local concrete = e.f == "concrete" or e.f == "structure"
            burst(slot, "dust", math.floor((if concrete then 14 else 7) * power) + (if collapse then 8 else 0), rgb(fx.dust), (if concrete then 4.5 else 3) * power)
            burst(slot, "smoke", if concrete then 3 else 1, rgb(fx.dust):Lerp(Color3.new(0, 0, 0), 0.25), 4 * power)
            burst(slot, "chips", 8 + math.floor(power * 4), rgb(fx.debris), 0.55)
            if not concrete then
                burst(slot, "sparks", 18, rgb(fx.spark), 0.4)
            end
            burst(slot, "shock", 1, nil, (if concrete then 14 else 9) * power)
            glowLight(slot, Color3.fromRGB(255, 205, 140), 2.2, 18, 10)
            play(if concrete then "collapse" else "metalHit", pos, math.min(1, 0.5 + power * 0.25), if concrete then 1 else 0.85)
            -- Fragments: big chunks plus (for panels / metal) one large flying plate that keeps the module's silhouette.
            local count = math.min(10, fx.fragments + math.floor(power * 3))
            local outward = (if e.v then (pos - e.v) else V3(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)))
            outward = if outward.Magnitude > 0.1 then outward.Unit else V3(0, 0, -1)
            for i = 1, count do
                local s = rng:NextNumber(0.9, 2.6) * (0.6 + power * 0.35)
                local dir = (outward * (if collapse then 0.35 else 1) + V3(rng:NextNumber(-0.8, 0.8), rng:NextNumber(0.3, 1.1), rng:NextNumber(-0.8, 0.8))).Unit
                local speed = if collapse then rng:NextNumber(6, 22) else rng:NextNumber(18, 44)
                local origin = (cf * CF(rng:NextNumber(-0.4, 0.4) * size.X, rng:NextNumber(-0.4, 0.4) * size.Y, rng:NextNumber(-0.4, 0.4) * size.Z)).Position
                if i == 1 and not concrete and size.Magnitude > 4 then
                    -- the plate itself
                    local plate = V3(math.max(size.X, size.Z) * 0.8, math.min(size.Y, 6) * 0.9, 0.35)
                    if size.Y > size.X and size.Y > size.Z then plate = V3(size.Y * 0.6, 0.35, math.max(size.X, size.Z) * 0.8) end
                    spawnFragment(cf.Position, dir * speed * 0.8, plate, color, material, 3.5, 3.4)
                else
                    spawnFragment(origin, dir * speed, V3(s, s * rng:NextNumber(0.5, 1), s * rng:NextNumber(0.7, 1.3)), color:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.35)), material, 8, nil)
                end
            end
        end
        slot.dust.SpreadAngle = Vector2.new(75, 75)
    end

    local function clearAll()
        for i = #active, 1, -1 do
            releaseFragment(active[i])
            table.remove(active, i)
        end
        for _, s in ipairs(scorch) do
            s.part.Transparency = 1
            s.born = -100
        end
    end

    remotes.DestructionFx.OnClientEvent:Connect(function(packet)
        if type(packet) ~= "table" then
            return
        end
        for _, e in ipairs(packet) do
            stats.events += 1
            local t = e.t
            if t == "h" then
                impact(e)
            elseif t == "x" then
                destroyed(e)
            elseif t == "s" then
                stage(e)
            elseif t == "n" then
                if hud then
                    hud.Notice(e.text)
                end
            elseif t == "c" then
                clearAll()
            end
        end
    end)

    local filterAt = 0
    RunService:BindToRenderStep("IronframeDestructionFx", Enum.RenderPriority.Camera.Value + 3, function(dt)
        local started = os.clock()
        if started - filterAt > 2 then
            filterAt = started
            refreshFilter()
        end
        stepFragments(math.min(dt, 0.05))
        for _, slot in ipairs(slots) do
            if slot.light.Brightness > 0 then
                slot.light.Brightness = math.max(0, slot.light.Brightness - slot.lightRate * dt)
            end
        end
        local clock = os.clock()
        for _, s in ipairs(scorch) do
            local age = clock - s.born
            if age < s.life then
                local cool = math.clamp(age / 1.6, 0, 1)
                s.part.Color = Color3.fromRGB(255, 140, 50):Lerp(Color3.fromRGB(14, 13, 12), cool)
                s.part.Material = if cool < 1 then Enum.Material.Neon else Enum.Material.Slate
                s.part.Transparency = if age > s.life - 4 then math.clamp(1 - (s.life - age) / 4, 0.1, 1) else 0.1
            elseif s.part.Transparency < 1 then
                s.part.Transparency = 1
            end
        end
        local elapsed = (os.clock() - started) * 1000
        stats.stepMs += (elapsed - stats.stepMs) * 0.05
        stats.worstMs = math.max(stats.worstMs, elapsed)
    end)

    -- Client-only test interface (same remotes/data as production; used by the Studio verification scripts).
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeDestructionControl"
    control.OnInvoke = function(command, a)
        if command == "report" then
            local activeFragments, settled = 0, 0
            for _, f in ipairs(active) do
                activeFragments += 1
                if f.settled then
                    settled += 1
                end
            end
            return {
                events = stats.events, hits = stats.hits, destroyed = stats.destroyed, bursts = stats.bursts, active = activeFragments, settled = settled,
                spawned = stats.fragmentsSpawned, recycled = stats.fragmentsRecycled, scorch = stats.scorchSpawned, sounds = stats.soundsPlayed,
                stepMs = stats.stepMs, worstMs = stats.worstMs, dropped = stats.dropped, instances = #root:GetDescendants(),
                pool = #pool, slots = #slots, voices = #voices,
            }
        elseif command == "clear" then
            clearAll()
        elseif command == "inject" and type(a) == "table" then
            for _, e in ipairs(a) do
                if e.t == "h" then impact(e) elseif e.t == "x" then destroyed(e) elseif e.t == "s" then stage(e) end
            end
        end
        return nil
    end
    control.Parent = player.PlayerScripts
    return { Clear = clearAll, SetMachineHook = function(fn) machineHook = fn end }
end

return Fx
