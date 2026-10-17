-- Progressive mechanical damage on the Bastion (M10B), cosmetic only. The server publishes per-region health fractions as model
-- attributes (Dmg_CORE, Dmg_ARM_L, ...); this module turns them into what you see:
--
--   DAMAGED   scorched, darkened armour, occasional sparks
--   CRITICAL  dark smoke, regular sparks, electrical failure (glow parts flicker)
--   FAILED    heavy smoke, a dead region: disabled weapon mounts go dark with a pulsing red fault lamp, a failed reactor goes out
--   CORE FAIL terminal shutdown: every light stutters and dies, smoke pours from the torso, sparks burst (the server removes the
--             machine a moment later with a final burst, after the pilot is already safe)
--
-- Scorch marks are small dark discs welded (in code, each frame) to the rig part nearest the impact. Darkened armour is a graded
-- EditableImage per (texture, tint) exactly like ArmorGrade.client does it, because MeshPart.Color cannot tint a baked texture.
-- Everything is bounded (<= 12 emitters, <= 14 discs per model, a handful of shared images) and removed by repair or model removal.
-- Pilots do not appear here: there is no person in this model, only machinery.

local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Damage = require(Shared:WaitForChild("MechDamage"))

local MechDamageFx = {}

local SOOT = Color3.fromRGB(20, 20, 22)
local STAGE_DARK = { OK = 0, DAMAGED = 0, CRITICAL = 0.5, FAILED = 0.7 } -- DAMAGED shows scorch / sparks only: fewer distinct images
local STAGE_RANK = { OK = 0, DAMAGED = 1, CRITICAL = 2, FAILED = 3 }
local MAX_DISCS = 14
local DISCS_PER_REGION = 3

-- Shared graded images (refcounted) ---------------------------------------------------------------------------------------
local images: { [string]: { image: any, users: number } } = {}
local pending: { [string]: boolean } = {}
local function imageKey(texture: string, color: Color3): string
    return string.format("%s|%d,%d,%d", texture, math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- Damaged-armour images are deliberately small (256 x 256) and capped: EditableImage memory is a shared client budget that
-- ArmorGrade also draws on, and a damaged plate does not need the full-resolution texture. On a budget failure darkening is
-- switched off for a while (smoke, sparks, scorch discs and lamps carry the damage presentation on their own).
local IMAGE_SIZE = Vector2.new(256, 256)
local MAX_IMAGES = 12
local imageCount = 0
local blockedUntil = 0
local function acquireImage(texture: string, color: Color3): any?
    local key = imageKey(texture, color)
    local entry = images[key]
    if entry then
        entry.users += 1
        return entry.image, key
    end
    if pending[key] or imageCount >= MAX_IMAGES or os.clock() < blockedUntil then
        return nil, nil
    end
    pending[key] = true
    local ok, result = pcall(function()
        local image = AssetService:CreateEditableImageAsync(Content.fromUri(texture))
        image:Resize(IMAGE_SIZE)
        image:DrawRectangle(Vector2.zero, image.Size, color, 0, Enum.ImageCombineType.Multiply)
        return image
    end)
    pending[key] = nil
    if not ok then
        blockedUntil = os.clock() + 20
        return nil, nil
    end
    imageCount += 1
    images[key] = { image = result, users = 1 }
    return result, key
end

local function releaseImage(key: string?)
    local entry = key and images[key]
    if not entry then
        return
    end
    entry.users -= 1
    if entry.users <= 0 then
        images[key :: string] = nil
        imageCount -= 1
        entry.image:Destroy()
    end
end

-- Per-model state -----------------------------------------------------------------------------------------------------------
local entries: { [Model]: any } = setmetatable({}, { __mode = "k" }) :: any

local function emitter(host: BasePart, kind: string): Instance
    local a = Instance.new("Attachment")
    a.Name = "DamageFx_" .. kind
    a.Parent = host
    local e = Instance.new("ParticleEmitter")
    e.Name = kind
    if kind == "Sparks" then
        e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        e.Color = ColorSequence.new(Color3.fromRGB(255, 226, 150), Color3.fromRGB(255, 120, 40))
        e.LightEmission, e.Lifetime = 1, NumberRange.new(0.2, 0.5)
        e.Speed, e.SpreadAngle = NumberRange.new(6, 16), Vector2.new(180, 180)
        e.Acceleration = Vector3.new(0, -30, 0)
        e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
        e.Rate = 0
    else
        e.Texture = "rbxasset://textures/particles/smoke_main.dds"
        e.Color = ColorSequence.new(Color3.fromRGB(44, 44, 46), Color3.fromRGB(96, 96, 98))
        e.Lifetime, e.Speed, e.SpreadAngle = NumberRange.new(1.6, 2.8), NumberRange.new(2, 5), Vector2.new(14, 14)
        e.Acceleration = Vector3.new(0.6, 2.5, 0)
        e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 3.4) })
        e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.7, 0.7), NumberSequenceKeypoint.new(1, 1) })
        e.RotSpeed = NumberRange.new(-30, 30)
        e.Rate = 0
    end
    e.Parent = a
    return e
end

local function build(model: Model)
    local entry = { model = model, regions = {}, stage = {}, discs = {}, discCount = {}, flicker = {}, lamps = {}, shutdown = nil, reactorFactor = 1 }
    for _, region in ipairs(Damage.Regions) do
        entry.regions[region] = { parts = {}, armor = {}, glow = {}, host = nil, hostSize = 0, sparks = nil, smoke = nil }
        entry.stage[region] = "OK"
        entry.discCount[region] = 0
    end
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "Chassis" and part:GetAttribute("Joint") then
            local localCF = part:GetAttribute("LocalCF")
            local region = Damage.ClassifyPart(part.Name, part:GetAttribute("Joint"), part:GetAttribute("Group"), if localCF then localCF.Position.X else 0)
            local info = { part = part, color = part.Color, material = part.Material, transparency = part.Transparency }
            local r = entry.regions[region]
            table.insert(r.parts, info)
            if part.Material == Enum.Material.Neon or part:GetAttribute("Group") == "glow" then
                table.insert(r.glow, info)
            elseif part:GetAttribute("Group") == "armor" or part:IsA("MeshPart") then
                table.insert(r.armor, info)
            end
            local size = part.Size.Magnitude
            if size > r.hostSize and part.Material ~= Enum.Material.Neon then
                r.host, r.hostSize = part, size
            end
        end
    end
    -- One client-only Highlight chars the whole machine as it takes damage (MeshPart.Color cannot tint the baked / graded armour
    -- textures and the shared EditableImage budget may be spent, so this is the guaranteed baseline; per-region texture darkening is a bonus).
    local soot = Instance.new("Highlight")
    soot.Name = "DamageSoot"
    soot.FillColor, soot.OutlineTransparency, soot.FillTransparency = Color3.fromRGB(10, 9, 9), 1, 1
    soot.DepthMode = Enum.HighlightDepthMode.Occluded
    soot.Enabled = false
    soot.Adornee = model
    soot.Parent = model
    entry.soot = soot
    entries[model] = entry
    return entry
end

-- Armour darkening --------------------------------------------------------------------------------------------------------
local function darken(info, amount: number)
    local part: BasePart = info.part
    if not part.Parent then
        return
    end
    -- ArmorGrade replaces the baked texture with a graded EditableImage (TextureID may then read empty); its GradeKey attribute
    -- still carries the original asset id ("<texture>|r,g,b").
    local texture = if part:IsA("MeshPart") then (if part.TextureID ~= "" then part.TextureID else string.match(tostring(part:GetAttribute("GradeKey") or ""), "^(.-)|")) else nil
    if texture and texture ~= "" and typeof(part:GetAttribute("TintColor")) == "Color3" then
        if amount <= 0 then
            -- Back to the plate ArmorGrade graded: put its content back and drop the darkened copy.
            if info.imageKey and info.original then
                part.TextureContent = info.original
                releaseImage(info.imageKey)
                info.imageKey = nil
            end
            return
        end
        info.original = info.original or part.TextureContent
        local tint = (part:GetAttribute("TintColor") :: Color3):Lerp(SOOT, amount)
        local key = imageKey(texture, tint)
        if info.imageKey == key then
            return
        end
        task.spawn(function()
            local image, newKey = acquireImage(texture, tint)
            if image and part.Parent then
                part.TextureContent = Content.fromObject(image)
                releaseImage(info.imageKey)
                info.imageKey = newKey
            elseif newKey then
                releaseImage(newKey)
            end
        end)
    elseif not part:IsA("MeshPart") then
        part.Color = info.color:Lerp(SOOT, amount)
    end
end

local function setEmitters(entry, region: string, stage: string)
    local r = entry.regions[region]
    if not r.host then
        return
    end
    local sparks = if stage == "OK" then 0 elseif stage == "DAMAGED" then 3 elseif stage == "CRITICAL" then 9 else 5
    local smoke = if stage == "OK" then 0 elseif stage == "DAMAGED" then 3 elseif stage == "CRITICAL" then 11 else 20
    if region == "CORE" and stage ~= "OK" then
        smoke *= 1.3
    end
    if sparks > 0 and not r.sparks then
        r.sparks = emitter(r.host, "Sparks")
    end
    if smoke > 0 and not r.smoke then
        r.smoke = emitter(r.host, "Smoke")
    end
    if r.sparks then
        (r.sparks :: ParticleEmitter).Rate = sparks
    end
    if r.smoke then
        (r.smoke :: ParticleEmitter).Rate = smoke
    end
end

local function setLamp(entry, region: string, on: boolean)
    local r = entry.regions[region]
    local lamp = entry.lamps[region]
    if on and r.host then
        if not lamp then
            lamp = Instance.new("PointLight")
            lamp.Name = "FaultLamp"
            lamp.Color, lamp.Range, lamp.Brightness, lamp.Shadows = Color3.fromRGB(255, 50, 36), 9, 0, false
            lamp.Parent = r.host
            entry.lamps[region] = lamp
        end
    elseif lamp then
        lamp:Destroy()
        entry.lamps[region] = nil
    end
end

local function applyStage(entry, region: string, stage: string)
    local r = entry.regions[region]
    local previous = entry.stage[region]
    entry.stage[region] = stage
    local amount = STAGE_DARK[stage]
    for _, info in ipairs(r.armor) do
        darken(info, amount)
    end
    if stage == "OK" then
        for _, info in ipairs(r.parts) do
            if not info.part:IsA("MeshPart") then
                info.part.Color = info.color
            end
        end
    end
    setEmitters(entry, region, stage)
    -- Weapon assemblies: a dead assembly leaves its mounts dark with a pulsing fault lamp; electrical failure for the others.
    local isArm = region == "ARM_L" or region == "ARM_R"
    setLamp(entry, region, stage == "FAILED" and (isArm or region == "REACTOR"))
    if isArm and STAGE_RANK[stage] >= STAGE_RANK.FAILED then
        for _, info in ipairs(r.parts) do
            if string.find(info.part.Name, "^Weapon_") or string.find(info.part.Name, "^Mount_") then
                if not info.part:IsA("MeshPart") then
                    info.part.Color = info.color:Lerp(SOOT, 0.85)
                end
                darken(info, 0.85)
            end
        end
    end
    local flickers = STAGE_RANK[stage] >= STAGE_RANK.CRITICAL or (region == "REACTOR" and STAGE_RANK[stage] >= STAGE_RANK.DAMAGED)
    entry.flicker[region] = if flickers then stage else nil
    if STAGE_RANK[stage] < STAGE_RANK[previous] then
        -- Repair: restore glow parts that flicker/fade drove.
        for _, info in ipairs(r.glow) do
            info.part.Transparency, info.part.Color = info.transparency, info.color
        end
    end
end

local function clearAll(entry)
    for _, region in ipairs(Damage.Regions) do
        applyStage(entry, region, "OK")
        local r = entry.regions[region]
        for _, info in ipairs(r.parts) do
            if info.imageKey then
                releaseImage(info.imageKey)
                info.imageKey = nil
            end
        end
    end
    for _, disc in ipairs(entry.discs) do
        disc.part:Destroy()
    end
    entry.discs, entry.shutdown = {}, nil
    for region in pairs(entry.discCount) do
        entry.discCount[region] = 0
    end
end

-- Scorch discs ----------------------------------------------------------------------------------------------------------------
-- Welds (every frame, see the render step) a dark disc to the rig part of `region` nearest to the world contact point.
function MechDamageFx.OnHit(e)
    if e.why ~= "MECH" or not e.region or not e.p then
        return
    end
    local folder = workspace:FindFirstChild("IronframeMechs")
    local model = folder and folder:FindFirstChild(tostring(game:GetService("Players").LocalPlayer.UserId))
    local entry = model and entries[model]
    if not entry or e.pen <= 0 or #entry.discs >= MAX_DISCS or entry.discCount[e.region] >= DISCS_PER_REGION then
        return
    end
    local r = entry.regions[e.region]
    local best, bestDistance
    for _, info in ipairs(r.parts) do
        local d = (info.part.Position - e.p).Magnitude
        if info.part.Material ~= Enum.Material.Neon and (not bestDistance or d < bestDistance) then
            best, bestDistance = info.part, d
        end
    end
    if not best then
        return
    end
    local local0 = best.CFrame:PointToObjectSpace(e.p)
    local half = best.Size / 2
    -- Snap to the part's nearest face so the disc sits on armour rather than floating at the hull box.
    local dx, dy, dz = half.X - math.abs(local0.X), half.Y - math.abs(local0.Y), half.Z - math.abs(local0.Z)
    local face, offset
    if dx <= dy and dx <= dz then
        face, offset = Vector3.new(math.sign(local0.X), 0, 0), Vector3.new(math.sign(local0.X) * half.X, math.clamp(local0.Y, -half.Y, half.Y), math.clamp(local0.Z, -half.Z, half.Z))
    elseif dy <= dz then
        face, offset = Vector3.new(0, math.sign(local0.Y), 0), Vector3.new(math.clamp(local0.X, -half.X, half.X), math.sign(local0.Y) * half.Y, math.clamp(local0.Z, -half.Z, half.Z))
    else
        face, offset = Vector3.new(0, 0, math.sign(local0.Z)), Vector3.new(math.clamp(local0.X, -half.X, half.X), math.clamp(local0.Y, -half.Y, half.Y), math.sign(local0.Z) * half.Z)
    end
    if face.Magnitude == 0 then
        face, offset = Vector3.new(0, 1, 0), Vector3.new(0, half.Y, 0)
    end
    local diameter = if e.heavy then 3.4 else 2.2
    local disc = Instance.new("Part")
    disc.Name = "Scorch"
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = Vector3.new(0.08, diameter, diameter)
    disc.Anchored, disc.CanCollide, disc.CanQuery, disc.CanTouch, disc.CastShadow = true, false, false, false, false
    disc.Material, disc.Color, disc.Transparency = Enum.Material.Slate, Color3.fromRGB(14, 13, 12), 0.1
    disc.Parent = model
    local cf = CFrame.lookAt(offset + face * 0.05, offset + face * 2) * CFrame.Angles(0, math.pi / 2, 0)
    table.insert(entry.discs, { part = disc, host = best, cf = cf })
    entry.discCount[e.region] += 1
end

-- Driver ------------------------------------------------------------------------------------------------------------------------
function MechDamageFx.Start()
    local accumulator = 0
    local function sync(model: Model)
        local entry = entries[model] or build(model)
        local failed = model:GetAttribute("DmgCoreFailed") == true or model:GetAttribute("State") == "PILOT_EVACUATED"
        local allClear = true
        for _, region in ipairs(Damage.Regions) do
            local fraction = model:GetAttribute("Dmg_" .. region) or 1
            local stage = Damage.Stage(fraction)
            if stage ~= "OK" then
                allClear = false
            end
            if failed and region ~= "CORE" then
                stage = if STAGE_RANK[stage] < STAGE_RANK.CRITICAL then "CRITICAL" else stage
            end
            if failed and region == "CORE" then
                stage = "FAILED"
            end
            if entry.stage[region] ~= stage then
                applyStage(entry, region, stage)
            end
        end
        if allClear and not failed and (#entry.discs > 0 or entry.shutdown) then
            clearAll(entry)
        end
        if failed and not entry.shutdown then
            entry.shutdown = os.clock()
        end
        entry.reactorFactor = model:GetAttribute("DmgReactorFactor") or 1
        -- Overall char level: the core counts for half, the other five regions share the rest.
        local others = 0
        for _, region in ipairs(Damage.Regions) do
            if region ~= "CORE" then
                others += 1 - (model:GetAttribute("Dmg_" .. region) or 1)
            end
        end
        local level = math.clamp(0.5 * (1 - (model:GetAttribute("Dmg_CORE") or 1)) + 0.5 * others / 5, 0, 1)
        if failed then
            level = 1
        end
        entry.soot.Enabled = level > 0.04
        entry.soot.FillTransparency = 0.92 - 0.4 * level
    end

    -- Slow poll (10 Hz): attribute reads and stage transitions only.
    RunService.Heartbeat:Connect(function(dt)
        accumulator += dt
        if accumulator < 0.1 then
            return
        end
        accumulator = 0
        local folder = workspace:FindFirstChild("IronframeMechs")
        if not folder then
            return
        end
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and model:GetAttribute("Dmg_CORE") ~= nil and model:GetAttribute("PartCount") then
                sync(model)
            end
        end
    end)

    -- After the showroom animator has posed the rig: keep discs on their parts and drive flicker / shutdown.
    local perf = { ms = 0, worst = 0 }
    RunService:BindToRenderStep("IronframeMechDamage", Enum.RenderPriority.Camera.Value, function()
        local now = os.clock()
        for model, entry in pairs(entries) do
            if not model.Parent then
                entries[model] = nil
                for _, region in ipairs(Damage.Regions) do
                    for _, info in ipairs(entry.regions[region].parts) do
                        releaseImage(info.imageKey)
                    end
                end
                continue
            end
            for _, disc in ipairs(entry.discs) do
                if disc.host.Parent then
                    disc.part.CFrame = disc.host.CFrame * disc.cf
                end
            end
            local dead = entry.shutdown and (now - entry.shutdown) or nil
            for region, stage in pairs(entry.flicker) do
                local r = entry.regions[region]
                for _, info in ipairs(r.glow) do
                    local flick = math.sin(now * 47 + #info.part.Name) * math.sin(now * 13.7 + info.part.Position.X) > (if stage == "FAILED" then -0.2 else 0.35)
                    info.part.Transparency = if flick then info.transparency else 0.88
                end
            end
            local reactor = entry.regions.REACTOR
            if entry.stage.REACTOR == "OK" and entry.reactorFactor < 0.999 then
                for _, info in ipairs(reactor.glow) do
                    info.part.Color = info.color:Lerp(SOOT, 1 - entry.reactorFactor)
                end
            end
            for region, lamp in pairs(entry.lamps) do
                lamp.Brightness = 3.5 * math.max(0, math.sin(now * 9)) ^ 2
            end
            if dead then
                -- Terminal shutdown: every glow part stutters out over about a second.
                local f = math.clamp(dead / 1.1, 0, 1)
                for _, r in pairs(entry.regions) do
                    for _, info in ipairs(r.glow) do
                        local stutter = math.sin(now * (30 + 40 * f)) > (1 - 2.2 * f) - 0.5
                        info.part.Transparency = if f >= 1 or not stutter then 0.92 else info.transparency
                        info.part.Color = info.color:Lerp(SOOT, f)
                    end
                end
            end
        end
        local spent = (os.clock() - now) * 1000
        perf.ms += (spent - perf.ms) * 0.05
        perf.worst = math.max(perf.worst, spent)
    end)

    local api = {}
    function api.Stats()
        local discs, emitters, imageCount = 0, 0, 0
        for _, entry in pairs(entries) do
            discs += #entry.discs
            for _, r in pairs(entry.regions) do
                emitters += (if r.sparks then 1 else 0) + (if r.smoke then 1 else 0)
            end
        end
        for _ in pairs(images) do
            imageCount += 1
        end
        return { discs = discs, emitters = emitters, images = imageCount, ms = perf.ms, worstMs = perf.worst }
    end
    api.OnHit = MechDamageFx.OnHit
    return api
end

return MechDamageFx
