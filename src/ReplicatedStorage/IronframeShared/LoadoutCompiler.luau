-- Loadout -> validated, effective build specification (M08A, extended in M11A).
--
-- THE single place where component choices become numbers. Everything downstream consumes the result of Compile and nothing else:
--   energy       EnergyConfig for EnergySystems (reactor output, capacitor, thermal behaviour, movement demand)
--   locomotion   the full effective drive parameter table for Locomotion.Create / MechDrive (hull and collision are the chassis' own)
--   structure    per-region health for MechDamage / BastionDamage (the existing six-region model, scaled; not a second health system)
--   weapons      per-socket effective weapon numbers read from the component registry (display and report only: firing itself reads
--                the same registry entries through WeaponState)
--   metrics      mass, power, heat, integrity ... (the existing garage / cockpit metrics)
-- Pure and deterministic: no Roblox types, no clock, no randomness. A loadout compiles to the same specification every time.
--
-- Request validation (what a client may ask for) lives next to it: Catalog (what the garage offers) and ApplyRequest (strict, whitelisted).

local ChassisRegistry = if script then require((script :: any).Parent.ChassisRegistry) else require("./ChassisRegistry" :: any)
local ComponentRegistry = if script then require((script :: any).Parent.ComponentRegistry) else require("./ComponentRegistry" :: any)
local EnergyConfig = if script then require((script :: any).Parent.EnergyConfig) else require("./EnergyConfig" :: any)
local CombatConfig = if script then require((script :: any).Parent.CombatConfig) else require("./CombatConfig" :: any)
local Avionics = if script then require((script :: any).Parent.Avionics) else require("./Avionics" :: any)
local CockpitLayouts = if script then require((script :: any).Parent.CockpitLayouts) else require("./CockpitLayouts" :: any)

local Compiler = {}

local function allowedFamily(families, value)
    for _, family in ipairs(families) do
        if family == value then
            return true
        end
    end
    return false
end

-- Garage catalog ---------------------------------------------------------------------------------------------------------------------
-- Weapon hardpoints the garage lets the player configure, and the system slots with their selectable components. Both derive from the
-- registry (`selectable = true`), so adding a component to the garage is a data change.
Compiler.ConfigurableSockets = { "left_arm", "right_arm", "left_shoulder", "right_shoulder" }
Compiler.ConfigurableSystems = { "reactor", "actuators", "armor" }
Compiler.SystemClass = { reactor = "reactor", actuators = "actuator", armor = "armor" }

local function sortedIds(filter: (string, any) -> boolean): { string }
    local ids = {}
    for id, component in pairs(ComponentRegistry) do
        if component.selectable and filter(id, component) then
            table.insert(ids, id)
        end
    end
    table.sort(ids, function(a, b)
        local ca, cb = ComponentRegistry[a], ComponentRegistry[b]
        if (ca.mass or 0) ~= (cb.mass or 0) then
            return (ca.mass or 0) < (cb.mass or 0)
        end
        return a < b
    end)
    return ids
end

-- Selectable weapons that physically fit `socket` on `chassisId` (size and family), implemented ones only (they have a `combat` entry).
function Compiler.WeaponOptions(chassisId: string, socket: string): { string }
    local chassis = ChassisRegistry[chassisId]
    local spec = chassis and chassis.hardpoints[socket]
    if not spec or not table.find(Compiler.ConfigurableSockets, socket) then
        return {}
    end
    return sortedIds(function(_, c)
        return c.class == "weapon" and c.combat ~= nil and c.size <= spec.size and allowedFamily(spec.families, c.family) and c.combat.hardpoints[socket] == true
    end)
end

function Compiler.SystemOptions(slot: string): { string }
    local class = Compiler.SystemClass[slot]
    if not class then
        return {}
    end
    return sortedIds(function(_, c) return c.class == class end)
end

-- M11C: cockpit packages the chassis' frame accepts, and the avionics modules a slot may hold. Both derive from `selectable` registry entries.
Compiler.AvionicsSlots = Avionics.Slots

function Compiler.CockpitOptions(chassisId: string): { string }
    local chassis = ChassisRegistry[chassisId]
    local spec = chassis and chassis.cockpit
    if not spec then
        return {}
    end
    return sortedIds(function(id, c)
        return c.class == "cockpit" and table.find(spec.packages, id) ~= nil and table.find(c.layouts, spec.layout) ~= nil
    end)
end

function Compiler.AvionicsOptions(chassisId: string, slot: string): { string }
    local chassis = ChassisRegistry[chassisId]
    if not chassis or not chassis.cockpit or not table.find(Avionics.Slots, slot) then
        return {}
    end
    return sortedIds(function(_, c)
        return c.class == "avionics" and c.slot == slot
    end)
end

-- The cockpit package and avionics a loadout actually wears: its own explicit choices, else the chassis' factory equipment.
function Compiler.CockpitOf(loadout: any): (string?, { [string]: string }?)
    local chassis = ChassisRegistry[loadout.chassisId]
    local spec = chassis and chassis.cockpit
    if not spec then
        return nil, nil
    end
    local avionics = loadout.avionics
    if avionics == nil then
        avionics = spec.defaultAvionics
    end
    return loadout.cockpit or spec.defaultPackage, avionics
end

-- Effective-value helpers -----------------------------------------------------------------------------------------------------------
local LOCOMOTION_SCALED = {
    { "maxForward", "speed" }, { "maxReverse", "reverse" }, { "accelForward", "accel" }, { "accelReverse", "accel" },
    { "turnRate", "turn" }, { "turnAccel", "turn" }, { "turnDecel", "turn" },
}

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
    local fixed = { reactor = "reactor", cooling = "cooling", armor = "armor" }
    local resolved = {}
    for slot, class in pairs(fixed) do
        local component = ComponentRegistry[systems[slot]]
        if not component or component.class ~= class then
            table.insert(issues, "Invalid component for system slot: " .. slot)
        else
            resolved[slot] = component
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
        if slot ~= "reactor" and slot ~= "cooling" and slot ~= "armor" and slot ~= "capacitor" and slot ~= "shield" and slot ~= "actuators" then
            table.insert(issues, "Unknown system slot: " .. tostring(slot))
        end
    end

    local resourceComponents = {}
    for _, slot in ipairs({ "capacitor", "shield", "actuators" }) do
        local id = systems[slot] or chassis.defaultSystems[slot]
        local component = ComponentRegistry[id]
        local class = if slot == "actuators" then "actuator" else slot
        if not component or component.class ~= class then
            table.insert(issues, "Invalid component for system slot: " .. slot)
        else
            resourceComponents[slot] = component
            metrics.mass += component.mass
        end
    end

    local mounts = loadout.mounts
    if type(mounts) ~= "table" then
        mounts = {}
        table.insert(issues, "Missing mounts map")
    end

    local weapons = {}
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
                local combat = component.combat
                if combat then
                    if not combat.hardpoints[socket] then
                        table.insert(issues, "Incompatible weapon in " .. socket)
                    end
                    weapons[socket] = {
                        id = componentId, name = component.name, category = combat.category, damage = combat.damage, interval = combat.interval,
                        dps = combat.damage / combat.interval, magazine = combat.magazine, reload = combat.reload, energy = combat.energy,
                        energyRate = combat.energy / combat.interval, heat = combat.heat, mass = component.mass, range = combat.range,
                    }
                end
            end
        end
    end
    for socket in pairs(mounts) do
        if not chassis.hardpoints[socket] then
            table.insert(issues, "Unknown weapon socket: " .. tostring(socket))
        end
    end

    -- M11C: cockpit package and avionics modules. Mass and rated power enter the same budgets as every other component; bays are a hard limit.
    local cockpitPackage, avionicsModules, packageId
    if chassis.cockpit then
        local cockpitId, installed = Compiler.CockpitOf(loadout)
        local package = ComponentRegistry[cockpitId or ""]
        if not CockpitLayouts.Frame(chassis.cockpit.layout) then
            table.insert(issues, "Unknown cockpit layout")
        elseif not package or package.class ~= "cockpit" or not table.find(chassis.cockpit.packages, cockpitId) or not table.find(package.layouts, chassis.cockpit.layout) then
            table.insert(issues, "Invalid cockpit package")
        elseif type(installed) ~= "table" then
            table.insert(issues, "Invalid avionics map")
        else
            cockpitPackage, packageId, avionicsModules = package, cockpitId, {}
            local bays = 0
            for slot, id in pairs(installed) do
                local component = ComponentRegistry[id]
                if type(slot) ~= "string" or not table.find(Avionics.Slots, slot) then
                    table.insert(issues, "Unknown avionics slot: " .. tostring(slot))
                elseif type(id) ~= "string" or not component or component.class ~= "avionics" or component.slot ~= slot then
                    table.insert(issues, "Invalid avionics module for slot: " .. slot)
                else
                    local entry = table.clone(component)
                    entry.id = id
                    avionicsModules[slot] = entry
                    metrics.mass += component.mass
                    metrics.powerDraw += component.powerDraw
                    if slot ~= "radar" then
                        bays += 1
                    end
                end
            end
            metrics.mass += package.mass
            metrics.powerDraw += package.powerDraw
            metrics.avionicsBays, metrics.avionicsBaysMax = bays, package.bays
            if bays > package.bays then
                table.insert(issues, "Avionics bays exceeded")
            end
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
    local result = { valid = #issues == 0, issues = issues, metrics = metrics, weapons = weapons }
    -- A build that only breaks a budget (mass / power) still gets its effective numbers, so the garage can show what the part WOULD do
    -- next to the reason it cannot be installed. `valid` stays false: nothing deploys, nothing is built, from such a result.
    for _, issue in ipairs(issues) do
        if issue ~= "Mass limit exceeded" and issue ~= "Reactor power budget exceeded" then
            return result
        end
    end

    -- Effective specification ---------------------------------------------------------------------------------------------------
    local actuator, armor, reactor = resourceComponents.actuators, resolved.armor, resolved.reactor
    local modifiers = {
        speed = (actuator.speedScale or 1) * (armor.speedScale or 1),
        reverse = (actuator.reverseScale or 1) * (armor.speedScale or 1),
        accel = (actuator.accelScale or 1) * (armor.accelScale or 1),
        turn = (actuator.turnScale or 1) * (armor.turnScale or 1),
        movementEnergy = (actuator.movementEnergyScale or 1) * (armor.movementEnergyScale or 1),
        capacitor = reactor.capacitorScale or 1, chargeRate = reactor.chargeRateScale or 1, thermal = reactor.thermalScale or 1, cooling = reactor.coolingScale or 1,
        legStructure = actuator.legStructureScale or 1,
        structure = (chassis.baseIntegrity + armor.integrityBonus) / chassis.referenceIntegrity,
    }
    local locomotion = table.clone(chassis.locomotion)
    for _, pair in ipairs(LOCOMOTION_SCALED) do
        locomotion[pair[1]] = chassis.locomotion[pair[1]] * modifiers[pair[2]]
    end
    local structure = {}
    for region, hp in pairs(CombatConfig.mech.regions) do
        local scale = modifiers.structure * (if region == "LEG_L" or region == "LEG_R" then modifiers.legStructure else 1)
        structure[region] = math.floor(hp * scale + 0.5)
    end
    if cockpitPackage then
        result.cockpit = { id = packageId, name = cockpitPackage.name, layout = chassis.cockpit.layout, bays = cockpitPackage.bays, baysUsed = metrics.avionicsBays,
            palette = cockpitPackage.palette, equipment = table.clone(cockpitPackage.equipment), eyeHeight = chassis.cockpit.eyeHeight }
        result.avionics = Avionics.Effective(packageId :: string, cockpitPackage, avionicsModules :: any)
    end
    result.modifiers = modifiers
    result.locomotion = locomotion
    result.structure = structure
    result.energy = EnergyConfig.Build(chassis, reactor, resourceComponents.capacitor, ComponentRegistry[systems.cooling], resourceComponents.shield, {
        capacitorScale = modifiers.capacitor, chargeRateScale = modifiers.chargeRate, thermalScale = modifiers.thermal, coolingScale = modifiers.cooling,
        movementEnergyScale = modifiers.movementEnergy,
    })
    result.stats = Compiler.Stats(result)
    result.label = Compiler.Label(loadout)
    return result
end

-- A flat table of the numbers the garage compares and the sortie report records.
function Compiler.Stats(compiled)
    local m, l, e, s = compiled.metrics, compiled.locomotion, compiled.energy, compiled.structure
    local av = compiled.avionics
    local radar, optics, thermal, tracker = av and av.radar, av and av.optics, av and av.thermal, av and av.tracker
    local top = 1
    if optics then
        top = optics.magnifications[#optics.magnifications]
    end
    return {
        radarRange = radar and radar.range or 0, radarRate = if radar then 1 / radar.interval else 0, identRange = radar and radar.identRange or 0, zoomMax = top,
        thermalRange = thermal and thermal.range or 0, trackRange = tracker and tracker.range or 0, trackDetail = tracker and tracker.detail or 0,
        avionicsMass = av and av.mass or 0, avionicsPower = av and av.ratedPower or 0, baysUsed = m.avionicsBays or 0, baysMax = m.avionicsBaysMax or 0,
        output = e.output, capacity = e.capacity, thermalPerEnergy = e.thermalPerEnergy, cooling = e.cooling, chargeRate = e.maxChargeRate,
        topSpeed = l.maxForward, sprintSpeed = l.maxForward * e.movement.sprintMultiplier, accel = l.accelForward, turnRate = math.deg(l.turnRate),
        moveEnergy = compiled.modifiers.movementEnergy, coreStructure = s.CORE, legStructure = s.LEG_L, armStructure = s.ARM_L, reactorStructure = s.REACTOR,
        mass = m.mass, massLimit = m.massLimit, integrity = m.integrity, powerDraw = m.powerDraw,
    }
end

-- Short human label of the build's engineering choices, e.g. "CORE 260 / SPRINT M-2 / REINFORCED | LR-12 + MG-9".
local SHORT = {
    CORE_220 = "CORE 220", CORE_260 = "CORE 260", CORE_300 = "CORE 300", ACT_STANDARD = "STD DRIVE", ACT_MOBILITY = "SPRINT M-2",
    ARMOR_STANDARD = "COMPOSITE", ARMOR_REINFORCED = "REINFORCED",
}
local COCKPIT_SHORT = { CKP_STANDARD = "STANDARD", CKP_RECON = "RECON" }
function Compiler.Label(loadout): string
    local systems, mounts = loadout.systems or {}, loadout.mounts or {}
    local names = {}
    for _, socket in ipairs(Compiler.ConfigurableSockets) do
        local c = ComponentRegistry[mounts[socket] or ""]
        if c and c.combat then
            local short = string.match(c.name, "^(%S+)") or c.name
            if not table.find(names, short) then
                table.insert(names, short)
            end
        end
    end
    local drive = systems.actuators or "ACT_STANDARD"
    local label = string.format("%s / %s / %s | %s", SHORT[systems.reactor or ""] or "CORE ?", SHORT[drive] or "DRIVE ?", SHORT[systems.armor or ""] or "ARMOR ?", if #names > 0 then table.concat(names, " + ") else "UNARMED")
    -- M11C: the cockpit and avionics are named only when they are not the factory equipment, so factory labels are unchanged.
    local chassis = ChassisRegistry[loadout.chassisId]
    local spec = chassis and chassis.cockpit
    if spec then
        local package, installed = Compiler.CockpitOf(loadout)
        local factory = Compiler.Normalize({ chassisId = loadout.chassisId, systems = {}, mounts = {} })
        local function moduleNames(map: any): string
            local list = {}
            for _, slot in ipairs(Avionics.Slots) do
                if type(map) == "table" and map[slot] then
                    table.insert(list, Avionics.Short[map[slot]] or "?")
                end
            end
            return table.concat(list, " ")
        end
        if package ~= factory.cockpit or moduleNames(installed) ~= moduleNames(factory.avionics) then
            local modules = moduleNames(installed)
            label ..= string.format(" | %s %s", COCKPIT_SHORT[package or ""] or "COCKPIT ?", if modules ~= "" then modules else "NO AVIONICS")
        end
    end
    return label
end

-- Request validation ----------------------------------------------------------------------------------------------------------------
-- A client request is data, never numbers: { mounts = { [socket] = componentId | false }, systems = { [slot] = componentId } }. Only the
-- configurable sockets / slots may appear, every id must be one the garage actually offers for that place, and the result must compile.
-- Returns the new loadout (a fresh table, `base` is never mutated) or nil plus a short reason.
function Compiler.ApplyRequest(base, request: any): (any?, string?)
    if type(request) ~= "table" or type(base) ~= "table" then
        return nil, "INVALID REQUEST"
    end
    local chassisId = base.chassisId
    local out = Compiler.Clone(base)
    local changes = 0
    for key in pairs(request) do
        if key ~= "mounts" and key ~= "systems" and key ~= "cockpit" and key ~= "avionics" then
            return nil, "UNKNOWN REQUEST FIELD"
        end
    end
    -- M11C: the cockpit package (one id) and avionics modules ({ [slot] = id | false }), both from the registry catalog for this chassis.
    if request.cockpit ~= nil then
        local id = request.cockpit
        if type(id) ~= "string" or #id > 40 or not table.find(Compiler.CockpitOptions(chassisId), id) then
            return nil, "COCKPIT PACKAGE NOT AVAILABLE"
        end
        local normalized = Compiler.Normalize(base)
        out.cockpit, out.avionics = id, normalized.avionics
        changes += 1
    end
    if request.avionics ~= nil then
        local modules = request.avionics
        if type(modules) ~= "table" then
            return nil, "INVALID AVIONICS"
        end
        local normalized = Compiler.Normalize(out)
        out.cockpit, out.avionics = normalized.cockpit, normalized.avionics
        for slot, id in pairs(modules) do
            if type(slot) ~= "string" or not table.find(Avionics.Slots, slot) then
                return nil, "AVIONICS SLOT NOT AVAILABLE"
            end
            if id == false then
                out.avionics[slot] = nil
            elseif type(id) == "string" and #id <= 40 and table.find(Compiler.AvionicsOptions(chassisId, slot), id) then
                out.avionics[slot] = id
            else
                return nil, "MODULE NOT AVAILABLE FOR " .. string.upper(slot)
            end
            changes += 1
        end
    end
    local mounts = request.mounts
    if mounts ~= nil then
        if type(mounts) ~= "table" then
            return nil, "INVALID MOUNTS"
        end
        for socket, id in pairs(mounts) do
            if type(socket) ~= "string" or not table.find(Compiler.ConfigurableSockets, socket) then
                return nil, "SOCKET NOT CONFIGURABLE"
            end
            if id == false then
                out.mounts[socket] = nil
            elseif type(id) == "string" and #id <= 40 and table.find(Compiler.WeaponOptions(chassisId, socket), id) then
                out.mounts[socket] = id
            else
                return nil, "WEAPON NOT AVAILABLE FOR " .. string.upper(socket)
            end
            changes += 1
        end
    end
    local systems = request.systems
    if systems ~= nil then
        if type(systems) ~= "table" then
            return nil, "INVALID SYSTEMS"
        end
        for slot, id in pairs(systems) do
            if type(slot) ~= "string" or not table.find(Compiler.ConfigurableSystems, slot) then
                return nil, "SYSTEM NOT CONFIGURABLE"
            end
            if type(id) ~= "string" or #id > 40 or not table.find(Compiler.SystemOptions(slot), id) then
                return nil, "COMPONENT NOT AVAILABLE FOR " .. string.upper(slot)
            end
            out.systems[slot] = id
            changes += 1
        end
    end
    if changes == 0 then
        return nil, "NOTHING TO CHANGE"
    end
    local compiled = Compiler.Compile(out)
    if not compiled.valid then
        return nil, string.upper(compiled.issues[1] or "INVALID BUILD")
    end
    return out, nil
end

-- The loadout with its factory cockpit equipment spelled out (cockpit id and a fresh avionics map). Chassis without a cockpit contract pass through.
function Compiler.Normalize(loadout)
    local out = { chassisId = loadout.chassisId, systems = table.clone(loadout.systems or {}), mounts = table.clone(loadout.mounts or {}) }
    local package, installed = Compiler.CockpitOf(loadout)
    if package then
        out.cockpit = package
        out.avionics = if type(installed) == "table" then table.clone(installed) else {}
    end
    return out
end

-- Deep copy of a loadout (presets are shared data; a session must never edit them in place).
function Compiler.Clone(loadout)
    local out = { chassisId = loadout.chassisId, systems = table.clone(loadout.systems or {}), mounts = table.clone(loadout.mounts or {}) }
    out.cockpit = loadout.cockpit
    out.avionics = if loadout.avionics then table.clone(loadout.avionics) else nil
    return out
end

-- True when two loadouts are identical in every slot (a missing cockpit / avionics map means the chassis' factory equipment).
function Compiler.Same(a, b): boolean
    for _, slot in ipairs({ "systems", "mounts" }) do
        local x, y = a[slot] or {}, b[slot] or {}
        for k, v in pairs(x) do
            if y[k] ~= v then return false end
        end
        for k, v in pairs(y) do
            if x[k] ~= v then return false end
        end
    end
    local na, nb = Compiler.Normalize(a), Compiler.Normalize(b)
    if na.cockpit ~= nb.cockpit then return false end
    for k, v in pairs(na.avionics or {}) do
        if (nb.avionics or {})[k] ~= v then return false end
    end
    for k, v in pairs(nb.avionics or {}) do
        if (na.avionics or {})[k] ~= v then return false end
    end
    return a.chassisId == b.chassisId
end

return Compiler
