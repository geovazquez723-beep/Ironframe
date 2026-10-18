-- Combat actor registry for the avionics (M11C). Adapts every kind of combat actor in a district into the flat TargetContract table, so the
-- sensor service is written once and a future chassis or drone only registers another provider here.
--
-- Providers read live authoritative state (training tanks, ROOK-01, the training mech); nothing here holds its own copy of any machine.
-- A provider returns the actors of ONE district; the pilot's own Bastion is never an actor (a sensor does not target its own machine).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Contract = require(Shared:WaitForChild("TargetContract"))
local Damage = require(Shared:WaitForChild("MechDamage"))
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))

local Registry = {}

local V3 = Vector3.new
local providers: { { name: string, collect: (any, number) -> { any } } } = {}

function Registry.Register(name: string, collect: (any, number) -> { any })
    for i, p in ipairs(providers) do
        if p.name == name then
            providers[i] = { name = name, collect = collect }
            return
        end
    end
    table.insert(providers, { name = name, collect = collect })
end

function Registry.Names(): { string }
    local list = {}
    for _, p in ipairs(providers) do
        table.insert(list, p.name)
    end
    return list
end

-- Every valid actor of the district. A provider that errors or returns malformed actors is skipped (and warned once), never fatal.
local warned: { [string]: boolean } = {}
function Registry.Collect(district: any, now: number): { any }
    local out = {}
    for _, provider in ipairs(providers) do
        local ok, list = pcall(provider.collect, district, now)
        if ok and type(list) == "table" then
            for _, actor in ipairs(list) do
                local valid, why = Contract.Validate(actor)
                if valid then
                    table.insert(out, actor)
                elseif not warned[provider.name] then
                    warned[provider.name] = true
                    warn("[IF-AVIONICS] provider", provider.name, "returned a bad actor:", why)
                end
            end
        elseif not ok and not warned[provider.name] then
            warned[provider.name] = true
            warn("[IF-AVIONICS] provider", provider.name, "failed:", list)
        end
    end
    return out
end

-- Tanks --------------------------------------------------------------------------------------------------------------------------
local TANK_SIZE = V3(15, 11, 22) -- includes the barrel overhang; the tracking box is drawn from it
local TANK_PARTS = { { "HULL", "HULL" }, { "TURRET", "TURRET" }, { "TRACK_L", "L TRACK" }, { "TRACK_R", "R TRACK" }, { "ENGINE", "ENGINE" } }

Registry.Register("tanks", function(d, _)
    local list = {}
    for _, tank in ipairs(d.vehicles) do
        local model = tank.model
        if tank.status and tank.position and model and model.Parent then
            local status = tank.status
            local arch = tank.arch
            local topSpeed = (tank.patrol and tank.patrol.speed) or (arch and arch.engagedSpeed) or 5
            table.insert(list, {
                id = tank.id, label = tank.id, kind = "VEHICLE", arch = arch and arch.label or nil,
                x = tank.position.X, y = tank.position.Y + TANK_SIZE.Y * 0.5, z = tank.position.Z, yaw = tank.yaw, speed = 0, derive = true, speedMax = topSpeed,
                operational = status.turretOperational and not status.destroyed, disabled = status.destroyed or not status.turretOperational, destroyed = status.destroyed,
                powered = not status.destroyed and not status.engineLost, burning = status.engineLost or status.destroyed,
                shotCounter = tank.ai and tank.ai.shots or 0, size = TANK_SIZE, samples = { -1.5, 1.5 }, model = model,
                components = function()
                    local out = {}
                    for _, part in ipairs(TANK_PARTS) do
                        local unit = tank.units and tank.units[part[1]]
                        if unit then
                            table.insert(out, { key = part[1], name = part[2], fraction = math.clamp(unit.health / unit.capacity, 0, 1), offline = unit.stage == "DESTROYED" })
                        end
                    end
                    return out
                end,
            })
        end
    end
    return list
end)

-- ROOK-01 (autonomous mech) ------------------------------------------------------------------------------------------------------
local ROOK_SIZE = V3(16, 22, 14)

Registry.Register("rook", function(d, _)
    local rook = d.rook
    if not rook or not rook.model or not rook.model.Parent or not rook.controller then
        return {}
    end
    local s = rook.controller.state
    local thermal = rook.power and rook.power.energy.thermal or 0
    return { {
        id = rook.def.callsign, label = rook.def.callsign, kind = "MECH", arch = rook.def.short,
        x = s.x, y = s.y + ROOK_SIZE.Y * 0.5, z = s.z, yaw = s.yaw, speed = s.speed, speedMax = rook.controller.params.maxForward or 16,
        operational = not rook.down, disabled = rook.down == true, destroyed = rook.down == true and rook.status == "DISABLED",
        powered = not rook.down, reactorHeat = math.clamp(thermal / 100, 0, 1), burning = rook.down == true and rook.status == "DISABLED",
        shotCounter = rook.counters.rounds, size = ROOK_SIZE, samples = { -3, 4 }, model = rook.model,
        components = function()
            local out = {}
            for _, region in ipairs(CombatConfig.mech.order) do
                local fraction = Damage.Fraction(rook.unit.damage, region)
                table.insert(out, { key = region, name = CombatConfig.mech.names[region], fraction = fraction, offline = fraction <= 0 })
            end
            return out
        end,
    } }
end)

-- Training mech (M-01, unmanned stationary target) --------------------------------------------------------------------------------
Registry.Register("trainingMech", function(d, _)
    local mech = d.mech
    if not mech or not mech.model or not mech.model.Parent or not mech.status then
        return {}
    end
    local down = mech.status.disabled == true
    return { {
        id = mech.id, label = mech.id, kind = "MECH", arch = "TRAINING",
        x = mech.position.X, y = mech.position.Y + 9, z = mech.position.Z, yaw = mech.yaw, speed = 0, speedMax = 1,
        operational = false, disabled = true, destroyed = down, powered = false, burning = false,
        shotCounter = 0, size = V3(14, 20, 12), samples = { -3, 4 }, model = mech.model,
        components = function()
            local out = {}
            for _, name in ipairs({ "CHASSIS", "ARM_MOUNT", "SHOULDER_ARMOR", "LEG_ASSEMBLY" }) do
                local unit = mech.units and mech.units[name]
                if unit then
                    table.insert(out, { key = name, name = string.gsub(name, "_", " "), fraction = math.clamp(unit.health / unit.capacity, 0, 1), offline = unit.stage == "DESTROYED" })
                end
            end
            return out
        end,
    } }
end)

return Registry
