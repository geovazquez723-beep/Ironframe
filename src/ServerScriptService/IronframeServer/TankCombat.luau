-- Active tank combat (M10B): the server side of ACTIVE TRAINING.
--
-- Each frame, for every district whose pilot is deployed:
--   1. perceive   target validity (deployed, operational, not evacuated, inside the district), range, traverse arc, line of sight
--                 against REAL geometry (destroyed cover is gone from the workspace, so lines of fire change)
--   2. think      TankBrain (pure state machine) decides state, whether to fire, and what the turret / hull should do
--   3. act        slew the turret, drive / pivot the hull, recoil; on FIRE spawn a shell from the real muzzle
--   4. fly        every shell is a plain table swept with Spherecast (world) and a ray-vs-hull test (the Bastion) each heartbeat -
--                 no physical projectile instances exist on the server
--   5. resolve    a Bastion hit goes through the EXISTING shield interface (EnergySystems.ResolveImpact); only the penetrating
--                 remainder reaches a damage region (BastionDamage). A world hit goes through Destructibles.Hit like any weapon.
--
-- The client is cosmetic only: it receives `fire` / `end` events and draws the shell, trail and impacts. Nothing it says can hit anything.
-- Pilots are never targets: the only target is the deployed, OPERATIONAL Bastion in the district; an evacuated mech, an escape
-- capsule or a docked mech is not a target and cancels everything in flight.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Config = require(Shared:WaitForChild("CombatConfig"))
local Math = require(Shared:WaitForChild("CombatMath"))
local MechDamage = require(Shared:WaitForChild("MechDamage"))
local Brain = require(Shared:WaitForChild("TankBrain"))
local EnemyConfig = require(Shared:WaitForChild("EnemyConfig"))
local Destructibles = require(script.Parent.Destructibles)
local EnemyMech = require(script.Parent.EnemyMech) -- M10C
local SortieReport = require(script.Parent.SortieReport) -- M11A
local TrainingTank = require(script.Parent.TrainingTank)
local Locomotion = require(script.Parent.Locomotion)
local EnergySystems = require(script.Parent.EnergySystems)
local BastionDamage = require(script.Parent.BastionDamage)

local TankCombat = {}

local V3 = Vector3.new
local UP = V3(0, 1, 0)
local RECOIL = 1.4 -- studs the turret kicks back when it fires
local RECOIL_TIME = 0.6
local TURRET_WRITE = 0.05 -- seconds between turret weld writes while tracking (20 Hz)
local BOUNDS = { minZ = 300, maxZ = 720, halfX = 92, minY = -30, maxY = 160 } -- bay-local limits of the district for shells

local env: { sessions: { [Player]: any }, fx: RemoteEvent, weaponFx: RemoteEvent? } = nil :: any
local rng = Random.new(10202)

TankCombat.stats = { aiMs = 0, aiWorst = 0, projMs = 0, projWorst = 0, steps = 0, peakProjectiles = 0, packets = 0, events = 0 }

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true

function TankCombat.Init(options)
    env = options
    -- M10C: ROOK fires through this module's swept-projectile manager and the shared weapon-effect remote.
    EnemyMech.Init({
        spawnBolt = function(d, spec) return TankCombat.SpawnBolt(d, spec) end,
        weaponFx = options.weaponFx,
        cancelBolts = function(d, rook) TankCombat.CancelFrom(d, rook.def.callsign) end,
        onDown = function(d, reason)
            local session = d.owner and options.sessions[d.owner]
            if session then
                SortieReport.NoteRookDown(session, reason)
            end
        end,
    })
end

local function newCombat(d)
    return {
        mode = Config.defaultMode, armedAt = 0, projectiles = {}, events = {}, nextId = 0,
        stats = { shots = 0, mechHits = 0, worldHits = 0, expired = 0, cancelled = 0, suppressed = 0, perfect = 0, guard = 0, unguarded = 0, offAxis = 0, prevented = 0, penetrating = 0 },
        published = {}, publishedAt = -100, lastPacketAt = 0,
    }
end

local function combatOf(d)
    local c = d.combat
    if not c then
        c = newCombat(d)
        d.combat = c
        d.folder:SetAttribute("CombatMode", c.mode)
        d.folder:SetAttribute("CombatArmed", false)
    end
    return c
end
TankCombat.Of = combatOf

local function emit(c, event)
    table.insert(c.events, event)
end

local function flush(d, c)
    if #c.events == 0 then
        return
    end
    if env and d.owner and d.owner.Parent then
        env.fx:FireClient(d.owner, c.events)
        TankCombat.stats.packets += 1
        TankCombat.stats.events += #c.events
    end
    c.events = {}
end

-- Target ------------------------------------------------------------------------------------------------------------------
-- The one thing tanks may shoot at: the pilot's deployed, operational Bastion while it is inside the district. Everything else
-- (hangar, staging, docked, ejected, evacuated, escape capsule) returns nil.
local function targetOf(d)
    local player = d.owner
    local session = player and env and env.sessions[player]
    if not session then
        return nil, nil
    end
    local sortieLive = session.machineState == "OPERATIONAL" and session.deployment == "ACTIVE"
    local c, mech = session.controller, session.mech
    if not sortieLive or not c or not mech or not mech.Parent or mech:GetAttribute("State") ~= "OPERATIONAL" then
        return nil, session, false
    end
    if session.damage and session.damage.coreFailed then
        return nil, session, false
    end
    if mech:GetAttribute("RangeZone") ~= "DISTRICT" then
        return nil, session, true -- alive, but in the staging field or hangar: never a target
    end
    local s = c.state
    local heading = V3(-math.sin(s.yaw), 0, -math.cos(s.yaw))
    return {
        session = session, player = player, controller = c, position = V3(s.x, s.y, s.z), velocity = heading * s.speed, yaw = s.yaw,
        hullCF = Locomotion.HullPose(c.params, s), hull = c.params.hull,
    }, session, true
end

-- Line of sight ---------------------------------------------------------------------------------------------------------------
local function filterList(d): { Instance }
    local list = {}
    for _, vehicle in ipairs(d.vehicles) do
        if vehicle.model then
            table.insert(list, vehicle.model)
        end
    end
    if d.mech and d.mech.model then
        table.insert(list, d.mech.model)
    end
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

-- Returns (clear, aimPoint): the first sample height on the Bastion that the muzzle can see.
local function lineOfSight(d, tank, target): (boolean, Vector3?)
    local origin = TrainingTank.Muzzle(tank).Position
    params.FilterDescendantsInstances = filterList(d)
    for _, h in ipairs(Config.sampleHeights) do
        local point = target.position + V3(0, h, 0)
        if not workspace:Raycast(origin, point - origin, params) then
            return true, point
        end
    end
    return false, nil
end

local function flat(a: Vector3, b: Vector3): number
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- Patrol tank: pick the route position with the best range and a clear line, hold it for a second to avoid dithering.
local function repositionGoal(d, tank, arch, target, now: number): Vector3?
    if tank.repoTarget and now < (tank.repoUntil or 0) then
        return tank.repoTarget
    end
    local points = tank.patrol and tank.patrol.points
    if not points or #points < 2 then
        return nil
    end
    local band = arch.preferredRange
    local mid = (band[1] + band[2]) / 2
    local a, b = points[1], points[#points]
    params.FilterDescendantsInstances = filterList(d)
    local sample = target.position + V3(0, Config.sampleHeights[1], 0)
    local best, bestCost
    for i = 0, 6 do
        local p = a:Lerp(b, i / 6)
        local range = flat(p, target.position)
        local cost = math.abs(range - mid) + 0.12 * flat(p, tank.position)
        if range < band[1] * 0.6 then
            cost += 200 -- never close to point-blank
        end
        local from = p + V3(0, 10, 0)
        if workspace:Raycast(from, sample - from, params) then
            cost += 80 -- no line of fire from there
        end
        if not bestCost or cost < bestCost then
            best, bestCost = p, cost
        end
    end
    tank.repoTarget, tank.repoUntil = best, now + 1.0
    return best
end

-- Shells -----------------------------------------------------------------------------------------------------------------
local function spawnShell(d, c, tank, dir: Vector3, origin: Vector3, aimDistance: number)
    local arch = tank.arch
    if #c.projectiles >= Config.maxProjectiles then
        c.stats.suppressed += 1
        return nil
    end
    c.nextId += 1
    local shell = arch.shell
    local life = math.min(shell.life, aimDistance / shell.speed + 1.0)
    local p = {
        id = c.nextId, tank = tank, tankId = tank.id, arch = arch.id, pos = origin, vel = dir * shell.speed, radius = shell.radius,
        age = 0, life = life, damage = shell.damage, structure = shell.structure, heavy = shell.heavy, origin = origin,
    }
    table.insert(c.projectiles, p)
    c.stats.shots += 1
    TankCombat.stats.peakProjectiles = math.max(TankCombat.stats.peakProjectiles, #c.projectiles)
    emit(c, { k = "fire", id = p.id, tank = tank.id, arch = arch.id, o = origin, v = p.vel, r = p.radius, l = life, t = workspace:GetServerTimeNow(), heavy = shell.heavy })
    return p
end

-- M10C: a round fired by an autonomous mech. Same table shape and same sweep / shield / damage resolution as a tank shell.
--   spec = { source, arch, weaponKey, origin, dir, speed, radius, life, damage, structure, category, weaponId }
function TankCombat.SpawnBolt(d, spec)
    local c = combatOf(d)
    local rooks = 0
    for _, p in ipairs(c.projectiles) do
        if p.bolt then
            rooks += 1
        end
    end
    if rooks >= EnemyConfig.trial.maxBolts or d.resetting then
        c.stats.suppressed += 1
        return nil
    end
    c.nextId += 1
    local p = {
        id = c.nextId, tankId = spec.source, arch = spec.arch, wk = spec.weaponKey, bolt = true, pos = spec.origin, vel = spec.dir * spec.speed,
        radius = spec.radius, age = 0, life = spec.life, damage = spec.damage, structure = spec.structure, heavy = false, origin = spec.origin,
        category = spec.category, weaponId = spec.weaponId,
    }
    table.insert(c.projectiles, p)
    c.stats.shots += 1
    TankCombat.stats.peakProjectiles = math.max(TankCombat.stats.peakProjectiles, #c.projectiles)
    emit(c, { k = "fire", id = p.id, tank = spec.source, arch = spec.arch, wk = spec.weaponKey, o = spec.origin, v = p.vel, r = p.radius, l = p.life, t = workspace:GetServerTimeNow(), heavy = false })
    return p
end

-- Validated discharge: the tank must be intact with an operational turret, the district must not be resetting.
-- `aim` is the world point the barrel is laid on (lead-corrected by the caller); the shell leaves along the real barrel.
local function fireShell(d, c, tank, aim: Vector3, now: number, exactAim: boolean?)
    local status = tank.status
    if not tank.arch or status.destroyed or not status.turretOperational or d.resetting then
        return nil
    end
    local arch = tank.arch
    local muzzle = TrainingTank.Muzzle(tank)
    local origin = muzzle.Position
    local forward = muzzle.LookVector
    local flatForward = V3(forward.X, 0, forward.Z)
    if flatForward.Magnitude < 1e-3 then
        return nil
    end
    flatForward = flatForward.Unit
    local to = aim - origin
    local horizontal = math.sqrt(to.X * to.X + to.Z * to.Z)
    local pitch = math.atan2(to.Y, math.max(horizontal, 1))
    local dir = flatForward * math.cos(pitch) + UP * math.sin(pitch)
    if exactAim then
        dir = to.Unit -- test and audit shots only
    else
        -- Imperfect crew: a random aim error inside a cone, never perfect.
        local ang = rng:NextNumber(0, 2 * math.pi)
        local mag = arch.spread * math.sqrt(rng:NextNumber())
        local cf = CFrame.lookAt(origin, origin + dir) * CFrame.Angles(math.sin(ang) * mag, math.cos(ang) * mag, 0)
        dir = cf.LookVector
    end
    tank.recoilAt = now
    return spawnShell(d, c, tank, dir, origin, to.Magnitude)
end

local function endShell(c, p, why: string, extra)
    local e = { k = "end", id = p.id, why = why, p = p.pos, arch = p.arch, heavy = p.heavy, r = p.radius, wk = p.wk }
    if extra then
        for key, value in pairs(extra) do
            e[key] = value
        end
    end
    emit(c, e)
end

-- Drops everything a given shooter still has in flight (that shooter was disabled or reset).
function TankCombat.CancelFrom(d, source: string)
    local c = combatOf(d)
    local keep = {}
    for _, p in ipairs(c.projectiles) do
        if p.tankId == source and p.bolt then
            endShell(c, p, "CANCEL")
            c.stats.cancelled += 1
        else
            table.insert(keep, p)
        end
    end
    c.projectiles = keep
end

local function cancelAll(d, c, why: string)
    for _, p in ipairs(c.projectiles) do
        endShell(c, p, why)
    end
    c.stats.cancelled += #c.projectiles
    c.projectiles = {}
end

-- A shell reached the Bastion's hull. Shield first (existing interface, existing energy economy), then components.
local function resolveMechHit(d, c, p, target, contact: Vector3, normal: Vector3)
    local session = target.session
    local dir = p.vel.Unit
    local attack = { category = p.category or "ballistic", damage = p.damage, fromX = -dir.X, fromZ = -dir.Z }
    local result = session.power and EnergySystems.ResolveImpact(session.power, attack, target.controller.state.yaw)
    local penetrating = if result then result.penetrating else p.damage
    local timing = if result then result.timing else "UNGUARDED"
    local prevented = if result then result.prevented else 0
    local stats = c.stats
    stats.mechHits += 1
    stats.prevented += prevented
    stats.penetrating += penetrating
    if timing == "PERFECT" then
        stats.perfect += 1
    elseif timing == "GUARD" then
        stats.guard += 1
    elseif timing == "OFF_AXIS" then
        stats.offAxis += 1
    else
        stats.unguarded += 1
    end
    local p0 = target.hullCF:PointToObjectSpace(contact)
    local hull = target.hull
    local region = MechDamage.RegionAt(p0.X, p0.Y, p0.Z, hull.width, hull.height, hull.depth)
    local mech = session.mech
    if mech and mech.Parent then
        mech:SetAttribute("LastHitRegion", region)
        mech:SetAttribute("LastHitTiming", timing)
        mech:SetAttribute("LastHitPrevented", math.floor(prevented * 10 + 0.5) / 10)
        mech:SetAttribute("LastHitPenetrating", math.floor(penetrating * 10 + 0.5) / 10)
        mech:SetAttribute("LastHitSerial", (mech:GetAttribute("LastHitSerial") or 0) + 1)
    end
    endShell(c, p, "MECH", { n = normal, region = region, timing = timing, prevented = prevented, pen = penetrating, dmg = p.damage, from = p.tankId })
    if penetrating > 0 then
        BastionDamage.Hit(session, region, penetrating)
    end
end

local function inBounds(d, pos: Vector3): boolean
    local o = d.origin
    return pos.Z >= o.Z + BOUNDS.minZ and pos.Z <= o.Z + BOUNDS.maxZ and math.abs(pos.X - o.X) <= BOUNDS.halfX
        and pos.Y >= o.Y + BOUNDS.minY and pos.Y <= o.Y + BOUNDS.maxY
end

local function stepShells(d, c, target, dt: number, now: number)
    local list = c.projectiles
    if #list == 0 then
        return
    end
    if not target then
        cancelAll(d, c, "CANCEL") -- evacuated, docked, ejected, left the district: nothing in flight may continue
        return
    end
    params.FilterDescendantsInstances = filterList(d)
    local hull = target.hull
    local keep = {}
    for _, p in ipairs(list) do
        p.age += dt
        local step = p.vel * dt
        local length = step.Magnitude
        local dir = step / length
        -- World: swept sphere against everything queryable (intact cover blocks, destroyed cover is gone).
        local worldHit = workspace:Spherecast(p.pos, p.radius, step, params)
        local worldDistance = if worldHit then worldHit.Distance else math.huge
        -- Bastion: ray against the authoritative hull box inflated by the shell radius (conservative swept sphere).
        local mechT, mnx, mny, mnz
        local local0 = target.hullCF:PointToObjectSpace(p.pos)
        local localDir = target.hullCF:VectorToObjectSpace(dir)
        mechT, mnx, mny, mnz = Math.rayBox(local0.X, local0.Y, local0.Z, localDir.X, localDir.Y, localDir.Z,
            hull.width / 2 + p.radius, hull.height / 2 + p.radius, hull.depth / 2 + p.radius, length)
        local done = false
        if mechT and mechT <= worldDistance then
            local centre = p.pos + dir * mechT
            local normal = target.hullCF:VectorToWorldSpace(V3(mnx :: number, mny :: number, mnz :: number))
            local contact = centre - normal * p.radius
            p.pos = centre
            resolveMechHit(d, c, p, target, contact, normal)
            done = true
        elseif worldHit then
            local inst = worldHit.Instance
            p.pos = p.pos + dir * worldHit.Distance
            Destructibles.Hit(inst, p.category or "ballistic", p.structure, now, { weapon = p.weaponId or Config.shellWeaponId, position = worldHit.Position, normal = worldHit.Normal, origin = p.origin })
            c.stats.worldHits += 1
            endShell(c, p, "WORLD", { p = worldHit.Position, n = worldHit.Normal })
            done = true
        end
        if not done then
            p.pos = p.pos + step
            if p.age >= p.life or not inBounds(d, p.pos) then
                c.stats.expired += 1
                endShell(c, p, "EXPIRE")
            else
                table.insert(keep, p)
            end
        end
    end
    c.projectiles = keep
end

-- Per-tank thinking and acting -------------------------------------------------------------------------------------------------
local function stepTank(d, c, tank, target, active: boolean, dt: number, now: number)
    local arch, ai, b = tank.arch, tank.ai, tank.build
    if not arch or not ai or not b or not b.model.Parent then
        return
    end
    local status = tank.status
    local s = {
        active = active, alive = not status.destroyed, canFire = status.turretOperational, canMove = status.mobile,
        resetting = d.resetting ~= nil, hasTarget = target ~= nil, range = math.huge, los = false, inArc = false, aimError = math.pi,
    }
    local relYaw: number? = nil
    local leadPoint: Vector3? = nil
    if target and s.alive and s.canFire and not s.resetting then
        local pos = tank.position
        s.range = flat(pos, target.position)
        if now - tank.losAt >= Config.losInterval then
            tank.losAt = now
            tank.losClear, tank.aimPoint = lineOfSight(d, tank, target)
        end
        s.los = tank.losClear
        local aim = tank.aimPoint or (target.position + V3(0, Config.sampleHeights[1], 0))
        local muzzle = TrainingTank.Muzzle(tank).Position
        local ax, az = Math.lead(muzzle.X, muzzle.Z, aim.X, aim.Z, target.velocity.X, target.velocity.Z, arch.shell.speed, arch.lead)
        leadPoint = V3(ax, aim.Y, az)
        relYaw = Math.wrap(math.atan2(-(ax - pos.X), -(az - pos.Z)) - tank.yaw)
        s.inArc = math.abs(relYaw) <= arch.traverse
        s.aimError = math.abs(Math.wrap(tank.turretYaw - math.clamp(relYaw, -arch.traverse, arch.traverse)))
    end
    local previous = ai.state
    local out = Brain.Step(ai, dt, s)
    tank.senses = s -- last perception, for the audit interface
    local model = tank.model
    if ai.state ~= previous then
        model:SetAttribute("AiState", ai.state)
        if ai.state == "AIM" then
            model:SetAttribute("AiWarn", arch.warnTime)
            model:SetAttribute("AiAimAt", workspace:GetServerTimeNow())
        end
    end

    -- Control hand-over: the stock patrol / scan code runs whenever the brain has no combat business with the tank.
    local scanning = out.turret == "scan" or ai.state == "DISABLED" or ai.state == "RESET"
    tank.control = if scanning then "idle" else "combat"
    tank.combatMoving = false
    if tank.control == "combat" and status.turretOperational then
        local rate = 0
        if out.turret == "track" then
            rate = arch.turretRate
        elseif out.turret == "aim" then
            rate = arch.turretRate * arch.aimRateScale
        end
        local want = if relYaw then math.clamp(relYaw, -arch.traverse, arch.traverse) else tank.turretYaw
        local yaw = tank.turretYaw + math.clamp(Math.wrap(want - tank.turretYaw), -rate * dt, rate * dt)
        local recoil = 0
        if tank.recoilAt then
            local age = now - tank.recoilAt
            if age < RECOIL_TIME then
                recoil = RECOIL * (1 - age / RECOIL_TIME) ^ 2
            else
                tank.recoilAt = nil
            end
        end
        if (yaw ~= tank.turretYaw or recoil ~= (tank.lastRecoil or 0)) and now - (tank.turretWriteAt or -1) >= TURRET_WRITE then
            tank.turretWriteAt, tank.lastRecoil = now, recoil
            TrainingTank.SetTurret(tank, yaw, recoil)
        elseif yaw ~= tank.turretYaw then
            tank.turretYaw = yaw -- keep the logical yaw current between weld writes
        end
    end
    if tank.control == "combat" and target and arch.mobility ~= "FIXED" then
        local move = out.move
        if (move == "reposition" or move == "slow") and status.mobile and arch.mobility == "ROUTE" then
            local goal = repositionGoal(d, tank, arch, target, now)
            if goal then
                local speed = (arch.engagedSpeed or 6) * (if move == "slow" then arch.slowFactor else 1)
                local remaining = TrainingTank.Steer(tank, goal, speed, tank.patrol and tank.patrol.turnRate or math.rad(20), dt)
                tank.combatMoving = remaining > 1.0
            end
        elseif move == "pivot" and arch.hullTurn then
            local pos = tank.position
            local heading = math.atan2(-(target.position.X - pos.X), -(target.position.Z - pos.Z))
            tank.combatMoving = math.abs(TrainingTank.Pivot(tank, heading, arch.hullTurn, dt)) > math.rad(1)
        end
    end

    if out.fire and leadPoint then
        fireShell(d, c, tank, leadPoint, now)
    end
end

-- Mode -------------------------------------------------------------------------------------------------------------------------
function TankCombat.SetMode(d, mode: string, reason: string?)
    local c = combatOf(d)
    if not Config.modes[mode] or c.mode == mode then
        return false
    end
    local previous = c.mode
    c.mode = mode
    c.armedAt = if mode == "ACTIVE" then os.clock() + Config.armDelay elseif mode == "MECH" then os.clock() + EnemyConfig.trial.armDelay else 0
    cancelAll(d, c, "CANCEL")
    if mode == "MECH" then
        EnemyMech.OnTrialStart(d) -- every trial begins against a fresh ROOK
        local session = d.owner and env and env.sessions[d.owner]
        if session then
            SortieReport.NoteTrialStart(session)
        end
    end
    d.folder:SetAttribute("CombatMode", mode)
    d.folder:SetAttribute("CombatReason", reason or "")
    d.folder:SetAttribute("CombatModeSerial", (d.folder:GetAttribute("CombatModeSerial") or 0) + 1)
    Destructibles.Notice(d, if mode == "ACTIVE" then "ACTIVE TRAINING - TANKS ARMING" elseif mode == "MECH" then "MECH TRIAL - ROOK-01 POWERING UP" elseif previous == "MECH" then "PASSIVE RANGE - ROOK-01 STANDING DOWN" else "PASSIVE RANGE - TANKS STAND DOWN", nil)
    return true
end

-- Range reset (called by RangeControl after the district accepted it). Tanks get fresh brains from their respawn; everything in
-- flight is cleared; a full reset also repairs the Bastion and refills its magazines (training convenience, not a rebalance).
function TankCombat.OnReset(d, kind: string)
    local c = combatOf(d)
    cancelAll(d, c, "RESET")
    c.armedAt = if c.mode == "ACTIVE" then os.clock() + Config.armDelay elseif c.mode == "MECH" then os.clock() + EnemyConfig.trial.armDelay else 0
    if kind == "ALL" or kind == "MECH" then
        local session = d.owner and env and env.sessions[d.owner]
        if session and session.mech and session.damage then
            BastionDamage.Repair(session)
            local weapons = session.weapons
            if weapons then
                for _, slot in pairs(weapons.slots) do
                    slot.ammo, slot.reloadAt, slot.nextShot = slot.spec.magazine, nil, 0
                end
            end
        end
        if kind == "ALL" then
            local stats = c.stats
            for key in pairs(stats) do
                stats[key] = 0
            end
        end
    end
end

function TankCombat.Reset(d, kind: string): boolean
    if d.destroyed or d.resetting then
        return false
    end
    local ok = Destructibles.Reset(d, kind)
    if ok then
        TankCombat.OnReset(d, kind)
    end
    return ok
end

-- Frame -----------------------------------------------------------------------------------------------------------------------
local PUBLISHED = { "shots", "mechHits", "perfect", "guard", "unguarded", "offAxis" }

function TankCombat.Step(now: number, dt: number)
    if not env then
        return
    end
    local started = os.clock()
    local aiTime, projTime = 0, 0
    dt = math.min(dt, 0.1)
    for _, d in pairs(Destructibles.Districts()) do
        if not d.destroyed then
            local c = combatOf(d)
            local target, session, sortieLive = targetOf(d)
            if c.mode ~= "PASSIVE" and session and not sortieLive then
                TankCombat.SetMode(d, "PASSIVE", "sortie ended") -- docking, ejection or core failure ends the training session (tanks and ROOK)
            end
            local active = c.mode == "ACTIVE" and now >= c.armedAt
            local trial = c.mode == "MECH" and now >= c.armedAt
            d.folder:SetAttribute("CombatArmed", active or trial)
            -- c.holdFire (test equipment only): tanks stand down but shells already in flight keep flying.
            local engage = active and not c.holdFire
            local t0 = os.clock()
            for _, tank in ipairs(d.vehicles) do
                stepTank(d, c, tank, if engage then target else nil, engage, dt, now)
            end
            -- M10C: the autonomous mech thinks, moves and fires after the tanks; its rounds fly in the same manager below.
            if d.rook then
                EnemyMech.Step(d, c, if c.holdFire then nil else target, trial and not c.holdFire, dt, now)
            end
            local t1 = os.clock()
            stepShells(d, c, if active or trial then target else nil, dt, now)
            local t2 = os.clock()
            aiTime += t1 - t0
            projTime += t2 - t1
            flush(d, c)
            if now - c.publishedAt >= 0.2 then
                c.publishedAt = now
                for _, key in ipairs(PUBLISHED) do
                    local name = "Combat" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
                    if c.published[name] ~= c.stats[key] then
                        c.published[name] = c.stats[key]
                        d.folder:SetAttribute(name, c.stats[key])
                    end
                end
            end
        end
    end
    local st = TankCombat.stats
    st.aiMs += (aiTime * 1000 - st.aiMs) * 0.05
    st.projMs += (projTime * 1000 - st.projMs) * 0.05
    st.aiWorst = math.max(st.aiWorst, aiTime * 1000)
    st.projWorst = math.max(st.projWorst, projTime * 1000)
    st.steps += 1
    st.totalMs = (os.clock() - started) * 1000
end

-- Test and audit hooks (server only; reached through the IronframeRangeAudit bindable, never by a client) --------------------
function TankCombat.DebugFire(d, tankIndex: number, aim: Vector3?, exact: boolean?)
    local tank = d.vehicles[tankIndex]
    local target = targetOf(d)
    local c = combatOf(d)
    if not tank or not tank.arch then
        return nil
    end
    local point = aim or (target and target.position + V3(0, Config.sampleHeights[1], 0))
    if not point then
        return nil
    end
    local p = fireShell(d, c, tank, point, os.clock(), exact)
    return p and p.id
end

function TankCombat.Audit(d)
    local c = combatOf(d)
    local tanks = {}
    for i, tank in ipairs(d.vehicles) do
        tanks[i] = { id = tank.id, arch = tank.arch and tank.arch.id, state = tank.ai and tank.ai.state, shots = tank.ai and tank.ai.shots, status = tank.status.status,
            control = tank.control, reason = tank.ai and tank.ai.lastReason, senses = tank.senses, turretYaw = math.deg(tank.turretYaw or 0), yaw = math.deg(tank.yaw), pos = tank.position }
    end
    local shells = {}
    for _, p in ipairs(c.projectiles) do
        table.insert(shells, { id = p.id, pos = p.pos, age = p.age, arch = p.arch })
    end
    return { mode = c.mode, armed = d.folder:GetAttribute("CombatArmed"), projectiles = #c.projectiles, shells = shells, stats = table.clone(c.stats), tanks = tanks,
        perf = table.clone(TankCombat.stats), events = #c.events, rook = EnemyMech.Audit(d) }
end

TankCombat.TargetOf = targetOf
TankCombat.CancelAll = cancelAll

return TankCombat
