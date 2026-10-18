-- Cockpit telemetry bus (M06A). Every instrument reads channels from here, and every gameplay system publishes to it.
-- Nothing in the UI invents data: a channel is LIVE (published by an authoritative system), DEMO (clearly marked
-- placeholder animation) or STANDBY (subsystem not implemented yet; no value is shown).
--
-- Future systems (movement, heat, damage, targeting, weapons) publish with Telemetry.Publish("heat.level", 41, "LIVE")
-- and the displays update without any UI rebuild. Subscribers are called with (key, channel) when a channel changes.

local Telemetry = {}

export type Channel = { value: any, status: string, updated: number }

local channels: { [string]: Channel } = {}
local subscribers: { (string, Channel) -> () } = {}

local STATUSES = { LIVE = true, DEMO = true, STANDBY = true }

function Telemetry.Publish(key: string, value: any, status: string?)
    status = status or "LIVE"
    assert(STATUSES[status :: string], "bad telemetry status " .. tostring(status))
    local channel = channels[key]
    if channel and channel.value == value and channel.status == status then
        return
    end
    channel = { value = value, status = status :: string, updated = os.clock() }
    channels[key] = channel
    for _, callback in ipairs(subscribers) do
        callback(key, channel)
    end
end

function Telemetry.Get(key: string): Channel
    return channels[key] or { value = nil, status = "STANDBY", updated = 0 }
end

function Telemetry.Value(key: string, default: any?): any
    local channel = channels[key]
    if channel and channel.value ~= nil then
        return channel.value
    end
    return default
end

-- Returns a disconnect function.
function Telemetry.Subscribe(callback: (string, Channel) -> ()): () -> ()
    table.insert(subscribers, callback)
    return function()
        local index = table.find(subscribers, callback)
        if index then
            table.remove(subscribers, index)
        end
    end
end

function Telemetry.Reset()
    table.clear(channels)
end

-- Channel catalogue. A STANDBY channel is one nothing publishes yet.
Telemetry.Keys = {
    -- published today by IronframeClient from the authoritative GetGarageState / StateChanged payload (LIVE)
    "mech.preset", "mech.presetOrder", "mech.state", "pilot.safe", "pilot.torsoYaw",
    "loadout.metrics", "loadout.mounts", "loadout.systems", "integrity.total", "diag.tests", "diag.rig",
    -- M08B: accepted server firing state and per-hardpoint magazines.
    "weapons.selected", "weapons.name", "weapons.state", "weapons.mode", "weapons.magazines", "weapons.ammo",
    "weapons.magazine", "weapons.power", "weapons.cost", "weapons.heat", "weapons.cooldown", "weapons.reload",
    "weapons.available", "weapons.shots", "weapons.hits", "weapons.lastTarget", "weapons.lastDamage",
    -- reserved for future systems; nothing publishes these yet, so the displays show STANDBY
    "heat.level", "integrity.sections", "movement.speed", "targeting.lock", "sensors.contacts",
    "energy.charge", "energy.capacity", "energy.output", "energy.demand", "energy.supply", "energy.capRate",
    "energy.thermal", "energy.propulsion", "energy.deficit", "energy.weaponDemand",
    -- M09: tactical energy profile and per-subsystem distribution
    "energy.profile", "energy.profilePending", "energy.profileEta", "energy.profileSerial", "energy.profileReason", "energy.focus",
    "energy.limited", "energy.weaponRate", "energy.shieldDemand", "energy.sprintDemand",
    "shield.state", "shield.cooldown", "shield.integrity", "shield.reason", "shield.timing",
    -- M10B: active tank combat and Bastion component damage (published by CombatHud from authoritative server attributes)
    "damage.regions", "damage.speed", "damage.reactor", "damage.disabled", "combat.threat", "combat.targets", "combat.lastHit",
    -- M11C: cockpit equipment and avionics. "avionics.state" is the latest server sensor packet (contacts, lock, thermal, capability);
    -- spec / label / bays come from the compiled build; demand / factor from the energy ledger's published attributes.
    "loadout.cockpit", "avionics.state", "avionics.spec", "avionics.label", "avionics.hasRadar", "avionics.baysUsed", "avionics.bays",
    "avionics.demand", "avionics.factor",
}

return Telemetry
