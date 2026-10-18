-- Pure authoritative component-damage model for the deployed Bastion (M10B). Six regions - core torso, left/right weapon
-- assemblies, left/right leg assemblies, reactor housing - each with its own health and a mechanical consequence.
--
-- Pilots are deliberately NOT part of this model. Core failure is a machine event; the server answers it with the existing
-- guaranteed-safe ejection and nothing here knows or cares who is inside.
--
-- No Roblox types: the server maps world hits into the hull's local frame and hands plain numbers to RegionAt.

local Config = if script then require((script :: any).Parent.CombatConfig) else require("./CombatConfig" :: any)

local Damage = {}

Damage.Regions = Config.mech.order

export type State = {
    health: { [string]: number },
    capacity: { [string]: number },
    hits: number,
    taken: number, -- total penetrating damage applied
    coreFailed: boolean,
    serial: number, -- increments on every applied hit
}

-- `capacities` (optional, M10C) overrides the per-region health, e.g. for an autonomous opponent with its own armour. Region names,
-- spill and consequences stay the shared Bastion conventions.
function Damage.New(capacities: { [string]: number }?): State
    local health, capacity = {}, {}
    for region, hp in pairs(Config.mech.regions) do
        local value = if capacities and capacities[region] then capacities[region] else hp
        health[region], capacity[region] = value, value
    end
    return { health = health, capacity = capacity, hits = 0, taken = 0, coreFailed = false, serial = 0 }
end

function Damage.Reset(s: State)
    for region, hp in pairs(s.capacity) do
        s.health[region] = hp
    end
    s.hits, s.taken, s.coreFailed = 0, 0, false
    s.serial += 1
end

function Damage.Fraction(s: State, region: string): number
    return math.clamp(s.health[region] / s.capacity[region], 0, 1)
end

-- OK / DAMAGED / CRITICAL / FAILED
function Damage.Stage(fraction: number): string
    if fraction <= 0 then
        return "FAILED"
    elseif fraction <= Config.mech.criticalAt then
        return "CRITICAL"
    elseif fraction <= Config.mech.damagedAt then
        return "DAMAGED"
    end
    return "OK"
end

-- Maps a point in the hull box's local frame (origin at the centre; +X right, +Y up, +Z back) to a damage region.
-- lx, ly, lz are the local coordinates, w/h/d the full box size. Front hits split into legs / arms / core by where they land;
-- anything in the rear third above the legs reaches the reactor housing.
function Damage.RegionAt(lx: number, ly: number, lz: number, w: number, h: number, d: number): string
    local c = Config.mech
    local nx = math.clamp(lx / (w / 2), -1, 1)
    local ny = math.clamp((ly + h / 2) / h, 0, 1)
    local nz = math.clamp(lz / (d / 2), -1, 1)
    if ny < c.legBelow then
        return if nx < 0 then "LEG_L" else "LEG_R"
    elseif nz > c.reactorBehind then
        return "REACTOR"
    elseif math.abs(nx) > c.armBeyond then
        return if nx < 0 then "ARM_L" else "ARM_R"
    end
    return "CORE"
end

-- Applies PENETRATING damage (already past the shield) to `region`; a share spills onto the core. Returns
-- { applied = {region -> amount}, destroyed = {region...}, stageChanged = {region -> newStage}, coreFailed }.
function Damage.Apply(s: State, region: string, amount: number)
    local result = { applied = {}, destroyed = {}, stageChanged = {}, coreFailed = false, region = region }
    if s.coreFailed or amount ~= amount or amount <= 0 or s.health[region] == nil then
        return result
    end
    local function hit(r: string, a: number)
        local before = s.health[r]
        if before <= 0 or a <= 0 then
            return
        end
        local stageBefore = Damage.Stage(before / s.capacity[r])
        s.health[r] = math.max(0, before - a)
        if s.health[r] < 1e-6 then
            s.health[r] = 0
        end
        local dealt = before - s.health[r]
        result.applied[r] = (result.applied[r] or 0) + dealt
        s.taken += dealt
        local stageAfter = Damage.Stage(s.health[r] / s.capacity[r])
        if stageAfter ~= stageBefore then
            result.stageChanged[r] = stageAfter
        end
        if s.health[r] <= 0 then
            table.insert(result.destroyed, r)
        end
    end
    hit(region, amount)
    if region ~= "CORE" then
        hit("CORE", amount * Config.mech.spill)
    end
    s.hits += 1
    s.serial += 1
    if s.health.CORE <= 0 then
        s.coreFailed = true
        result.coreFailed = true
    end
    return result
end

-- Mechanical consequences of the current state:
--   speed    0..1 multiplier on drive performance (legs)     turn   multiplier on steering authority
--   reactor  0..1 multiplier on reactor output               sockets  { [socketName] = true } weapon mounts that are offline
function Damage.Effects(s: State)
    local c = Config.mech
    local loss = 0
    for _, region in ipairs({ "LEG_L", "LEG_R" }) do
        local f = Damage.Fraction(s, region)
        loss += c.leg.perDamage * (1 - f) + (if f <= 0 then c.leg.destroyed else 0)
    end
    local speed = math.max(c.leg.floor, 1 - loss)
    local rf = Damage.Fraction(s, "REACTOR")
    local reactor = math.max(c.reactor.floor, 1 - (c.reactor.perDamage * (1 - rf) + (if rf <= 0 then c.reactor.destroyed else 0)))
    local sockets = {}
    for region, list in pairs(c.sockets) do
        if Damage.Fraction(s, region) <= 0 then
            for _, socket in ipairs(list) do
                sockets[socket] = true
            end
        end
    end
    return { speed = speed, turn = math.sqrt(speed), reactor = reactor, sockets = sockets, coreFailed = s.coreFailed }
end

-- Rig-part classification for visuals (client): which region a part of the Bastion model belongs to.
-- name/joint/group are the part's Name and its Joint / Group attributes; localX is the sign of its rig-local X (arms and
-- shoulder armour on the Torso joint are sided by position).
function Damage.ClassifyPart(name: string, joint: string?, group: string?, localX: number?): string
    if group == "reactor" then
        return "REACTOR"
    end
    if joint then
        local tag = string.match(joint, "^Shoulder(%u)$") or string.match(joint, "^Elbow(%u)$")
        if tag then
            return "ARM_" .. tag
        end
        tag = string.match(joint, "^Thigh(%u)$") or string.match(joint, "^Knee(%u)$") or string.match(joint, "^Ankle(%u)$")
        if tag then
            return "LEG_" .. tag
        end
    end
    local socket = string.match(name, "^Weapon_(%a+_%a+)_") or string.match(name, "^Mount_(%a+_%a+)")
    if socket then
        if string.find(socket, "^left_arm") or string.find(socket, "^left_shoulder") then
            return "ARM_L"
        elseif string.find(socket, "^right_arm") or string.find(socket, "^right_shoulder") then
            return "ARM_R"
        end
    end
    if string.find(name, "^Pauldron") or string.find(name, "^ShoulderLame") or string.find(name, "^ReinforcedPauldron") or string.find(name, "^ShoulderMarker") then
        return if (localX or 0) < 0 then "ARM_L" else "ARM_R"
    end
    return "CORE"
end

-- Socket -> owning region (nil for the core-mounted torso sockets).
function Damage.SocketRegion(socket: string): string?
    for region, list in pairs(Config.mech.sockets) do
        if table.find(list, socket) then
            return region
        end
    end
    return nil
end

return Damage
