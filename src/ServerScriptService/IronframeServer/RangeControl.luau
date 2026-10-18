-- Range control (M10A): owns the two remotes of the testing district and ties each district to its pilot's session.
--
--   DestructionFx       server -> owner client: batched cosmetic events (impact, destruction, notices, clear)
--   RequestRangeReset   owner client -> server: "ALL" | "VEHICLES" | "STRUCTURES"
--
-- The server validates everything: the kind is an allow-listed string, the pilot must be deployed and operational, requests are
-- rate limited, and a reset only ever touches the pilot's own bay. A reset restores authoritative health, collision, models
-- and effects; it never reloads the place and never touches the hangar.

local Destructibles = require(script.Parent.Destructibles)
local CombatTargets = require(script.Parent.CombatTargets)
local TankCombat = require(script.Parent.TankCombat) -- M10B
local EnemyMech = require(script.Parent.EnemyMech) -- M10C
local BastionDamage = require(script.Parent.BastionDamage) -- M10B
local Locomotion = require(script.Parent.Locomotion) -- M10B (test teleport / input only)
local EnergySystems = require(script.Parent.EnergySystems) -- M10B (test shield only)
local HitDebug = require(script.Parent.HitDebug) -- M11B (Studio-only diagnostic overlay)
local MechHit = require(script.Parent.MechHit) -- M11B
local Weapons = require(script.Parent.Weapons) -- M11B (audit shots use the production strike path)
local AvionicsService = require(script.Parent.AvionicsService) -- M11C (audit snapshot and test commands)
local ServerScriptService = game:GetService("ServerScriptService")

local RangeControl = {}

local KINDS = { ALL = true, VEHICLES = true, STRUCTURES = true, MECH = true } -- MECH (M10C): rebuild ROOK-01, repair and rearm the Bastion
local MIN_INTERVAL = 1.5
local ZONE_MIN_Z = 322
local HANGAR_MAX_Z = 60

local sessionsRef: { [Player]: any } = {}
local installAuditInterface

function RangeControl.Init(fxRemote: RemoteEvent, resetRemote: RemoteEvent, sessions: { [Player]: any })
    sessionsRef = sessions
    Destructibles.SetRemote(fxRemote)
    installAuditInterface(sessions)
    resetRemote.OnServerEvent:Connect(function(player, kind)
        local session = sessions[player]
        if not session or type(kind) ~= "string" or not KINDS[kind] then
            return
        end
        if session.deployment ~= "ACTIVE" or session.machineState ~= "OPERATIONAL" or not session.bay then
            return
        end
        local now = os.clock()
        if now - (session.lastRangeReset or -100) < MIN_INTERVAL then
            return
        end
        session.lastRangeReset = now
        local district = Destructibles.Get(session.bay)
        if district then
            TankCombat.Reset(district, kind) -- Destructibles.Reset plus the combat state (shells in flight, Bastion repair on ALL)
        end
    end)
end

-- Server-only test interface (a BindableFunction is not reachable from clients). It exercises the SAME modules and hit path as
-- production: "audit", "reset" kind, "stats", "part" (module name | "tank",index,comp | "mech",comp), "fire" part weaponId shots.
installAuditInterface = function(sessions: { [Player]: any })
    local bindable = Instance.new("BindableFunction")
    bindable.Name = "IronframeRangeAudit"
    local Components = require(game.ReplicatedStorage.IronframeShared.ComponentRegistry)
    local function districtOf(player: Player?)
        for p, session in pairs(sessions) do
            if (not player or p == player) and session.bay then
                return Destructibles.Get(session.bay)
            end
        end
        return nil
    end
    bindable.OnInvoke = function(command, a, b, c)
        local d = districtOf(nil)
        if not d then
            return nil
        end
        if command == "audit" then
            local audit = Destructibles.Audit(d)
            audit.stepMs, audit.worstMs, audit.steps = Destructibles.stats.stepMs, Destructibles.stats.worstMs, Destructibles.stats.steps
            audit.stats = d.stats
            audit.persistentEmitters = d.persistentEmitters
            return audit
        elseif command == "reset" then
            return TankCombat.Reset(d, a or "ALL")
        elseif command == "part" then
            if a == "tank" then
                local tank = d.vehicles[b]
                return tank and tank.build.groups[c].hit[1]
            elseif a == "mech" then
                for _, v in ipairs(d.mech.volumes) do
                    if v.component == b then
                        return v.part
                    end
                end
                return nil
            end
            for _, m in ipairs(d.modules) do
                if m.name == a then
                    return m.part
                end
            end
            return nil
        elseif command == "fire" then
            local spec = Components[b].combat
            local total = 0
            for _ = 1, c or 1 do
                total += CombatTargets.Hit(a, spec.category, spec.damage, os.clock(), { weapon = b, position = a.Position + Vector3.new(0, 0, -a.Size.Z / 2 - 0.1), normal = Vector3.new(0, 0, -1) })
            end
            return total
        elseif command == "state" then
            local out = { vehicles = {}, mech = d.mech and d.mech.status.status, modules = #d.modules }
            for i, tank in ipairs(d.vehicles) do
                out.vehicles[i] = { id = tank.id, status = tank.status.status, pos = tank.position, ai = tank.ai and tank.ai.state }
            end
            return out
        -- M10B combat audit / test commands. They drive the SAME TankCombat / BastionDamage / shield paths as live play.
        elseif command == "combat" then
            return TankCombat.Audit(d)
        elseif command == "hold" then -- tanks stand down without leaving ACTIVE mode (isolates forced shells in tests)
            TankCombat.Of(d).holdFire = a == true
            return true
        elseif command == "mode" then
            return TankCombat.SetMode(d, a, "audit")
        elseif command == "dfire" then -- tank index, aim Vector3?, exact aim?
            return TankCombat.DebugFire(d, a, b, c)
        elseif command == "mech" then
            local session = d.owner and sessions[d.owner]
            return session and BastionDamage.Snapshot(session)
        elseif command == "hit" then -- region, penetrating damage (bypasses the shield: used to test components and ejection)
            local session = d.owner and sessions[d.owner]
            return session and BastionDamage.Hit(session, a, b) ~= nil
        elseif command == "repair" then
            local session = d.owner and sessions[d.owner]
            if session then
                BastionDamage.Repair(session)
            end
            return session ~= nil
        elseif command == "teleport" then -- Vector3 position, yaw (radians): places the deployed Bastion
            local session = d.owner and sessions[d.owner]
            if session and session.controller then
                Locomotion.Teleport(session.controller, a, b or 0)
                return true
            end
            return false
        elseif command == "testwall" then -- Vector3(x, _, z) bay-local, width, height: a temporary tall concrete wall (test equipment, removed by "untestwall")
            if d.testWall then
                return d.testWall.part
            end
            local size = Vector3.new(b or 24, c or 30, 3)
            d.testWall = Destructibles.AddModule(d, {
                name = "TestWall", material = "CONCRETE", surface = Enum.Material.Concrete, color = Color3.fromRGB(110, 112, 110), size = size,
                cf = CFrame.new(d.origin + Vector3.new(a.X, size.Y / 2, a.Z)), hp = 300,
            })
            return d.testWall.part
        elseif command == "untestwall" then
            local obj = d.testWall
            if obj then
                Destructibles.UnindexObject(obj)
                table.remove(d.modules, table.find(d.modules, obj))
                table.remove(d.objects, table.find(d.objects, obj))
                d.totals.sections -= 1
                obj.root:Destroy()
                d.testWall = nil
            end
            return obj ~= nil
        elseif command == "shield" then -- same call the RequestShield remote makes (rate limit aside)
            local session = d.owner and sessions[d.owner]
            if session and session.power then
                local ok, reason = EnergySystems.Activate(session.power, session.deployment == "ACTIVE")
                return ok, reason
            end
            return false, "no session"
        elseif command == "drain" then -- set capacitor charge (test equipment)
            local session = d.owner and sessions[d.owner]
            if session and session.power then
                session.power.energy.charge = a
                session.power.energy.tokens = math.min(session.power.energy.tokens, a)
                return true
            end
            return false
        elseif command == "drive" then -- throttle, steer, sprint: same sanitised input path as DriveInput
            local session = d.owner and sessions[d.owner]
            if session and session.controller then
                Locomotion.SetInput(session.controller, a, b, c)
                return true
            end
            return false
        elseif command == "session" then
            local session = d.owner and sessions[d.owner]
            if not session then
                return nil
            end
            local s = session.controller and session.controller.state
            return { machineState = session.machineState, pilotSafe = session.pilotSafe, deployment = session.deployment, pilotTargetable = session.pilotTargetable,
                x = s and s.x, y = s and s.y, z = s and s.z, yaw = s and s.yaw, speed = s and s.speed, shield = session.power and session.power.shield.state,
                shieldReason = session.power and session.power.shield.reason, charge = session.power and session.power.energy.charge,
                output = session.power and session.power.energy.output, power = session.power and session.power.energy.reactorSupply,
                ammo = session.weapons and session.weapons.shots }
        elseif command == "target" then
            local target = TankCombat.TargetOf(d)
            return target ~= nil
        -- M11A: the compiled build and what the deployed runtime actually uses (tests compare the two)
        elseif command == "build" then
            local session = d.owner and sessions[d.owner]
            if not session or not session.compiled then
                return nil
            end
            local c, power, ctrl = session.compiled, session.power, session.controller
            return {
                label = c.label, loadout = session.loadout, customized = session.customized, stats = c.stats, structure = c.structure, weapons = c.weapons,
                runtime = {
                    maxForward = ctrl and ctrl.params.maxForward, turnRate = ctrl and ctrl.params.turnRate, accelForward = ctrl and ctrl.params.accelForward,
                    capacity = power.config.capacity, baseOutput = power.baseOutput or power.config.output, output = power.config.output, thermalPerEnergy = power.config.thermalPerEnergy,
                    movementDrive = power.config.movement.drive, damageCapacity = session.damage and session.damage.capacity, damageHealth = session.damage and session.damage.health,
                    mounts = session.loadout.mounts, topSpeedAttr = session.mech and session.mech:GetAttribute("TopSpeed"), reactorScale = power.reactorScale,
                },
                lastSortie = session.lastSortie,
            }
        -- M10C audit / test commands for ROOK-01. They use the same Destructibles.Hit / shield / brain paths as live play.
        elseif command == "rook" then
            return EnemyMech.Audit(d)
        elseif command == "rookpart" then -- region -> world point of its largest fitted volume (CORE | ARM_L | ARM_R | LEG_L | LEG_R | REACTOR)
            return d.rook and EnemyMech.RegionPoint(d.rook, a)
        elseif command == "rookhit" then -- region, weaponId, shots, origin Vector3?: shots resolved exactly like the player's weapon hits (analytic volume path)
            local rook = d.rook
            if not rook then
                return nil
            end
            local point = EnemyMech.RegionPoint(rook, a)
            if not point then
                return nil
            end
            local spec = Components[b].combat
            local total = 0
            for _ = 1, c or 1 do
                local hit = { district = d, object = rook, comp = a, position = point, normal = Vector3.new(0, 0, -1) }
                total += Destructibles.HitVolume(hit, spec.category, spec.damage, { weapon = b, origin = rook.hitOrigin })
            end
            return total
        elseif command == "rookorigin" then -- Vector3 | nil: where "test" shooters stand (for the directional shield)
            if d.rook then
                d.rook.hitOrigin = a
            end
            return true
        elseif command == "rookteleport" then -- x, z (world), yaw: test placement only (never used by the AI)
            local rook = d.rook
            if rook then
                Locomotion.Teleport(rook.controller, Vector3.new(a, rook.groundY, b), c or 0)
                rook.route, rook.goal = nil, nil
                return true
            end
            return false
        elseif command == "rookdrain" then -- set ROOK's capacitor charge (test equipment)
            local rook = d.rook
            if rook then
                rook.power.energy.charge = a
                rook.power.energy.tokens = math.min(rook.power.energy.tokens, a)
                return true
            end
            return false
        -- M11B audit / test commands ---------------------------------------------------------------------------------------------
        elseif command == "hitdebug" then -- true | false: the Studio-only hit-geometry overlay (server-created, off by default)
            return HitDebug.Set(a == true, d, Destructibles, function(folder)
                -- Fitted compound volumes (ROOK-01, the deployed Bastion) are plain tables: draw them as parts that follow the machine's chassis frame.
                local function draw(controller, volumes)
                    HitDebug.Track(function() return Locomotion.ChassisCFrame(controller) end, MechHit.Boxes(volumes))
                end
                if d.rook and d.rook.volumes then
                    draw(d.rook.controller, d.rook.volumes)
                end
                local session = d.owner and sessions[d.owner]
                if session and session.controller and session.mech then
                    draw(session.controller, MechHit.Build(session.mech))
                end
            end)
        elseif command == "shoot" then -- { origin, target, weapon, shots? }: the production hitscan strike (Weapons.Strike); returns what the ray registered
            local spec = Components[a.weapon].combat
            local dir = (a.target - a.origin).Unit
            local last, total, hits = nil, 0, 0
            for _ = 1, a.shots or 1 do
                last = Weapons.Strike(nil, a.origin, dir, spec, a.weapon, os.clock())
                total += last.damage
                if last.damage > 0 then
                    hits += 1
                end
            end
            local pos = last and last.endpoint
            local resolved = Destructibles.lastHit
            return { name = last and last.name, damage = total, hits = hits, position = pos, normal = last and last.normal, part = last and last.instance,
                comp = if last and last.damage > 0 and resolved then resolved.comp else nil }
        -- M11C avionics audit / test commands (server only; the real client path is the RequestAvionics remote)
        elseif command == "av" then
            local session = d.owner and sessions[d.owner]
            return session and AvionicsService.Audit(session)
        elseif command == "avcmd" then -- cmd, a, b: the same validated entry point the remote uses
            if d.owner then
                local session = sessions[d.owner]
                if session and session.av then
                    session.av.lastCommand = -10
                end
                AvionicsService.Command(d.owner, a, b, c)
                return true
            end
            return false
        elseif command == "avcharge" then -- set the Bastion's capacitor charge (starvation tests)
            local session = d.owner and sessions[d.owner]
            if session and session.power then
                session.power.energy.charge = a
                session.power.energy.tokens = math.min(session.power.energy.tokens, a)
                return true
            end
            return false
        elseif command == "rookwreck" then -- region, damage: penetrating damage straight to a region (component / terminal tests)
            local rook = d.rook
            return rook ~= nil and BastionDamage.Hit(rook.unit, a, b) ~= nil
        end
        return nil
    end
    bindable.Parent = ServerScriptService
end

-- Binds the district of `bay` to its pilot (effects and range readouts go only to that player).
function RangeControl.Attach(player: Player, bay: Model)
    local district = Destructibles.Get(bay)
    if district then
        district.owner = player
        district.folder:SetAttribute("OwnerUserId", player.UserId)
    end
end

function RangeControl.Detach(bay: Model)
    local district = Destructibles.Get(bay)
    if district then
        district.owner = nil
    end
end

-- Publishes which zone the pilot's mech is in. The hangar is a protected safe zone; weapons are only ever *effective*
-- against registered district modules, which all lie at or beyond the district gate.
function RangeControl.Step()
    for _, session in pairs(sessionsRef) do
        local c, mech = session.controller, session.mech
        if c and mech and mech.Parent then
            local localZ = c.state.z - session.bayPosition.Z
            local zone = if localZ < HANGAR_MAX_Z then "HANGAR" elseif localZ < ZONE_MIN_Z then "STAGING" else "DISTRICT"
            if mech:GetAttribute("RangeZone") ~= zone then
                mech:SetAttribute("RangeZone", zone)
            end
        elseif mech and mech.Parent and mech:GetAttribute("RangeZone") ~= nil then
            mech:SetAttribute("RangeZone", nil) -- docked, ejected or stowed: not in any range zone
        end
    end
end

return RangeControl
