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
local ServerScriptService = game:GetService("ServerScriptService")

local RangeControl = {}

local KINDS = { ALL = true, VEHICLES = true, STRUCTURES = true }
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
            Destructibles.Reset(district, kind)
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
            return Destructibles.Reset(d, a or "ALL")
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
                out.vehicles[i] = { id = tank.id, status = tank.status.status, pos = tank.position }
            end
            return out
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
