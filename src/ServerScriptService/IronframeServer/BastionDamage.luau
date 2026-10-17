-- Server adapter for the Bastion's component-damage model (M10B). The rules live in the pure MechDamage module; this file maps
-- world hits into the hull's frame, applies the mechanical consequences to the REAL systems (drive, reactor output, weapon mounts)
-- and publishes a compact, change-only attribute set for the cockpit and the damage visuals.
--
-- Nothing here touches the pilot. Core failure is a machine event; the owner (Main) answers it with the existing guaranteed-safe
-- ejection through `BastionDamage.onCoreFailure`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Damage = require(Shared:WaitForChild("MechDamage"))
local Config = require(Shared:WaitForChild("CombatConfig"))
local Locomotion = require(script.Parent.Locomotion)
local EnergySystems = require(script.Parent.EnergySystems)

local BastionDamage = {}

-- Set by Main: function(player, session) that runs the existing safe-ejection sequence. Called at most once per sortie.
BastionDamage.onCoreFailure = nil :: ((session: any) -> ())?

local function round2(n: number): number
    return math.floor(n * 100 + 0.5) / 100
end

function BastionDamage.Create(session)
    session.damage = Damage.New()
    session.damageFx = Damage.Effects(session.damage)
    session.damagePublished = {}
    session.coreFailureHandled = false
    BastionDamage.Publish(session, true)
end

function BastionDamage.Publish(session, force: boolean?)
    local model, state = session.mech, session.damage
    if not model or not model.Parent or not state then
        return
    end
    local published = session.damagePublished
    local function set(name: string, value: any)
        if published[name] ~= value then
            published[name] = value
            model:SetAttribute(name, value)
        end
    end
    for _, region in ipairs(Damage.Regions) do
        set("Dmg_" .. region, round2(Damage.Fraction(state, region)))
    end
    local fx = session.damageFx
    local off = {}
    for socket in pairs(fx.sockets) do
        table.insert(off, socket)
    end
    table.sort(off)
    set("DmgDisabledSockets", table.concat(off, ","))
    set("DmgSpeedFactor", round2(fx.speed))
    set("DmgReactorFactor", round2(fx.reactor))
    set("DmgCoreFailed", state.coreFailed)
    set("DmgHits", state.hits)
    if force then
        model:SetAttribute("DmgSerial", state.serial)
    elseif published.serial ~= state.serial then
        published.serial = state.serial
        model:SetAttribute("DmgSerial", state.serial)
    end
end

-- Re-derives and applies every mechanical consequence. Safe to call at any time (new controller after a deploy, after a hit).
function BastionDamage.Apply(session)
    local state = session.damage
    if not state then
        return nil
    end
    local fx = Damage.Effects(state)
    session.damageFx = fx
    if session.controller then
        Locomotion.SetMobility(session.controller, fx.speed, fx.turn)
    end
    if session.power then
        EnergySystems.SetReactorScale(session.power, fx.reactor)
    end
    return fx
end

-- World point -> region, using the controller's authoritative hull box.
function BastionDamage.RegionAt(session, worldPoint: Vector3): string
    local c = session.controller
    local hull = c.params.hull
    local cf = Locomotion.HullPose(c.params, c.state)
    local p = cf:PointToObjectSpace(worldPoint)
    return Damage.RegionAt(p.X, p.Y, p.Z, hull.width, hull.height, hull.depth)
end

-- Applies PENETRATING damage to `region`. Returns the Damage.Apply result (empty when the mech cannot be damaged right now).
function BastionDamage.Hit(session, region: string, amount: number)
    local state = session.damage
    if not state or state.coreFailed or session.machineState ~= "OPERATIONAL" then
        return nil
    end
    local result = Damage.Apply(state, region, amount)
    BastionDamage.Apply(session)
    BastionDamage.Publish(session)
    if result.coreFailed and not session.coreFailureHandled then
        session.coreFailureHandled = true
        session.mech:SetAttribute("DmgCoreFailed", true)
        if BastionDamage.onCoreFailure then
            BastionDamage.onCoreFailure(session)
        end
    end
    return result
end

-- Full repair (docking, range reset, new assembly). Weapon mounts, legs and reactor all return to nominal.
function BastionDamage.Repair(session)
    local state = session.damage
    if not state then
        return
    end
    Damage.Reset(state)
    session.coreFailureHandled = false
    BastionDamage.Apply(session)
    BastionDamage.Publish(session, true)
end

function BastionDamage.SocketDisabled(session, socket: string): boolean
    return session.damageFx ~= nil and session.damageFx.sockets[socket] == true
end

-- Test and audit snapshot.
function BastionDamage.Snapshot(session)
    local state = session.damage
    if not state then
        return nil
    end
    local out = { regions = {}, hits = state.hits, taken = state.taken, coreFailed = state.coreFailed }
    for _, region in ipairs(Damage.Regions) do
        out.regions[region] = state.health[region]
    end
    local fx = session.damageFx
    out.speed, out.turn, out.reactor = fx.speed, fx.turn, fx.reactor
    out.sockets = {}
    for socket in pairs(fx.sockets) do
        table.insert(out.sockets, socket)
    end
    table.sort(out.sockets)
    out.config = Config.mech.regions
    return out
end

return BastionDamage
