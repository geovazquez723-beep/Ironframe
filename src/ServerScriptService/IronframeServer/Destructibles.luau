-- Server-authoritative destructible environment (M10A).
--
-- Everything that decides "is it destroyed?" lives here and in the pure shared modules (DestructibleState, ComponentRules):
--   * One registry maps every hittable BasePart to (district, object, component). The weapon raycast (Weapons.Step) already
--     returns that part; CombatTargets.Hit forwards it here with the weapon id, hit position and normal.
--   * Health, stage and support are tables, never client state. Clients only receive batched cosmetic events (FxBatch).
--   * Destruction is not cosmetic: a destroyed module is removed from the workspace (collision AND line of sight, because the
--     mech probe and the weapon raycast both read CanQuery geometry) and can only come back through an explicit Reset.
--   * Modules are re-parented, never recreated: reset restores the exact instances (no growth). Vehicles and the training
--     mech are rebuilt by their own builders (respawn), after the old instances have been unregistered and destroyed.
--
-- Objects:
--   module   one Part (optionally inside a holder Model with non-queryable decor): wall panel, barrier, fence, column...
--   vehicle  multi-component machine (TrainingTank)
--   mech     multi-component machine (TrainingMech)
-- Training machines are unmanned. No occupant, no injury; "disabled" and "destroyed" refer to machinery only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Config = require(Shared:WaitForChild("DestructionConfig"))
local Unit = require(Shared:WaitForChild("DestructibleState"))
local Batch = require(Shared:WaitForChild("FxBatch"))

local Destructibles = {}

local limits = Config.limits
local districts = {} -- [bay Model] = district
local partIndex = {} -- [BasePart] = { district, obj, comp }
local fxRemote: RemoteEvent? = nil
local rng = Random.new(10101)
local nextId = 0

local SOOT = Color3.fromRGB(24, 24, 26)
local ORIGIN_UP = Vector3.new(0, 1, 0)

Destructibles.Config = Config

function Destructibles.SetRemote(remote: RemoteEvent)
    fxRemote = remote
end

-- District ---------------------------------------------------------------------------------------------------------------
local function newStats()
    return {
        damage = 0, hits = 0, byClass = { MG = 0, LASER = 0, HEAVY = 0 },
        targetsDisabled = 0, vehiclesDestroyed = 0, componentsLost = 0,
        sectionsDestroyed = 0, wallsBreached = 0, collapses = 0, resets = 0,
    }
end

function Destructibles.NewDistrict(bay: Model, origin: Vector3, parent: Instance)
    local folder = Instance.new("Model")
    folder.Name = "TestingDistrict"
    folder.Parent = parent
    local d = {
        bay = bay, origin = origin, folder = folder, owner = nil :: Player?,
        objects = {}, modules = {}, groups = {}, vehicles = {}, mech = nil, wallGroups = 0,
        totals = { sections = 0, walls = 0, vehicles = 0, targets = 0 },
        stats = newStats(),
        batch = Batch.New(limits.fxBatchInterval, limits.fxHitsPerBatch, limits.fxMaxEventsPerBatch),
        pending = {}, rubble = {}, resetting = nil, destroyed = false,
        dirty = true, publishedAt = -100, noticed = {},
        persistentEmitters = 0,
    }
    d.destroyConn = folder.Destroying:Connect(function()
        Destructibles.DestroyDistrict(d)
    end)
    districts[bay] = d
    return d
end

function Destructibles.Get(bay: Instance): any
    return districts[bay]
end

function Destructibles.Districts()
    return districts
end

function Destructibles.DestroyDistrict(d)
    if d.destroyed then
        return
    end
    d.destroyed = true
    if d.destroyConn then
        d.destroyConn:Disconnect()
        d.destroyConn = nil
    end
    for part, rec in pairs(partIndex) do
        if rec.district == d then
            partIndex[part] = nil
        end
    end
    d.objects, d.modules, d.vehicles, d.pending = {}, {}, {}, {}
    districts[d.bay] = nil
end

-- Effects ----------------------------------------------------------------------------------------------------------------
local function emit(d, event, important: boolean?)
    if important then
        Batch.Push(d.batch, event)
    else
        Batch.PushHit(d.batch, event)
    end
end
Destructibles.Emit = emit

function Destructibles.Notice(d, text: string, key: string?)
    if key then
        if d.noticed[key] then
            return
        end
        d.noticed[key] = true
    end
    emit(d, { t = "n", text = text }, true)
end

local function flush(d, now: number)
    local packet = Batch.Flush(d.batch, now)
    if not packet or not fxRemote then
        return
    end
    if d.owner and d.owner.Parent then
        fxRemote:FireClient(d.owner, packet)
    end
end

-- Registration -----------------------------------------------------------------------------------------------------------
local function newId(prefix: string): string
    nextId += 1
    return string.format("%s%03d", prefix, nextId)
end

function Destructibles.IndexPart(d, obj, comp: string?, part: BasePart)
    partIndex[part] = { district = d, obj = obj, comp = comp }
    obj.parts = obj.parts or {}
    table.insert(obj.parts, part)
end

function Destructibles.UnindexObject(obj)
    for _, part in ipairs(obj.parts or {}) do
        partIndex[part] = nil
    end
    obj.parts = {}
end

function Destructibles.RegisterObject(d, obj)
    table.insert(d.objects, obj)
end

-- Modules ----------------------------------------------------------------------------------------------------------------
-- spec: name, group, groupKind ("wall"|"barrier"|"container"|"machine"|"fence"|"column"|"roof"), size, cf, material (config
-- id), color, surface (Enum.Material), hp?, resist?, parent?, supports? ({module}), decor? (function(holder, part)),
-- rubble? (default by material), explosive? ({radius, damage}), wreck? (stay as a blackened hulk instead of vanishing),
-- label? (notice text when it is the first loss in its group), transparency?
function Destructibles.AddModule(d, spec)
    local def = assert(Config.materials[spec.material], "unknown material " .. tostring(spec.material))
    local part = Instance.new("Part")
    part.Name = spec.name
    part.Size = spec.size
    part.CFrame = spec.cf
    part.Anchored = true
    part.CanCollide, part.CanQuery, part.CanTouch = true, true, false
    part.Material = spec.surface or Enum.Material.Concrete
    part.Color = spec.color
    if spec.shape then
        part.Shape = spec.shape
    end
    part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    if spec.transparency then
        part.Transparency = spec.transparency
    end
    local id = newId("M")
    part:SetAttribute("DestructibleId", id)
    part:SetAttribute("DestructionMaterial", spec.material)
    part:SetAttribute("Stage", "INTACT")
    local root: Instance = part
    if spec.decor then
        local holder = Instance.new("Model")
        holder.Name = spec.name
        part.Parent = holder
        spec.decor(holder, part)
        root = holder
    end
    local obj = {
        kind = "module", id = id, name = spec.name, group = spec.group, groupKind = spec.groupKind or "prop",
        part = part, root = root, home = spec.parent or d.folder,
        unit = Unit.New({ material = spec.material, hp = spec.hp, resist = spec.resist }),
        def = def, cf = spec.cf, color = spec.color, surface = part.Material, transparency = part.Transparency,
        supports = spec.supports, dependents = {}, overlays = {}, emitters = {}, rubbleParts = {},
        destroyed = false, collapsePending = false, wreck = spec.wreck, explosive = spec.explosive,
        label = spec.label, lastOverlay = -100, rubbleWanted = if spec.rubble ~= nil then spec.rubble else (spec.material == "CONCRETE" or spec.material == "STRUCTURE"),
    }
    root.Parent = obj.home
    for _, support in ipairs(spec.supports or {}) do
        table.insert(support.dependents, obj)
    end
    Destructibles.IndexPart(d, obj, nil, part)
    table.insert(d.objects, obj)
    table.insert(d.modules, obj)
    d.totals.sections += 1
    if spec.group then
        local group = d.groups[spec.group]
        if not group then
            group = { name = spec.group, kind = obj.groupKind, count = 0, lost = 0, breached = false, label = spec.label }
            d.groups[spec.group] = group
            if obj.groupKind == "wall" then
                d.totals.walls += 1
            end
        end
        group.count += 1
        obj.groupRef = group
    end
    return obj
end

-- Visual variants -------------------------------------------------------------------------------------------------------
local function decal(obj, cf: CFrame, size: Vector3, color: Color3, shape: Enum.PartType?, material: Enum.Material?)
    local p = Instance.new("Part")
    p.Name = "Damage"
    p.Size = size
    p.CFrame = cf
    p.Anchored = true
    p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
    p.Material = material or Enum.Material.Slate
    p.Color = color
    if shape then
        p.Shape = shape
    end
    p.Parent = obj.part
    table.insert(obj.overlays, p)
    return p
end

-- Adds one surface damage mark where the module was struck (cracks, crater, scorch or pocks), bounded per module.
local function addOverlay(obj, position: Vector3, normal: Vector3, class: string)
    if #obj.overlays >= limits.overlayPerModule or os.clock() - obj.lastOverlay < 0.2 then
        return
    end
    obj.lastOverlay = os.clock()
    local fx = obj.def.fx
    local base = CFrame.lookAt(position + normal * 0.05, position + normal * 2)
    local spin = CFrame.Angles(0, 0, rng:NextNumber(0, math.pi))
    local dark = obj.color:Lerp(SOOT, 0.7)
    if class == "HEAVY" then
        local diameter = rng:NextNumber(2.4, 3.8)
        local crater = decal(obj, base * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(0.12, diameter, diameter), dark:Lerp(Color3.new(0, 0, 0), 0.4), Enum.PartType.Cylinder)
        crater.Name = "Crater"
        for _ = 1, 2 do
            decal(obj, base * CFrame.Angles(0, 0, rng:NextNumber(0, math.pi)) * CFrame.new(0, rng:NextNumber(1, 2), 0), Vector3.new(0.14, rng:NextNumber(2.5, 5), 0.1), SOOT).Name = "Crack"
        end
        if fx == "concrete" or fx == "structure" then
            local rebar = decal(obj, base * CFrame.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), 0.6) * CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0.3, 1.2), 0), Vector3.new(2.6, 0.18, 0.18), Color3.fromRGB(88, 54, 38), Enum.PartType.Cylinder, Enum.Material.Metal)
            rebar.Name = "Rebar"
        end
    elseif class == "LASER" then
        local diameter = rng:NextNumber(1.1, 1.9)
        decal(obj, base * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(0.1, diameter, diameter), Color3.fromRGB(14, 13, 12), Enum.PartType.Cylinder).Name = "Scorch"
        local ember = decal(obj, base * CFrame.Angles(0, math.pi / 2, 0) * CFrame.new(0.05, 0, 0), Vector3.new(0.06, diameter * 0.45, diameter * 0.45), Color3.fromRGB(255, 120, 40), Enum.PartType.Cylinder, Enum.Material.Neon)
        ember.Name = "ScorchGlow"
        ember.Transparency = 0.35
    else
        decal(obj, base * spin, Vector3.new(0.14, rng:NextNumber(1.6, 3.2), 0.08), SOOT).Name = "Crack"
        decal(obj, base * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(0.08, 0.55, 0.55), SOOT, Enum.PartType.Cylinder).Name = "Pock"
    end
end

local function smokeEmitter(parent: BasePart, rate: number, size: number, dark: number)
    local attachment = Instance.new("Attachment")
    attachment.Name = "SmokePoint"
    attachment.Position = Vector3.new(0, parent.Size.Y / 2, 0)
    attachment.Parent = parent
    local smoke = Instance.new("ParticleEmitter")
    smoke.Name = "WreckSmoke"
    smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
    smoke.Color = ColorSequence.new(Color3.fromRGB(60 - dark, 60 - dark, 62 - dark), Color3.fromRGB(110, 110, 112))
    smoke.Rate, smoke.Lifetime = rate, NumberRange.new(2.5, 4.5)
    smoke.Speed, smoke.SpreadAngle = NumberRange.new(4, 9), Vector2.new(14, 14)
    smoke.EmissionDirection = Enum.NormalId.Top
    smoke.Acceleration = Vector3.new(1.5, 2.5, 0)
    smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.4), NumberSequenceKeypoint.new(1, size * 1.8) })
    smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(0.7, 0.6), NumberSequenceKeypoint.new(1, 1) })
    smoke.RotSpeed = NumberRange.new(-30, 30)
    smoke.Parent = attachment
    return attachment
end
Destructibles.SmokeEmitter = smokeEmitter

local function fireEmitter(parent: BasePart, rate: number, size: number)
    local attachment = parent:FindFirstChild("SmokePoint") or Instance.new("Attachment")
    attachment.Name = "SmokePoint"
    attachment.Position = Vector3.new(0, parent.Size.Y / 2, 0)
    attachment.Parent = parent
    local fire = Instance.new("ParticleEmitter")
    fire.Name = "WreckFire"
    fire.Texture = "rbxasset://textures/particles/fire_main.dds"
    fire.Color = ColorSequence.new(Color3.fromRGB(255, 190, 90), Color3.fromRGB(220, 60, 20))
    fire.LightEmission, fire.Rate = 0.8, rate
    fire.Lifetime = NumberRange.new(0.6, 1.2)
    fire.Speed, fire.SpreadAngle = NumberRange.new(3, 7), Vector2.new(12, 12)
    fire.EmissionDirection = Enum.NormalId.Top
    fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
    fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
    fire.Parent = attachment
    return attachment
end
Destructibles.FireEmitter = fireEmitter

local function applyDamaged(d, obj, position: Vector3, normal: Vector3, class: string)
    local part = obj.part
    part.Color = obj.color:Lerp(SOOT, 0.22)
    part:SetAttribute("Stage", "DAMAGED")
    local fx = obj.def.fx
    if part.Material == Enum.Material.Glass then
        part.Transparency = 0.2 -- cracked, frosted glazing
        part.Color = obj.color:Lerp(Color3.fromRGB(210, 220, 225), 0.45)
    elseif fx == "panel" or fx == "metal" then
        -- The panel shifts on its fixings: a few degrees of tilt and a slight outward kick (real, tiny collision change).
        local axis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
        if axis.Magnitude < 0.1 then
            axis = ORIGIN_UP
        end
        part.CFrame = obj.cf * CFrame.fromAxisAngle(axis.Unit, math.rad(rng:NextNumber(2.5, 4.5))) * CFrame.new(0, 0, 0)
        part.Material = Enum.Material.CorrodedMetal
    elseif fx == "machine" then
        table.insert(obj.emitters, smokeEmitter(part, 4, 1.6, 20))
        d.persistentEmitters += 1
    end
    addOverlay(obj, position, normal, class)
end

local function groundBelow(d, position: Vector3): number
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { d.folder }
    local result = workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -120, 0), params)
    return result and result.Position.Y or d.origin.Y
end

local function spawnRubble(d, obj)
    if not obj.rubbleWanted then
        return
    end
    local size = obj.part.Size
    local ground = groundBelow(d, obj.part.Position)
    local count = if size.Magnitude > 14 then 3 else 2
    for _ = 1, count do
        if #d.rubble >= limits.rubbleParts then
            return
        end
        local chunk = Instance.new("Part")
        chunk.Name = "Rubble"
        local s = rng:NextNumber(1.2, 3.0)
        chunk.Size = Vector3.new(s * rng:NextNumber(0.8, 1.6), s * rng:NextNumber(0.5, 0.9), s * rng:NextNumber(0.8, 1.6))
        chunk.CFrame = CFrame.new(obj.part.Position.X + rng:NextNumber(-size.X * 0.4, size.X * 0.4) * (if size.X < 14 then 1 else 0.5),
            ground + chunk.Size.Y / 2 - 0.05, obj.part.Position.Z + rng:NextNumber(-size.Z * 0.4, size.Z * 0.4) * (if size.Z < 14 then 1 else 0.5))
            * CFrame.Angles(rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, math.pi), rng:NextNumber(-0.25, 0.25))
        chunk.Anchored = true
        chunk.CanCollide, chunk.CanQuery, chunk.CanTouch, chunk.CastShadow = false, false, false, false
        chunk.Material = obj.surface
        chunk.Color = obj.color:Lerp(SOOT, 0.35)
        chunk.Parent = d.folder
        table.insert(d.rubble, chunk)
        table.insert(obj.rubbleParts, chunk)
    end
end

local function now(): number
    return os.clock()
end

local function scheduleCollapse(d, obj, delay: number)
    if obj.destroyed or obj.collapsePending then
        return
    end
    obj.collapsePending = true
    table.insert(d.pending, { at = now() + delay, kind = "collapse", obj = obj })
end

local function destroyModule(d, obj, cause: string, position: Vector3?)
    if obj.destroyed then
        return
    end
    obj.destroyed = true
    obj.collapsePending = false
    local part = obj.part
    local def = obj.def
    local size, cf = part.Size, part.CFrame
    d.dirty = true
    d.stats.sectionsDestroyed += 1
    if obj.groupRef then
        obj.groupRef.lost += 1
        local group = obj.groupRef
        if group.kind == "wall" and not group.breached then
            group.breached = true
            d.stats.wallsBreached += 1
            Destructibles.Notice(d, string.format("%s - %s", string.upper(group.label or group.name), "WALL BREACHED"), "breach:" .. group.name)
        elseif group.kind == "barrier" then
            Destructibles.Notice(d, string.format("%s - %s", string.upper(group.label or group.name), "SECTION " .. def.final), "break:" .. group.name .. group.lost)
        elseif cause == "COLLAPSE" then
            Destructibles.Notice(d, string.upper(group.label or group.name) .. " - PARTIAL COLLAPSE", "collapse:" .. group.name)
        elseif group.kind == "machine" then
            Destructibles.Notice(d, string.upper(group.label or group.name) .. " - DISABLED", "machine:" .. obj.id)
        end
    end
    if cause == "COLLAPSE" then
        d.stats.collapses += 1
    end
    local volume = size.X * size.Y * size.Z
    local power = math.clamp(volume ^ (1 / 3) / 4.5, 0.5, 3.2)
    for _, overlay in ipairs(obj.overlays) do
        overlay:Destroy()
    end
    obj.overlays = {}
    if obj.wreck then
        -- Machinery stays as a blackened, smoking hulk (collision unchanged), with a burst of electrical/mechanical failure.
        part.Color = SOOT:Lerp(obj.color, 0.12)
        part.Material = Enum.Material.CorrodedMetal
        part:SetAttribute("Stage", "DESTROYED")
        for _, e in ipairs(obj.emitters) do
            e:Destroy()
        end
        obj.emitters = { smokeEmitter(part, 9, 3 * power, 24) }
        d.persistentEmitters += 1
        emit(d, { t = "x", f = def.fx, k = "wreck", cf = cf, s = size, c = obj.color, mat = obj.surface, e = power }, true)
    else
        part:SetAttribute("Stage", "DESTROYED")
        obj.root.Parent = nil -- authoritative: collision and line of sight are gone with the part
        emit(d, { t = "x", f = def.fx, k = if cause == "COLLAPSE" then "collapse" else "break", cf = cf, s = size, c = obj.color, mat = obj.surface, e = power, v = position }, true)
        spawnRubble(d, obj)
    end
    if obj.explosive then
        table.insert(d.pending, { at = now() + rng:NextNumber(0.12, 0.3), kind = "blast", pos = part.Position, radius = obj.explosive.radius, damage = obj.explosive.damage, source = obj })
        emit(d, { t = "x", f = "machine", k = "explosion", cf = cf, s = size, c = obj.color, mat = obj.surface, e = power * 1.6 }, true)
    end
    for _, dependent in ipairs(obj.dependents) do
        if not dependent.destroyed then
            scheduleCollapse(d, dependent, rng:NextNumber(limits.collapseDelayMin, limits.collapseDelayMax))
        end
    end
end

-- Damage ---------------------------------------------------------------------------------------------------------------
local function closestDistance(part: BasePart, point: Vector3): number
    local rel = part.CFrame:PointToObjectSpace(point)
    local half = part.Size / 2
    local clamped = Vector3.new(math.clamp(rel.X, -half.X, half.X), math.clamp(rel.Y, -half.Y, half.Y), math.clamp(rel.Z, -half.Z, half.Z))
    return (rel - clamped).Magnitude
end

local function damageModule(d, obj, class: string, raw: number, scale: number?, position: Vector3, normal: Vector3): number
    if obj.destroyed then
        return 0
    end
    local dealt, old, new = Unit.Hit(obj.unit, class, raw, scale)
    if dealt <= 0 then
        return 0
    end
    if new == "DESTROYED" then
        destroyModule(d, obj, "DAMAGE", position)
    elseif old == "INTACT" and new == "DAMAGED" then
        applyDamaged(d, obj, position, normal, class)
        emit(d, { t = "s", f = obj.def.fx, p = position, n = normal, w = class, e = 1 }, true)
    elseif new == "DAMAGED" or class ~= "MG" then
        addOverlay(obj, position, normal, class)
    end
    return dealt
end

-- Area blast on STRUCTURAL modules only (never vehicles, mechs, pilots or capsules). Returns the modules touched.
local function blast(d, position: Vector3, radius: number, raw: number, fraction: number, maxTargets: number, skip)
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { d.folder }
    local seen, ranked = {}, {}
    for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, params)) do
        local rec = partIndex[part]
        if rec and rec.district == d and rec.obj.kind == "module" and rec.obj ~= skip and not seen[rec.obj] and rec.obj.def.splash and not rec.obj.destroyed then
            seen[rec.obj] = true
            table.insert(ranked, { obj = rec.obj, distance = closestDistance(part, position) })
        end
    end
    table.sort(ranked, function(a, b) return a.distance < b.distance end)
    local total = 0
    for i = 1, math.min(#ranked, maxTargets) do
        local entry = ranked[i]
        local falloff = math.clamp(1 - entry.distance / radius, 0.15, 1)
        local toward = (entry.obj.part.Position - position)
        local normal = if toward.Magnitude > 0.01 then -toward.Unit else ORIGIN_UP
        total += damageModule(d, entry.obj, "HEAVY", raw, fraction * falloff, position, normal)
    end
    return total, #ranked
end

local function damageComponent(d, obj, comp: string, class: string, raw: number, position: Vector3, normal: Vector3): number
    local component = obj.comps[comp]
    if not component then
        return 0
    end
    local dealt, old, new = Unit.Hit(component.unit, class, raw)
    if dealt <= 0 then
        return 0
    end
    d.dirty = true
    if old ~= new and obj.onStage then
        obj.onStage(d, obj, comp, old, new, position, normal, class)
    end
    return dealt
end

-- Entry point from CombatTargets.Hit. context = { weapon = componentId, position, normal }. Returns effective damage dealt
-- (0 when the part is not a destructible, is protected, or the weapon has no structural class).
function Destructibles.Hit(part: BasePart, category: string, damage: number, _now: number, context: any): number
    local rec = partIndex[part]
    if not rec then
        return 0
    end
    local d, obj = rec.district, rec.obj
    if d.destroyed or d.resetting or part:GetAttribute("Targetable") == false then
        return 0
    end
    local class = Config.WeaponClass(context and context.weapon, category, damage)
    if not class or damage ~= damage or damage <= 0 then
        return 0
    end
    local position = context and context.position or part.Position
    local normal = context and context.normal or ORIGIN_UP
    local dealt
    if obj.kind == "module" then
        dealt = damageModule(d, obj, class, damage, nil, position, normal)
    else
        dealt = damageComponent(d, obj, rec.comp, class, damage, position, normal)
    end
    if dealt <= 0 then
        return 0
    end
    if obj.onHit then
        obj.onHit(d, obj, rec.comp, position, normal, class)
    end
    local stats = d.stats
    stats.damage += dealt
    stats.hits += 1
    stats.byClass[class] += dealt
    d.dirty = true
    local fx = if obj.kind == "module" then obj.def.fx else Config.materials[obj.comps[rec.comp].unit.material].fx
    emit(d, { t = "h", f = fx, w = class, p = position, n = normal, m = math.floor(dealt * 10) / 10 })
    local splash = Config.splash[class]
    if splash then
        local total = blast(d, position, splash.radius, damage, splash.fraction, splash.maxTargets, if obj.kind == "module" then obj else nil)
        if total > 0 then
            stats.damage += total
            stats.byClass[class] += total
        end
    end
    return dealt
end

-- Per-frame --------------------------------------------------------------------------------------------------------------
local function runPending(d, t: number)
    if #d.pending == 0 then
        return
    end
    local due, keep = {}, {}
    for _, item in ipairs(d.pending) do
        if item.at <= t then
            table.insert(due, item)
        else
            table.insert(keep, item)
        end
    end
    d.pending = keep
    for _, item in ipairs(due) do
        if item.kind == "collapse" then
            if not item.obj.destroyed then
                Unit.Destroy(item.obj.unit) -- structural collapse is not weapon damage: it never counts as damage inflicted
                destroyModule(d, item.obj, "COLLAPSE", nil)
            end
        elseif item.kind == "blast" then
            blast(d, item.pos, item.radius, item.damage, 1, 14, item.source)
        end
    end
end

local function publish(d, t: number)
    if not d.dirty or t - d.publishedAt < limits.statsInterval then
        return
    end
    d.dirty = false
    d.publishedAt = t
    local s, folder = d.stats, d.folder
    local function set(name: string, value: any)
        if folder:GetAttribute(name) ~= value then
            folder:SetAttribute(name, value)
        end
    end
    set("StatDamage", math.floor(s.damage))
    set("StatDamageMG", math.floor(s.byClass.MG))
    set("StatDamageLR", math.floor(s.byClass.LASER))
    set("StatDamageHMG", math.floor(s.byClass.HEAVY))
    set("StatHits", s.hits)
    set("StatTargetsDisabled", s.targetsDisabled)
    set("StatTargetsTotal", d.totals.targets)
    set("StatVehiclesDestroyed", s.vehiclesDestroyed)
    set("StatVehiclesTotal", d.totals.vehicles)
    set("StatComponentsLost", s.componentsLost)
    set("StatSections", s.sectionsDestroyed)
    set("StatSectionsTotal", d.totals.sections)
    set("StatWallsBreached", s.wallsBreached)
    set("StatWallsTotal", d.totals.walls)
    set("StatCollapses", s.collapses)
    set("StatResets", s.resets)
    set("StatResetting", d.resetting ~= nil)
end

-- Reset ------------------------------------------------------------------------------------------------------------------
local function restoreModule(d, obj)
    for _, overlay in ipairs(obj.overlays) do
        overlay:Destroy()
    end
    obj.overlays = {}
    for _, e in ipairs(obj.emitters) do
        e:Destroy()
    end
    obj.emitters = {}
    obj.rubbleParts = {}
    Unit.Reset(obj.unit)
    obj.destroyed, obj.collapsePending, obj.lastOverlay = false, false, -100
    local part = obj.part
    part.CFrame = obj.cf
    part.Color = obj.color
    part.Material = obj.surface
    part.Transparency = obj.transparency
    part:SetAttribute("Stage", "INTACT")
    if obj.root.Parent ~= obj.home then
        obj.root.Parent = obj.home
    end
end

local function clearRubble(d)
    for _, chunk in ipairs(d.rubble) do
        chunk:Destroy()
    end
    d.rubble = {}
end

-- kind: "ALL" | "VEHICLES" | "STRUCTURES". Work is spread over several heartbeats; hits are ignored meanwhile.
function Destructibles.Reset(d, kind: string): boolean
    if d.destroyed or d.resetting then
        return false
    end
    if kind ~= "ALL" and kind ~= "VEHICLES" and kind ~= "STRUCTURES" then
        return false
    end
    local queue = {}
    if kind ~= "VEHICLES" then
        for _, obj in ipairs(d.modules) do
            table.insert(queue, obj)
        end
        clearRubble(d)
        d.pending = {}
        d.noticed = {}
        for _, group in pairs(d.groups) do
            group.lost, group.breached = 0, false
        end
    end
    if kind ~= "STRUCTURES" then
        for _, obj in ipairs(d.vehicles) do
            table.insert(queue, obj)
        end
        if d.mech then
            table.insert(queue, d.mech)
        end
    end
    d.resetting = { kind = kind, queue = queue, index = 1 }
    Batch.Clear(d.batch)
    emit(d, { t = "c" }, true)
    d.dirty = true
    return true
end

local function stepReset(d)
    local r = d.resetting
    if not r then
        return
    end
    local budget = limits.resetChunk
    while r.index <= #r.queue and budget > 0 do
        local obj = r.queue[r.index]
        r.index += 1
        if obj.kind == "module" then
            restoreModule(d, obj)
            budget -= 1
        else
            obj.respawn(d, obj)
            budget = 0 -- a rebuilt machine (4-13 ms) gets a frame to itself so resets never stack several rebuilds
        end
    end
    if r.index > #r.queue then
        d.resetting = nil
        local s = d.stats
        s.resets += 1
        if r.kind == "ALL" then
            local resets = s.resets
            d.stats = newStats()
            d.stats.resets = resets
            d.noticed = {}
        elseif r.kind == "STRUCTURES" then
            s.sectionsDestroyed, s.wallsBreached, s.collapses = 0, 0, 0
            d.noticed = {}
        else
            s.targetsDisabled, s.vehiclesDestroyed, s.componentsLost = 0, 0, 0
        end
        d.dirty = true
        Destructibles.Notice(d, if r.kind == "ALL" then "RANGE RESET COMPLETE - ALL TARGETS RESTORED" elseif r.kind == "VEHICLES" then "VEHICLES REPAIRED AND RESPAWNED" else "STRUCTURES RESTORED", nil)
    end
end

Destructibles.stats = { stepMs = 0, worstMs = 0, steps = 0 }

function Destructibles.Step(t: number, dt: number)
    local started = os.clock()
    for _, d in pairs(districts) do
        if not d.destroyed then
            runPending(d, t)
            stepReset(d)
            for _, vehicle in ipairs(d.vehicles) do
                if vehicle.update then
                    vehicle.update(d, vehicle, dt, t)
                end
            end
            if d.mech and d.mech.update then
                d.mech.update(d, d.mech, dt, t)
            end
            flush(d, t)
            publish(d, t)
        end
    end
    local ms = (os.clock() - started) * 1000
    local stats = Destructibles.stats
    stats.stepMs += (ms - stats.stepMs) * 0.05
    stats.worstMs = math.max(stats.worstMs, ms)
    stats.steps += 1
end

-- Diagnostics (tests and reports) --------------------------------------------------------------------------------------
function Destructibles.Audit(d)
    local instances = #d.folder:GetDescendants()
    local indexed = 0
    for _, rec in pairs(partIndex) do
        if rec.district == d then
            indexed += 1
        end
    end
    local overlays, emitters = 0, 0
    for _, obj in ipairs(d.modules) do
        overlays += #obj.overlays
        emitters += #obj.emitters
    end
    local totalIndexed = 0
    for _ in pairs(partIndex) do
        totalIndexed += 1
    end
    return {
        instances = instances, indexed = indexed, modules = #d.modules, vehicles = #d.vehicles, rubble = #d.rubble,
        overlays = overlays, moduleEmitters = emitters, pending = #d.pending, resetting = d.resetting ~= nil,
        batchDropped = d.batch.dropped, batchSent = d.batch.sent, batchPackets = d.batch.packets,
        totalIndexed = totalIndexed,
    }
end

-- Counts one more component loss / vehicle stat; builders call these on stage transitions.
function Destructibles.NoteComponentLost(d)
    d.stats.componentsLost += 1
    d.dirty = true
end

function Destructibles.NoteTargetDisabled(d, isVehicle: boolean)
    d.stats.targetsDisabled += 1
    if isVehicle then
        d.stats.vehiclesDestroyed += 1
    end
    d.dirty = true
end

Destructibles.Blast = blast

return Destructibles
