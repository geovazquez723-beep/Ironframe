local ChassisRegistry = require(script.Parent.ChassisRegistry)
local ComponentRegistry = require(script.Parent.ComponentRegistry)

local Compiler = {}

local function allowedFamily(families, value)
    for _, family in ipairs(families) do
        if family == value then
            return true
        end
    end
    return false
end

function Compiler.Compile(loadout)
    local issues = {}
    local metrics = {
        mass = 0, massLimit = 0, remainingMass = 0,
        powerDraw = 0, powerOutput = 0,
        heatPerSecond = 0, coolingPerSecond = 0,
        nominalDps = 0, integrity = 0, equippedWeapons = 0,
    }

    if type(loadout) ~= "table" then
        return { valid = false, issues = { "Loadout must be a table" }, metrics = metrics }
    end

    local chassis = ChassisRegistry[loadout.chassisId]
    if not chassis then
        return { valid = false, issues = { "Unknown chassis ID" }, metrics = metrics }
    end

    metrics.mass = chassis.dryMass
    metrics.massLimit = chassis.massLimit
    metrics.integrity = chassis.baseIntegrity

    local systems = loadout.systems
    if type(systems) ~= "table" then
        systems = {}
        table.insert(issues, "Missing systems map")
    end
    for _, slot in ipairs({ "reactor", "cooling", "armor" }) do
        local component = ComponentRegistry[systems[slot]]
        if not component or component.class ~= slot then
            table.insert(issues, "Invalid component for system slot: " .. slot)
        else
            metrics.mass += component.mass
            if slot == "reactor" then
                metrics.powerOutput += component.powerOutput
            elseif slot == "cooling" then
                metrics.coolingPerSecond += component.coolingPerSecond
            elseif slot == "armor" then
                metrics.integrity += component.integrityBonus
            end
        end
    end
    for slot in pairs(systems) do
        if slot ~= "reactor" and slot ~= "cooling" and slot ~= "armor" then
            table.insert(issues, "Unknown system slot: " .. tostring(slot))
        end
    end

    local mounts = loadout.mounts
    if type(mounts) ~= "table" then
        mounts = {}
        table.insert(issues, "Missing mounts map")
    end

    for socket, spec in pairs(chassis.hardpoints) do
        local componentId = mounts[socket]
        if componentId ~= nil then -- Empty sockets are valid.
            local component = ComponentRegistry[componentId]
            if not component or component.class ~= "weapon" then
                table.insert(issues, "Unknown weapon in " .. socket)
            elseif component.size > spec.size or not allowedFamily(spec.families, component.family) then
                table.insert(issues, "Incompatible weapon in " .. socket)
            else
                metrics.mass += component.mass
                metrics.powerDraw += component.powerDraw
                metrics.heatPerSecond += component.heatPerSecond
                metrics.nominalDps += component.nominalDps
                metrics.equippedWeapons += 1
            end
        end
    end
    for socket in pairs(mounts) do
        if not chassis.hardpoints[socket] then
            table.insert(issues, "Unknown weapon socket: " .. tostring(socket))
        end
    end

    metrics.remainingMass = metrics.massLimit - metrics.mass
    if metrics.remainingMass < -0.0001 then
        table.insert(issues, "Mass limit exceeded")
    end
    if metrics.powerDraw > metrics.powerOutput then
        table.insert(issues, "Reactor power budget exceeded")
    end

    -- Excess weapon heat is deliberately a tactical tradeoff, not a build error.
    -- The future combat simulation must model throttling/overheat honestly.
    metrics.netHeatPerSecond = metrics.heatPerSecond - metrics.coolingPerSecond
    return { valid = #issues == 0, issues = issues, metrics = metrics }
end

return Compiler
