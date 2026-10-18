-- Server runner for autonomous mechs (M10C): ROOK-01.
--
-- ROOK is the existing IF-42 Bastion rig (MechFactory / BastionBuilder, ROOK palette and sensor module) driven by the SAME machinery
-- as the player's mech - nothing here is a parallel enemy-only system:
--
--   locomotion   Locomotion.Create / Step: the authoritative hull Part, MechDrive acceleration + jerk + turn limits, the ground and
--                swept-hull probes. Clients pose the rig (ShowroomAnimator + MechGait) around the replicated hull, so ROOK walks with
--                the Bastion's gait and footfalls; the server never moves a rig part.
--   energy       EnergySystems.Create / Step: the same reactor, capacitor, thermal ledger, profiles (MOBILITY / BALANCED / WEAPONS) and
--                pulse shield as the player. Movement, shield and laser charging draw from it; every round is paid from it.
--   weapons      WeaponState: the shared magazine / reload / cooldown / payment rules on the real MG-9 and LR-12 components. Muzzle
--                geometry is the player's (Rig.Solve + Geometry.Mount). Rounds are swept projectiles owned by TankCombat's bolt manager
--                (world hits through Destructibles.Hit, player hits through the pulse shield and BastionDamage), never instant hits.
--   damage       MechDamage / BastionDamage: six regions with the Bastion's consequences. Hits arrive through Destructibles.Hit on tight
--                fitted compound hit volumes (MechHit / VolumeHit), then the P-01 shield, then armour, then the region.
--   brain        MechBrain (pure) decides; this file measures the senses and carries out the orders.
--
-- Pilot safety: the only valid target is the one TankCombat.TargetOf returns (deployed, operational, in the district, core intact).
-- Ejected pilots, escape capsules and docked mechs are never targets and cancel every bolt in flight.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Config = require(Shared:WaitForChild("EnemyConfig"))
local Brain = require(Shared:WaitForChild("MechBrain"))
local Nav = require(Shared:WaitForChild("MechNav"))
local Loadouts = require(Shared:WaitForChild("Loadouts"))
local Compiler = require(Shared:WaitForChild("LoadoutCompiler"))
local Components = require(Shared:WaitForChild("ComponentRegistry"))
local WeaponState = require(Shared:WaitForChild("WeaponState"))
local MechRig = require(Shared:WaitForChild("MechRig"))
local Geometry = require(Shared:WaitForChild("WeaponGeometry"))
local Energy = require(Shared:WaitForChild("Energy"))
local Damage = require(Shared:WaitForChild("MechDamage"))
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local Math = require(Shared:WaitForChild("CombatMath"))
local Factory = require(script.Parent.MechFactory)
local Locomotion = require(script.Parent.Locomotion)
local EnergySystems = require(script.Parent.EnergySystems)
local BastionDamage = require(script.Parent.BastionDamage)
local Destructibles = require(script.Parent.Destructibles)
local MechHit = require(script.Parent.MechHit) -- M11B

local EnemyMech = {}

local V3, CF, ANG = Vector3.new, CFrame.new, CFrame.Angles
local SAMPLE_HEIGHTS = CombatConfig.sampleHeights -- the same aim samples on the Bastion that tank crews use
local SENSOR_HEIGHT = 19 -- ROOK's sensor module above its ground point
local GUN_HEIGHT = 12.5 -- the arm weapons
local CLEAR_LOOKAHEAD = 26
local WHISKER_ANGLE = math.rad(32)

EnemyMech.stats = { stepMs = 0, worstMs = 0, steps = 0, losRays = 0, casts = 0 }

local env: { spawnBolt: (any, any) -> any?, weaponFx: RemoteEvent?, cancelBolts: ((any, any) -> ())?, onDown: ((any, string) -> ())? } = { spawnBolt = nil :: any }

function EnemyMech.Init(options)
    env = options
end

-- Hit volumes -----------------------------------------------------------------------------------------------------------------
-- M11B: fitted, not placed. MechHit.Build turns every armour / frame / joint / reactor / weapon part of the built rig into one oriented box in the
-- chassis frame (rest pose), classified into the damage region the rest of the game uses. The M10C hand-placed boxes (18) were 1-2 studs off the
-- drawn armour on average and up to 6 away; the fitted set follows the visible parts (see docs/M11B_PHYSICAL_COMBAT_FIDELITY.md). The volumes are plain
-- tables carried with the chassis: no parts exist, nothing replicates when ROOK moves, and weapons reach them through Destructibles.Probe.

local HIT_FX = { CORE = "metal", ARM_L = "machine", ARM_R = "machine", LEG_L = "machine", LEG_R = "machine", REACTOR = "machine" }
local REGION_NAME = CombatConfig.mech.names

-- Small helpers ---------------------------------------------------------------------------------------------------------------
local function flat(ax: number, az: number, bx: number, bz: number): number
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

local function setAttr(rook, instance: Instance, name: string, value: any)
    local cache = rook.attrCache
    local key = instance == rook.model and name or (tostring(instance) .. name)
    if cache[key] ~= value then
        cache[key] = value
        instance:SetAttribute(name, value)
    end
end

local function round1(n: number): number
    return math.floor(n * 10 + 0.5) / 10
end

local function characters(): { Instance }
    local list = {}
    local mechs = workspace:FindFirstChild("IronframeMechs")
    if mechs then
        table.insert(list, mechs)
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            table.insert(list, player.Character)
        end
    end
    return list
end

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.IgnoreWater = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshFilters()
    local list = characters()
    sightParams.FilterDescendantsInstances = list
    castParams.FilterDescendantsInstances = list
    overlapParams.FilterDescendantsInstances = list
end

local function groundHeight(position: Vector3): number
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = characters()
    local hit = workspace:Raycast(position + V3(0, 30, 0), V3(0, -80, 0), params)
    return hit and hit.Position.Y or position.Y
end

-- World queries ---------------------------------------------------------------------------------------------------------------
local function hullCF(rook, x: number, z: number, yaw: number): CFrame
    local h = rook.controller.params.hull
    return CF(x, rook.groundY + h.offsetY, z) * ANG(0, yaw, 0) * CF(h.offsetX, 0, h.offsetZ)
end

local function hullSize(rook, shrink: number): Vector3
    local h = rook.controller.params.hull
    return V3(h.width - shrink, h.height - shrink, h.depth - shrink)
end

local function hullBlockedAt(rook, x: number, z: number): boolean
    EnemyMech.stats.casts += 1
    for _, part in ipairs(workspace:GetPartBoundsInBox(hullCF(rook, x, z, 0), hullSize(rook, 0.3), overlapParams)) do
        if part.CanQuery then
            return true
        end
    end
    return false
end

-- Swept hull test between two ground points (the same Blockcast the drive probe uses).
local function segmentClear(rook, x1: number, z1: number, x2: number, z2: number): boolean
    local dx, dz = x2 - x1, z2 - z1
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.1 then
        return true
    end
    EnemyMech.stats.casts += 1
    local cf = hullCF(rook, x1, z1, Nav.yawTo(x1, z1, x2, z2))
    return workspace:Blockcast(cf, hullSize(rook, 0.6), V3(dx, 0, dz), castParams) == nil
end

-- Free distance along a heading from the current pose (capped at CLEAR_LOOKAHEAD).
local function freeDistance(rook, yawOffset: number, direction: number): number
    local s = rook.controller.state
    local yaw = s.yaw + yawOffset
    local hx, hz = -math.sin(yaw), -math.cos(yaw)
    EnemyMech.stats.casts += 1
    local hit = workspace:Blockcast(hullCF(rook, s.x, s.z, s.yaw), hullSize(rook, 0.6), V3(hx * direction, 0, hz * direction) * CLEAR_LOOKAHEAD, castParams)
    return if hit then math.max(0, hit.Distance - Locomotion.SKIN) else CLEAR_LOOKAHEAD
end

local function lineOfSight(from: Vector3, to: Vector3): boolean
    EnemyMech.stats.losRays += 1
    return workspace:Raycast(from, to - from, sightParams) == nil
end

-- Construction ----------------------------------------------------------------------------------------------------------------
local function weather(model: Model, rng: Random)
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part:GetAttribute("Group") == "armor" and part.Name ~= "RigRoot" then
            local dust = Color3.fromRGB(72, 66, 58)
            part.Color = part.Color:Lerp(dust, rng:NextNumber(0.02, 0.2))
            if not string.find(part.Name, "^Rook") and rng:NextNumber() < 0.4 then
                part.Material = Enum.Material.Metal -- bare, worn steel showing through the paint
            end
        end
    end
end

local function buildVolumes(rook)
    rook.volumes = MechHit.Build(rook.model)
    -- A weapon ray / shell asks for the nearest fitted-volume contact along its path (see Destructibles.Probe).
    Destructibles.SetProbe(rook, function(origin: Vector3, direction: Vector3, maxT: number, inflate: number?)
        if not rook.model.Parent then
            return nil
        end
        return MechHit.Ray(rook.volumes, Locomotion.ChassisCFrame(rook.controller), origin, direction, maxT, inflate)
    end)
end

-- World position of the middle of the largest volume of `region` (audit and test equipment: where to aim at a given region).
function EnemyMech.RegionPoint(rook, region: string): Vector3?
    local best, bestVolume = nil, -1
    for _, box in ipairs(MechHit.Boxes(rook.volumes)) do
        if box.region == region then
            local v = box.size.X * box.size.Y * box.size.Z
            if v > bestVolume then
                best, bestVolume = box, v
            end
        end
    end
    if not best then
        return nil
    end
    return Locomotion.ChassisCFrame(rook.controller) * best.cf.Position
end

local function validateLattice(rook)
    local def = rook.def
    rook.nodes = Nav.BuildNodes(def.court, def.station, rook.district.origin.X, rook.district.origin.Z)
    refreshFilters()
    for _, node in ipairs(rook.nodes) do
        node.valid = node.station or not hullBlockedAt(rook, node.x, node.z)
    end
    rook.graph = Nav.BuildGraph(rook.nodes, def.court.edgeReach, function(a, b)
        return segmentClear(rook, a.x, a.z, b.x, b.z)
    end)
    rook.latticeAt = os.clock()
end

local function build(d, rook)
    local def = rook.def
    local loadout = Loadouts.enemy[def.presetId]
    local compiled = Compiler.Compile(loadout)
    assert(compiled.valid, "ROOK loadout invalid: " .. table.concat(compiled.issues, "; "))
    rook.district = d
    local station = V3(d.origin.X + def.station.x, 0, d.origin.Z + def.station.z)
    station = V3(station.X, groundHeight(station), station.Z)
    rook.groundY = station.Y
    local model = Factory.Create(0, def.presetId, loadout, station, { useAssets = false })
    model.Name = def.callsign
    model:SetAttribute("OwnerUserId", nil)
    model:SetAttribute("PilotTargetable", nil)
    model:SetAttribute("EnemyId", def.id)
    model:SetAttribute("Callsign", def.callsign)
    model:SetAttribute("Unmanned", true)
    model:SetAttribute("Autonomous", true)
    model:SetAttribute("State", "OPERATIONAL")
    model:SetAttribute("Deployment", "ACTIVE") -- the client weapon / shield presentation keys on it
    model:SetAttribute("Deployed", true)
    model:SetAttribute("AiState", "IDLE")
    model:SetAttribute("AiType", nil)
    weather(model, Random.new(def.callsign:byte(1) * 131 + 7))
    rook.model = model
    rook.attrCache = {}
    rook.districtCache = {}

    local controller = Locomotion.Create(model, def.chassisId, station, def.station.yaw)
    controller.hull.CanQuery = false -- weapons hit the region volumes, never a box around the whole machine
    Locomotion.SetLocked(controller, true)
    rook.controller = controller

    local power = EnergySystems.Create(model, compiled.energy, def.startProfile)
    controller.energySystems = power
    rook.power = power

    rook.weapons = WeaponState.New(loadout.mounts, Components)
    rook.weapons.selected, rook.weapons.reason = 1, "SAFE"

    -- The damage unit shares BastionDamage's adapter: a session-shaped table.
    local unit = {
        mech = model, controller = controller, power = power, machineState = "OPERATIONAL", damageCapacity = def.structure.regions,
        onCoreFailure = function()
            EnemyMech.Disable(d, rook, "CORE FAILURE", true)
        end,
    }
    BastionDamage.Create(unit)
    BastionDamage.Apply(unit)
    rook.unit = unit

    rook.brain = Brain.New(def, Brain.Rng(rook.seed))
    rook.rng = Random.new(rook.seed + 11)
    rook.progress = Nav.NewProgress()
    rook.turnBlockedFor = 0
    rook.live, rook.homing, rook.down, rook.downReason = false, false, false, nil
    rook.losAt, rook.losClear, rook.losSample = -10, false, 1
    rook.memory = { pos = nil, vel = Vector3.zero, at = -math.huge, exact = false }
    rook.goal, rook.route, rook.arrived, rook.noPath, rook.noPathAt = nil, nil, false, false, -10
    rook.recent = {}
    rook.clear = { ahead = CLEAR_LOOKAHEAD, left = CLEAR_LOOKAHEAD, right = CLEAR_LOOKAHEAD, at = -10 }
    rook.aim = nil
    rook.lockedAim = nil
    rook.attackSocket = nil
    rook.lastHitAt, rook.lastHitFrom = -100, nil
    rook.hitSerial = 0
    rook.lastProfileAsk = -10
    rook.published = -10
    rook.counters = { MG = 0, LR = 0, hitsTaken = 0, shields = 0, stuck = 0, repicks = 0, rounds = 0 }
    rook.lastAttack = nil
    rook.status = "STANDBY"

    buildVolumes(rook)
    model.Parent = workspace:FindFirstChild("IronframeMechs") or workspace
    validateLattice(rook)
    EnergySystems.Publish(power, true)
    setAttr(rook, model, "RookStatus", rook.status)
    rook.district.folder:SetAttribute("RookStatus", rook.status)
end

function EnemyMech.Create(d, spec)
    local def = assert(Config.enemies[spec.enemyId or Config.defaultEnemy])
    local rook = {
        kind = "robot", id = def.callsign, def = def, parts = {}, seed = spec.seed or 1010,
        takeHit = EnemyMech.TakeHit, hitFx = function(region: string) return HIT_FX[region] or "machine" end,
        respawn = EnemyMech.Respawn,
    }
    d.rook = rook
    table.insert(d.objects, rook)
    d.totals.targets += 1
    build(d, rook)
    return rook
end

function EnemyMech.Respawn(d, rook)
    Destructibles.UnindexObject(rook)
    if rook.model then
        rook.model:Destroy()
    end
    build(d, rook)
end

-- Hits on ROOK (called by Destructibles.Hit for a registered hit volume) ----------------------------------------------------------
-- Order: shield (the real P-01, directional) -> armour by region and weapon class -> the region -> consequences.
function EnemyMech.TakeHit(d, rook, region: string, class: string, raw: number, position: Vector3, normal: Vector3, context: any?, weaponCategory: string?): number
    if rook.down or d.resetting then
        return 0
    end
    local def = rook.def
    local category = weaponCategory or (if class == "LASER" then "laser" else "ballistic")
    local origin = context and context.origin
    local ax, az
    if origin then
        ax, az = origin.X - position.X, origin.Z - position.Z
    else
        ax, az = normal.X, normal.Z
    end
    if ax * ax + az * az < 1e-6 then
        ax, az = 0, -1
    end
    local result = EnergySystems.ResolveImpact(rook.power, { category = category, damage = raw, fromX = ax, fromZ = az }, rook.controller.state.yaw)
    local penetrating = if result then result.penetrating else raw
    -- What the client needs to draw the interaction: the shield timing and where the path crossed the shield plane (outside the hull).
    rook.lastShot = { timing = if result then result.timing else "UNGUARDED", pen = penetrating, sp = nil }
    if result and result.prevented > 0 and origin then
        rook.lastShot.sp = MechHit.ShieldPoint(Locomotion.ChassisCFrame(rook.controller), position, (position - origin).Unit)
    end
    local armour = def.structure.resist[region][class] or 1
    local amount = penetrating * armour
    rook.counters.hitsTaken += 1
    rook.lastHitAt = os.clock()
    rook.lastHitFrom = origin or (position + V3(ax, 0, az).Unit * 40)
    rook.hitSerial += 1
    local model = rook.model
    setAttr(rook, model, "LastHitRegion", region)
    setAttr(rook, model, "LastHitTiming", if result then result.timing else "UNGUARDED")
    setAttr(rook, model, "HitSerial", rook.hitSerial)
    if amount <= 0 then
        return 0
    end
    local before = rook.unit.damage and table.clone(rook.unit.damage.health)
    local outcome = BastionDamage.Hit(rook.unit, region, amount)
    if outcome and before then
        for r, stage in pairs(outcome.stageChanged) do
            if r ~= "CORE" or stage ~= "FAILED" then
                local label = REGION_NAME[r] or r
                if stage == "FAILED" then
                    Destructibles.NoteComponentLost(d)
                    Destructibles.MechFailure(d, r, EnemyMech.RegionPoint(rook, r) or position)
                    Destructibles.Notice(d, string.format("%s %s DESTROYED", def.callsign, label), nil)
                elseif stage == "CRITICAL" then
                    Destructibles.Notice(d, string.format("%s %s CRITICAL", def.callsign, label), nil)
                end
            end
        end
    end
    return amount
end

-- Disabled ----------------------------------------------------------------------------------------------------------------------
-- Terminal until the next reset: the drive is locked (it brakes hard), power is cancelled, weapons are safed. A core failure also
-- slumps the machine (client pose keyed on `Wreck`) and smokes; losing both weapon assemblies leaves it standing, neutralised.
function EnemyMech.Disable(d, rook, reason: string, wreck: boolean)
    if rook.down then
        return
    end
    rook.down, rook.downReason, rook.live, rook.homing = true, reason, false, false
    if env.onDown then
        env.onDown(d, reason)
    end
    rook.status = if wreck then "DISABLED" else "NEUTRALIZED"
    local model = rook.model
    Locomotion.SetLocked(rook.controller, true)
    EnergySystems.Cancel(rook.power)
    if env.cancelBolts then
        env.cancelBolts(d, rook)
    end
    rook.attackSocket, rook.lockedAim, rook.aim = nil, nil, nil
    setAttr(rook, model, "WeaponAim", nil)
    setAttr(rook, model, "WeaponState", "SAFE")
    setAttr(rook, model, "AiState", "DISABLED")
    setAttr(rook, model, "AiAttack", "")
    setAttr(rook, model, "RookStatus", rook.status)
    setAttr(rook, model, "DownReason", reason)
    setAttr(rook, model, "Disabled", true)
    if wreck then
        setAttr(rook, model, "Wreck", workspace:GetServerTimeNow())
        local core = rook.controller.hull -- the chassis carrier part: effects stay with the machine wherever it stands
        if core then
            Destructibles.SmokeEmitter(core, 14, 4, 26)
            Destructibles.FireEmitter(core, 10, 2.4)
            Destructibles.Emit(d, { t = "x", f = "machine", k = "explosion", cf = core.CFrame, s = core.Size, c = Color3.fromRGB(70, 70, 70), mat = Enum.Material.Metal, e = 2.6 }, true)
        end
        Destructibles.NoteTargetDisabled(d, false)
    else
        Destructibles.NoteTargetDisabled(d, false)
    end
    Destructibles.Notice(d, string.format("%s %s - %s", rook.def.callsign, rook.status, reason), nil)
    d.folder:SetAttribute("RookStatus", rook.status)
end

-- Perception -------------------------------------------------------------------------------------------------------------------
local function sample(rook, target, now: number): ({ [string]: any }, Vector3?)
    local p = rook.def.perception
    local state = rook.controller.state
    local mem = rook.memory
    local seen, heard, lane = false, false, false
    local hasTarget = target ~= nil
    local range, bearing = math.huge, 0
    local estimate: Vector3? = nil
    if target then
        local dx, dz = target.position.X - state.x, target.position.Z - state.z
        local actual = math.sqrt(dx * dx + dz * dz)
        local actualBearing = math.rad(Math.relativeBearing(state.yaw, dx, dz))
        local inSight = actual <= p.sightRange and (actual <= p.proximity or math.abs(actualBearing) <= p.sightHalfArc)
        if inSight and now - rook.losAt >= p.losInterval then
            rook.losAt = now
            local from = V3(state.x, rook.groundY + SENSOR_HEIGHT, state.z)
            rook.losClear = false
            for i, h in ipairs(SAMPLE_HEIGHTS) do
                local point = target.position + V3(0, h, 0)
                if lineOfSight(from, point) then
                    rook.losClear, rook.losSample = true, i
                    break
                end
            end
            -- The arm guns sit lower than the sensor head: the firing lane is the line from the gun height to the target's torso.
            rook.laneClear = rook.losClear and lineOfSight(V3(state.x, rook.groundY + GUN_HEIGHT, state.z), target.position + V3(0, SAMPLE_HEIGHTS[1], 0))
        elseif not inSight then
            rook.losClear = false
        end
        seen = inSight and rook.losClear
        lane = seen and rook.laneClear == true
        if seen then
            mem.pos, mem.vel, mem.at, mem.exact = target.position, target.velocity, now, true
        else
            -- Gunfire gives the player away, but only roughly.
            local session = target.session
            local ws = session and session.weapons
            if actual <= p.hearRange and ws and ws.held and now - (rook.heardAt or -10) > 0.8 then
                rook.heardAt = now
                local angle = rook.rng:NextNumber(0, math.pi * 2)
                local error = rook.rng:NextNumber(0.3, 1) * p.hearError
                mem.pos = target.position + V3(math.cos(angle) * error, 0, math.sin(angle) * error)
                mem.vel, mem.at, mem.exact = Vector3.zero, now, false
                heard = true
            end
        end
    else
        mem.pos, mem.at = nil, -math.huge -- no valid target: nothing remains of the contact (pilot safety, reset)
    end
    local sinceSeen = now - mem.at
    if mem.pos and sinceSeen < p.memory then
        local drift = math.min(sinceSeen, 2.0)
        estimate = mem.pos + mem.vel * drift
        local ex, ez = estimate.X - state.x, estimate.Z - state.z
        range = math.sqrt(ex * ex + ez * ez)
        bearing = math.rad(Math.relativeBearing(state.yaw, ex, ez))
    end
    return { seen = seen, lane = lane, heard = heard, hasTarget = hasTarget, sinceSeen = sinceSeen, range = range, bearing = bearing }, estimate
end

-- Is the player shooting at ROOK? ROOK only knows what it can see: the player's weapon must be firing and the aim line must pass close
-- to ROOK, and ROOK must have the player in view (or have just been hit).
local function threatOf(rook, target, seen: boolean, now: number)
    local def = rook.def.defense
    local state = rook.controller.state
    local level, bearing = 0, 0
    if target and seen then
        local ws = target.session and target.session.weapons
        if ws and ws.held and ws.aim and (now - (ws.lastInput or -10)) < 0.5 then
            local o = target.position + V3(0, 12, 0)
            local to = ws.aim - o
            local len = to.Magnitude
            if len > 1 then
                local u = to / len
                local chest = V3(state.x, rook.groundY + 9, state.z) - o
                local t = chest:Dot(u)
                if t > 0 and t <= len + 40 and (chest - u * t).Magnitude <= def.aimRadius * 0.6 then
                    level = 1
                    bearing = math.rad(Math.relativeBearing(state.yaw, target.position.X - state.x, target.position.Z - state.z))
                end
            end
        end
    end
    if now - rook.lastHitAt < def.hitAwareness and rook.lastHitFrom then
        level = math.max(level, 0.8)
        bearing = math.rad(Math.relativeBearing(state.yaw, rook.lastHitFrom.X - state.x, rook.lastHitFrom.Z - state.z))
    end
    return { level = level, bearing = bearing }
end

local function fraction(unit, region: string): number
    return Damage.Fraction(unit.damage, region)
end

local function slotOf(rook, w)
    return rook.weapons.slots[w.socket]
end

local function senses(rook, target, trial: boolean, now: number)
    local def = rook.def
    local state = rook.controller.state
    local unit = rook.unit
    local fx = unit.damageFx
    local e = rook.power.energy
    local perceived, estimate = sample(rook, target, now)
    local w = def.weapons
    local mgSlot, lrSlot = slotOf(rook, w.MG), slotOf(rook, w.LR)
    local pulses = w.LR.pulses
    local others = 0
    for _, region in ipairs({ "ARM_L", "ARM_R", "LEG_L", "LEG_R", "REACTOR" }) do
        others += fraction(unit, region)
    end
    local speedCap = rook.controller.params.maxForward
    local shield = rook.power.shield
    local s = {
        active = trial, resetting = rook.district.resetting ~= nil, coreAlive = not unit.damage.coreFailed,
        weaponsOnline = { MG = not fx.sockets[w.MG.socket], LR = not fx.sockets[w.LR.socket] },
        hasTarget = perceived.hasTarget, seen = perceived.seen, lane = perceived.lane, sinceSeen = perceived.sinceSeen, range = perceived.range, bearing = perceived.bearing,
        targetSpeed = if target then target.velocity.Magnitude else rook.memory.vel.Magnitude, ownSpeedFrac = math.abs(state.speed) / speedCap,
        legs = fx.speed, reactor = fx.reactor, charge = e.charge / rook.power.config.capacity,
        availWeapons = Energy.Available(e, "weapons"), weaponBudget = math.max(0, e.charge - Energy.Reserve(e, "weapons")),
        thermal = e.thermal / rook.power.config.thermalMaximum,
        mg = { ammo = mgSlot.ammo, reloading = mgSlot.reloadAt ~= nil, burstCost = mgSlot.spec.energy * w.MG.burst, interval = mgSlot.spec.interval },
        lr = { volleyCost = lrSlot.spec.energy * pulses, interval = lrSlot.spec.interval },
        shield = { ready = shield.state == "READY" and shield.reason ~= "CAPACITOR LOW" },
        threat = threatOf(rook, target, perceived.seen, now),
        structure = 0.6 * fraction(unit, "CORE") + 0.4 * others / 5,
        armHealth = { MG = fraction(unit, w.MG.region), LR = fraction(unit, w.LR.region) },
        profile = rook.power.profile.pending or rook.power.profile.active,
        nav = {
            arrived = rook.arrived, noPath = rook.noPath, stuck = rook.progress.stuck,
            awayFromStation = flat(state.x, state.z, rook.district.origin.X + def.station.x, rook.district.origin.Z + def.station.z) > 12,
        },
    }
    return s, estimate, perceived
end

-- Movement ------------------------------------------------------------------------------------------------------------------------
local function stationPoint(rook): (number, number)
    local def = rook.def
    return rook.district.origin.X + def.station.x, rook.district.origin.Z + def.station.z
end

local function updateClearances(rook, now: number)
    local c = rook.clear
    if now - c.at < 0.07 then
        return
    end
    c.at = now
    c.ahead = freeDistance(rook, 0, 1)
    c.left = freeDistance(rook, WHISKER_ANGLE, 1)
    c.right = freeDistance(rook, -WHISKER_ANGLE, 1)
end

local function pickGoal(rook, reason: string, estimate: Vector3, now: number)
    local def = rook.def
    local state = rook.controller.state
    -- Re-validate the lattice when it is old (walls get shot away, or a stale edge was blocked by something that has since moved).
    if now - rook.latticeAt > 20 then
        validateLattice(rook)
    end
    refreshFilters()
    local los = {}
    for _, node in ipairs(rook.nodes) do
        if node.valid then
            los[node.id] = lineOfSight(V3(node.x, rook.groundY + GUN_HEIGHT, node.z), estimate + V3(0, SAMPLE_HEIGHTS[1], 0))
        end
    end
    local recent = {}
    for id, until_ in pairs(rook.recent) do
        if until_ > now then
            recent[id] = 40
        else
            rook.recent[id] = nil
        end
    end
    local node = Nav.Pick(rook.graph, {
        x = state.x, z = state.z, tx = estimate.X, tz = estimate.Z, reason = reason, band = def.tactics.band, los = los, recent = recent, minTravel = 9,
    })
    rook.counters.repicks += 1
    if node then
        rook.goal = { x = node.x, z = node.z, id = node.id, reason = reason }
        rook.recent[node.id] = now + 12
        rook.route, rook.arrived, rook.noPath = nil, false, false
    else
        rook.goal, rook.noPath, rook.noPathAt = nil, true, now
    end
end

local function followGoal(rook, gx: number, gz: number, cap: number, stop: number, now: number): (number, number, number)
    local state = rook.controller.state
    local def = rook.def
    local route = rook.route
    if not route or flat(route.gx, route.gz, gx, gz) > 3 or now - route.at > 2.5 then
        local points = Nav.Route(rook.graph, state.x, state.z, gx, gz, function(x1, z1, x2, z2)
            return segmentClear(rook, x1, z1, x2, z2)
        end)
        route = { gx = gx, gz = gz, at = now, points = points, index = 1 }
        rook.route = route
        if not points then
            rook.noPath, rook.noPathAt = true, now
        else
            rook.noPath = false
        end
    end
    if not route.points then
        -- No lattice route: close slowly on the goal in a straight line using the live clearance sweeps. The stuck detector and the
        -- brain (noPath -> a new position) take over if that goes nowhere.
        local c = rook.clear
        local th, st, dist = Nav.Drive(state, gx, gz, rook.controller.params, { cap = cap * 0.5, stop = stop, clearAhead = c.ahead, clearLeft = c.left, clearRight = c.right, hullMargin = 3 })
        return th, st, dist
    end
    local wp = route.points[route.index]
    local last = route.index == #route.points
    local limit = if last then def.court.arriveRadius else def.court.passRadius
    if flat(state.x, state.z, wp.x, wp.z) < limit then
        if last then
            rook.arrived = true
        else
            route.index += 1
            wp = route.points[route.index]
            last = route.index == #route.points
        end
    end
    local c = rook.clear
    local throttle, steer, distance = Nav.Drive(state, wp.x, wp.z, rook.controller.params, {
        cap = cap, stop = if last then stop else 0, clearAhead = c.ahead, clearLeft = c.left, clearRight = c.right, hullMargin = 3,
    })
    return throttle, steer, distance
end

-- Returns throttle, steer for this frame.
local function movement(rook, orders, estimate: Vector3?, now: number, dt: number): (number, number)
    local state = rook.controller.state
    local def = rook.def
    local mode = orders.move.mode
    local throttle, steer = 0, 0
    updateClearances(rook, now)
    local c = rook.clear
    local ox, oz = state.x, state.z
    -- A new tactical position was requested.
    if orders.repick and estimate then
        local reason = rook.brain.reposition and rook.brain.reposition.reason
        if reason then
            pickGoal(rook, reason, estimate, now)
        end
    end
    local faceYaw = if estimate then Nav.yawTo(ox, oz, estimate.X, estimate.Z) else state.yaw
    if rook.progress.recover or (rook.progress.stuck and mode ~= "hold") then
        local th, st, done = Nav.Recover(rook.progress, dt, c.left, c.right, 1.8)
        if done then
            rook.counters.stuck += 1
            rook.route = nil
            rook.noPath, rook.noPathAt = true, now
        end
        return th, st
    end
    if mode == "approach" and estimate then
        -- Close on the contact to the middle of the preferred band, never past it.
        local mid = (def.tactics.band[1] + def.tactics.band[2]) / 2
        local dx, dz = estimate.X - ox, estimate.Z - oz
        local range = math.sqrt(dx * dx + dz * dz)
        local travel = math.max(0, range - mid)
        local gx, gz = ox + dx / math.max(range, 1) * travel, oz + dz / math.max(range, 1) * travel
        gx, gz = Nav.Clamp(def.court, rook.district.origin.X, rook.district.origin.Z, gx, gz)
        -- Snap the ideal point to the nearest clear lattice node so the goal is never inside a wall.
        local snapped = Nav.Nearest(rook.graph, gx, gz, 1)[1]
        if snapped and flat(snapped.x, snapped.z, gx, gz) < 14 then
            gx, gz = snapped.x, snapped.z
        end
        local th, st = followGoal(rook, gx, gz, orders.move.cap, 3, now)
        throttle, steer = th, st
    elseif mode == "reposition" and rook.goal then
        local th, st = followGoal(rook, rook.goal.x, rook.goal.z, orders.move.cap, def.court.arriveRadius - 1.5, now)
        throttle, steer = th, st
    elseif mode == "reposition" then
        throttle, steer = 0, Nav.Face(state.yaw, faceYaw, math.rad(25))
    elseif mode == "station" then
        local sx, sz = stationPoint(rook)
        local th, st, distance = followGoal(rook, sx, sz, orders.move.cap, 2.5, now)
        throttle, steer = th, st
        if distance < 3 and math.abs(state.speed) < 0.4 then
            steer = Nav.Face(state.yaw, def.station.yaw, math.rad(20)) -- square up to the pad
            throttle = 0
        end
    elseif mode == "retreat" and estimate then
        throttle = -orders.move.cap
        steer = Nav.Face(state.yaw, faceYaw, math.rad(25))
        local back = freeDistance(rook, 0, -1)
        if back < 8 then
            throttle = 0
        end
    else
        throttle = 0
        if orders.face == "target" or orders.face == "threat" then
            steer = Nav.Face(state.yaw, faceYaw, math.rad(25))
        end
    end
    -- Never walk through the player's machine: it is a solid circle for planning even though the hulls are not colliders.
    if throttle > 0 and rook.playerPos then
        local px, pz = rook.playerPos.X, rook.playerPos.Z
        local gap = flat(ox, oz, px, pz) - Config.trial.separation * 2
        local toward = Nav.wrap(Nav.yawTo(ox, oz, px, pz) - state.yaw)
        if math.abs(toward) < math.rad(50) and gap < 14 then
            throttle *= math.clamp(gap / 14, 0, 1)
        end
    end
    -- Progress tracking: commanded to travel but barely moving trips the stuck detector.
    -- A hull pressed against a wall cannot sweep round: Locomotion reports turnBlocked, and the stuck detector also watches the yaw.
    if rook.turnBlockedFor > 0.8 and not rook.progress.recover then
        rook.progress.stuck = true
        rook.progress.stuckCount += 1
        rook.turnBlockedFor = 0
    end
    Nav.Track(rook.progress, dt, ox, oz, math.abs(throttle) > 0.3, state.yaw, math.abs(steer) > 0.25 and math.abs(throttle) < 0.3)
    return throttle, steer
end

-- Weapons -----------------------------------------------------------------------------------------------------------------------------
local function muzzleGeometry(rook, w, aim: Vector3)
    local st = rook.controller.state
    local root = CF(st.x, st.y, st.z) * ANG(0, st.yaw, 0) * ANG(st.pitch, 0, st.roll)
    local world = MechRig.Solve(root)
    local mount = Geometry.Mount(world, w.socket, nil)
    local aimed = Geometry.Mount(world, w.socket, aim)
    local slot = rook.weapons.slots[w.socket]
    local origin = (aimed * CF(0, 0, -slot.spec.muzzle)).Position
    local delta = aim - mount.Position
    local valid = delta.Magnitude > slot.spec.muzzle + 1 and delta.Magnitude < 2000 and delta.Unit:Dot(root.LookVector) >= math.cos(math.rad(65))
    return origin, aimed.LookVector, mount.Position, valid
end

local function desiredAim(rook, w, target, estimate: Vector3, orders): Vector3
    local mem = rook.memory
    local st = rook.controller.state
    local velocity = if target and mem.exact then target.velocity else mem.vel
    local point = estimate + V3(0, SAMPLE_HEIGHTS[rook.losSample] or SAMPLE_HEIGHTS[1], 0)
    local muzzle = V3(st.x, rook.groundY + 12, st.z)
    local ax, az = Math.lead(muzzle.X, muzzle.Z, point.X, point.Z, velocity.X, velocity.Z, w.speed, w.lead)
    return V3(ax, point.Y, az)
end

local function fireRound(rook, d, c, w, aim: Vector3, spread: number, now: number): boolean
    local slot = slotOf(rook, w)
    local model = rook.model
    local origin, direction, mountPos, valid = muzzleGeometry(rook, w, aim)
    if valid then
        sightParams.FilterDescendantsInstances = characters()
        if workspace:Raycast(mountPos, origin - mountPos, sightParams) then
            valid = false -- a barrel pressed into cover cannot fire
        end
    end
    local e = rook.power.energy
    local fired = WeaponState.Fire(rook.weapons, w.socket, now, true, valid, function(cost, heat)
        if Energy.Consume(e, cost, false, 0, "weapons") ~= cost then
            EnergySystems.NoteWeaponLimited(rook.power)
            return false
        end
        e.thermal = math.clamp(e.thermal + heat, 0, rook.power.config.thermalMaximum)
        return true
    end)
    if not fired then
        return false
    end
    -- Bounded targeting error: a random point in the aim cone, never perfect.
    local angle, magnitude = rook.rng:NextNumber(0, math.pi * 2), spread * math.sqrt(rook.rng:NextNumber())
    local shot = CFrame.lookAt(origin, origin + direction) * ANG(math.sin(angle) * magnitude, math.cos(angle) * magnitude, 0)
    local dir = shot.LookVector
    local spec = slot.spec
    local distance = (aim - origin).Magnitude
    local damage = spec.damage * w.damageScale
    if env.spawnBolt then
        env.spawnBolt(d, {
            source = rook.def.callsign, arch = "ROOK", weaponKey = w.key, origin = origin, dir = dir, speed = w.speed, radius = w.radius,
            life = math.min(w.life, distance / w.speed + 0.6), damage = damage, structure = damage, category = w.category, weaponId = w.id,
        })
    end
    local shotAt = workspace:GetServerTimeNow()
    model:SetAttribute("WeaponShotAt", shotAt)
    if env.weaponFx then
        env.weaponFx:FireAllClients(model, w.socket, w.id, origin, origin + dir * 7, -dir, 0)
    end
    rook.counters[w.key] += 1
    rook.counters.rounds += 1
    return true
end

local function weaponsStep(rook, d, c, orders, target, estimate: Vector3?, perceived, s, now: number, dt: number)
    local def = rook.def
    local model = rook.model
    local attack = orders.attack
    local power = rook.power
    -- Slots keep reloading in the background exactly like the player's.
    WeaponState.Advance(rook.weapons, now)
    if not attack or not estimate or rook.down then
        if rook.attackSocket then
            rook.attackSocket, rook.lockedAim, rook.aim = nil, nil, nil
            setAttr(rook, model, "WeaponAim", nil)
            setAttr(rook, model, "AiAttack", "")
            setAttr(rook, model, "AiPhase", "")
        end
        setAttr(rook, model, "WeaponState", if rook.down then "SAFE" else rook.weapons.reason)
        return
    end
    local w = def.weapons[attack.id]
    if rook.attackSocket ~= w.socket or (attack.started) then
        rook.attackSocket = w.socket
        rook.aim = nil
        rook.lockedAim = nil
        rook.lastAttack = { id = attack.id, at = now }
        setAttr(rook, model, "AiAimAt", workspace:GetServerTimeNow())
        setAttr(rook, model, "AiWarn", attack.duration or if attack.id == "MG" then w.spool else w.charge)
    end
    setAttr(rook, model, "AiAttack", attack.id)
    setAttr(rook, model, "AiPhase", attack.phase)
    setAttr(rook, model, "WeaponSocket", w.socket)
    -- The arm tracks with finite speed: the aim point eases toward the lead-corrected target, then freezes when the laser locks.
    local desired = desiredAim(rook, w, target, estimate, orders)
    if attack.locked then
        rook.lockedAim = rook.lockedAim or rook.aim or desired
        rook.aim = rook.lockedAim
    else
        rook.lockedAim = nil
        local rate = if attack.id == "MG" then 7 else 5
        rook.aim = if rook.aim then rook.aim:Lerp(desired, 1 - math.exp(-rate * dt)) else desired
    end
    setAttr(rook, model, "WeaponAim", rook.aim)
    -- Continuous energy while the laser charges (shows up as weapon demand in the same ledger).
    if attack.id == "LR" and attack.phase == "CHARGE" then
        EnergySystems.RequestPower(power, "weapons", w.chargeDraw)
    end
    setAttr(rook, model, "WeaponState", if attack.trigger then "FIRING" else "CHARGING")
    if attack.trigger then
        local spread = Brain.AimSpread(def, w, s)
        fireRound(rook, d, c, w, rook.aim, spread, now)
    end
end

-- Frame ---------------------------------------------------------------------------------------------------------------------------------
local function publishDistrict(rook, s, now: number)
    if now - rook.published < 0.2 then
        return
    end
    rook.published = now
    local folder = rook.district.folder
    local function set(name: string, value: any)
        if rook.districtCache[name] ~= value then
            rook.districtCache[name] = value
            folder:SetAttribute(name, value)
        end
    end
    set("RookStatus", rook.status)
    set("RookState", rook.brain.state)
    set("RookStructure", math.floor(s.structure * 100 + 0.5))
    set("RookCharge", math.floor(s.charge * 100 + 0.5))
    set("RookShield", rook.power.shield.state)
    set("RookAttack", rook.model:GetAttribute("AiAttack") or "")
    set("RookShots", rook.counters.rounds)
end

local function separate(rook, target)
    local ctrl = rook.controller
    local pc = target.controller
    local a, b = ctrl.state, pc.state
    local dx, dz = a.x - b.x, a.z - b.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local minimum = Config.trial.separation * 2
    if dist >= minimum then
        return
    end
    if dist < 0.01 then
        dx, dz, dist = 0, 1, 1
    end
    local push = (minimum - dist)
    local nx, nz = dx / dist, dz / dist
    -- Half each, through the real swept hull probes so neither is shoved into a wall.
    local rx, rz = ctrl.params2.move(a.x, a.y, a.z, a.yaw, nx * push * 0.5, nz * push * 0.5)
    a.x, a.z = rx, rz
    local px, pz = pc.params2.move(b.x, b.y, b.z, b.yaw, -nx * push * 0.5, -nz * push * 0.5)
    b.x, b.z = px, pz
    -- Whoever drives into the other loses speed.
    local ha, hb = -math.sin(a.yaw), -math.cos(a.yaw)
    if ha * -nx + hb * -nz > 0.3 then a.speed *= 0.8 end
    local pa, pb = -math.sin(b.yaw), -math.cos(b.yaw)
    if pa * nx + pb * nz > 0.3 then b.speed *= 0.8 end
end

function EnemyMech.Step(d, c, target, trial: boolean, dt: number, now: number)
    local rook = d.rook
    if not rook or d.resetting or not rook.model or not rook.model.Parent then
        return
    end
    local started = os.clock()
    local ctrl = rook.controller
    local model = rook.model
    refreshFilters()
    rook.playerPos = target and target.position or nil

    -- Trial gating: unlock the drive when the trial arms, stand down (and walk home) when it ends.
    local live = trial and not rook.down
    if live ~= rook.live then
        rook.live = live
        if live then
            rook.homing = false
            Locomotion.SetLocked(ctrl, false)
            rook.status = "ACTIVE"
        elseif not rook.down then
            rook.homing = true
            rook.status = "STANDING DOWN"
            rook.attackSocket, rook.aim, rook.lockedAim = nil, nil, nil
            setAttr(rook, model, "WeaponAim", nil)
            setAttr(rook, model, "AiAttack", "")
            setAttr(rook, model, "AiPhase", "")
            Locomotion.SetLocked(ctrl, false)
        end
        setAttr(rook, model, "RookStatus", rook.status)
    end

    local s, estimate, perceived = senses(rook, target, live, now)
    local orders = Brain.Step(rook.brain, dt, s)

    -- A wreck or a neutralised unit only needs its pose kept current.
    if rook.down then
        Locomotion.Step(ctrl, dt)
        publishDistrict(rook, s, now)
        return
    end
    if rook.brain.state == "DISABLED" and not rook.down then
        EnemyMech.Disable(d, rook, if rook.unit.damage.coreFailed then "CORE FAILURE" else "BOTH WEAPON ASSEMBLIES DESTROYED", rook.unit.damage.coreFailed)
        return
    end

    local throttle, steer = 0, 0
    if live or rook.homing then
        if rook.homing then
            orders.move = { mode = "station", cap = 0.55 }
            orders.face = "travel"
        end
        throttle, steer = movement(rook, orders, estimate, now, dt)
        if rook.homing then
            local sx, sz = stationPoint(rook)
            if flat(ctrl.state.x, ctrl.state.z, sx, sz) < 3.5 and math.abs(ctrl.state.speed) < 0.4 then
                rook.homing = false
                rook.status = "STANDBY"
                Locomotion.SetLocked(ctrl, true)
                setAttr(rook, model, "RookStatus", rook.status)
            end
        end
    end
    Locomotion.SetInput(ctrl, throttle, steer, false)
    rook.cmd = { throttle = throttle, steer = steer, mode = orders.move.mode, face = orders.face }

    -- Profile and shield orders go through the same server interfaces the player's requests use.
    if orders.profile and now - rook.lastProfileAsk > 0.5 then
        rook.lastProfileAsk = now
        EnergySystems.RequestProfile(rook.power, orders.profile)
    end
    if orders.shield then
        local ok = EnergySystems.Activate(rook.power, true)
        if ok then
            rook.counters.shields += 1
        end
    end

    weaponsStep(rook, d, c, orders, target, estimate, perceived, s, now, dt)
    local events = Locomotion.Step(ctrl, dt)
    rook.turnBlockedFor = if events.turnBlocked then rook.turnBlockedFor + dt else math.max(0, rook.turnBlockedFor - dt * 2)
    if target and live then
        separate(rook, target)
    end

    -- Published state (change-only attributes; the cockpit and the lamps read these).
    local brain = rook.brain
    setAttr(rook, model, "AiState", brain.state)
    setAttr(rook, model, "AiReason", brain.reason)
    setAttr(rook, model, "AiRange", if s.seen then math.floor(s.range + 0.5) else -1)
    setAttr(rook, model, "AiSeen", s.seen)
    setAttr(rook, model, "AiProfile", rook.power.profile.active)
    setAttr(rook, model, "AiStuck", rook.counters.stuck)
    setAttr(rook, model, "StructurePct", math.floor(s.structure * 100 + 0.5))
    if brain.state == "DEFEND" then
        setAttr(rook, model, "AiGuard", true)
    else
        setAttr(rook, model, "AiGuard", false)
    end
    publishDistrict(rook, s, now)

    local ms = (os.clock() - started) * 1000
    local stats = EnemyMech.stats
    stats.stepMs += (ms - stats.stepMs) * 0.05
    stats.worstMs = math.max(stats.worstMs, ms)
    stats.steps += 1
end

-- Mode hook: the trial is (de)activated by TankCombat.SetMode. Starting a trial always begins against a fresh machine.
function EnemyMech.OnTrialStart(d)
    local rook = d.rook
    if rook and (rook.down or rook.unit.damage.hits > 0 or rook.brain.shields > 0 or rook.counters.rounds > 0) then
        EnemyMech.Respawn(d, rook)
    end
end

-- Audit -------------------------------------------------------------------------------------------------------------------------------------
function EnemyMech.Audit(d)
    local rook = d.rook
    if not rook then
        return nil
    end
    local st = rook.controller.state
    local e = rook.power.energy
    local brain = rook.brain
    local fx = rook.unit.damageFx
    local regions = {}
    for _, region in ipairs(Damage.Regions) do
        regions[region] = round1(rook.unit.damage.health[region])
    end
    local sockets = {}
    for socket in pairs(fx.sockets) do
        table.insert(sockets, socket)
    end
    table.sort(sockets)
    local slots = {}
    for socket, slot in pairs(rook.weapons.slots) do
        slots[socket] = { id = slot.id, ammo = slot.ammo, reloading = slot.reloadAt ~= nil }
    end
    local instances = 0
    for _ in ipairs(rook.model:GetDescendants()) do
        instances += 1
    end
    return {
        id = rook.id, status = rook.status, state = brain.state, reason = brain.reason, down = rook.down, downReason = rook.downReason,
        position = V3(st.x, st.y, st.z), yaw = st.yaw, speed = st.speed, yawRate = st.yawRate, distance = st.distance,
        charge = round1(e.charge), capacity = rook.power.config.capacity, output = round1(e.output), supply = round1(e.reactorSupply),
        thermal = round1(e.thermal), demand = round1(e.demand), deficit = round1(e.deficit), profile = rook.power.profile.active,
        profilePending = rook.power.profile.pending, shield = rook.power.shield.state, shieldReason = rook.power.shield.reason,
        shieldSerial = rook.power.shield.serial, regions = regions, speedFactor = fx.speed, reactorFactor = fx.reactor, sockets = sockets,
        slots = slots, counters = table.clone(rook.counters), cool = table.clone(brain.cool), attack = brain.attack and { id = brain.attack.id, phase = brain.attack.phase } or nil,
        transitions = brain.transitions, shots = table.clone(brain.shots), aborted = brain.aborted, lastAbort = brain.lastAbort,
        goal = rook.goal, noPath = rook.noPath, stuckCount = rook.progress.stuckCount, edges = Nav.EdgeCount(rook.graph),
        route = rook.route and rook.route.points and #rook.route.points or -1, cmd = rook.cmd, clear = table.clone(rook.clear), wp = rook.route and rook.route.points and rook.route.points[rook.route.index] and string.format("%d/%d (%.0f,%.0f)", rook.route.index, #rook.route.points, rook.route.points[rook.route.index].x, rook.route.points[rook.route.index].z) or "-", turnBlockedFor = rook.turnBlockedFor,
        lattice = (function() local list = {}; for _, node in ipairs(rook.nodes) do table.insert(list, string.format("%d,%d%s", node.x - rook.district.origin.X, node.z - rook.district.origin.Z, node.valid and "" or "x")) end; return table.concat(list, " ") end)(),
        validNodes = (function() local n = 0; for _, node in ipairs(rook.nodes) do if node.valid then n += 1 end end; return n end)(),
        totalNodes = #rook.nodes, instances = instances, perf = table.clone(EnemyMech.stats), memoryAge = os.clock() - rook.memory.at,
        locked = rook.controller.input.locked, live = rook.live,
    }
end

return EnemyMech
