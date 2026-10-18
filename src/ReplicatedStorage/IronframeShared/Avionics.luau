-- Avionics rules (M11C). Pure and deterministic: no Roblox types, no clock, no randomness.
--
-- The LoadoutCompiler resolves the installed cockpit package and avionics modules once (`Avionics.Effective`); at run time the sensor
-- service asks this module three questions, never the registry directly:
--   Demand       how many energy units per second does the installed equipment want right now (it enters the real ledger as `avionics`)
--   Capability   given what the ledger actually delivered and how damaged the sensor mast is, what do the radar / thermal imager / tracker
--                really do this instant (range, scan interval, available or not)
--   Fov          the camera field of view for an optical magnification (true optical magnification, see Fov)
-- Nothing a client says reaches any of these: the inputs come from the compiled build, the energy ledger and the damage model.

local Components = if script then require((script :: any).Parent.ComponentRegistry) else require("./ComponentRegistry" :: any)

local Avionics = {}

Avionics.Slots = { "radar", "optics", "thermal", "targeting" }
Avionics.Short = { AV_RADAR_BASIC = "RS-4", AV_RADAR_ENHANCED = "RS-9", AV_OPTICS_ZOOM = "OP-2", AV_THERMAL = "TI-3", AV_TRACKER = "TC-1" }

-- Sensor mast health (the core fraction of the damage model): below `damaged` the radar loses reach, below `critical` it loses far more
-- and the thermal imager and the tracker's subsystem analysis go dark. Same thresholds the Bastion damage model already uses.
Avionics.Damage = { damaged = 0.6, critical = 0.25, damagedRange = 0.85, criticalRange = 0.6 }
Avionics.TrackerOffline = 0.15 -- below this share of its requested power the tracker keeps nothing

local function bonusOf(package: any, key: string): number
    local b = package and package.sensorBonus
    return if b and type(b[key]) == "number" then b[key] else 1
end

local function radarSpec(component: any, package: any): any
    local s = component.sensor
    local range = s.range * bonusOf(package, "radarRange")
    return {
        id = component.id, name = component.name, range = range, identRange = math.min(s.identRange * bonusOf(package, "radarRange"), range),
        interval = s.interval / bonusOf(package, "radarRate"), stale = s.stale, lost = s.lost, obstruction = s.obstruction,
        distStep = s.distStep, bearingStep = s.bearingStep, heading = s.heading, wreckHold = s.wreckHold, needsPower = s.needsPower, power = component.powerDraw,
    }
end

-- `modules` = { [slot] = registry component (with id) }. Returns the effective sensor specification the rest of the game consumes.
function Avionics.Effective(packageId: string, package: any, modules: { [string]: any }): any
    local spec = {
        packageId = packageId, packageName = package.name, packagePower = package.powerDraw or 0, packageMass = package.mass or 0,
        ratedPower = package.powerDraw or 0, mass = package.mass or 0, installed = {},
    }
    for _, slot in ipairs(Avionics.Slots) do
        local c = modules[slot]
        if c then
            spec.ratedPower += c.powerDraw
            spec.mass += c.mass
            spec.installed[slot] = c.id
        end
    end
    local radar = modules.radar
    if radar then
        spec.radar = radarSpec(radar, package)
        local fallbackId = radar.sensor.fallback
        local fb = fallbackId and Components[fallbackId]
        if fb then
            fb = table.clone(fb)
            fb.id = fallbackId
            spec.radar.fallback = radarSpec(fb, package)
        end
    end
    local optics = modules.optics
    if optics then
        spec.optics = { id = optics.id, name = optics.name, magnifications = table.clone(optics.sensor.magnifications), power = optics.powerDraw, standby = optics.sensor.standby }
    end
    local thermal = modules.thermal
    if thermal then
        spec.thermal = { id = thermal.id, name = thermal.name, range = thermal.sensor.range * bonusOf(package, "thermalRange"), power = thermal.powerDraw,
            standby = thermal.sensor.standby, needsPower = thermal.sensor.needsPower }
    end
    local tracker = modules.targeting
    if tracker then
        local s = tracker.sensor
        -- bonus.trackerDetail is an absolute detail level (2 = component analysis); a package without it leaves the module's own detail.
        local bonusDetail = package.sensorBonus and package.sensorBonus.trackerDetail
        spec.tracker = { id = tracker.id, name = tracker.name, range = s.range, loseTime = s.loseTime, detail = if bonusDetail then math.max(s.detail, bonusDetail) else s.detail,
            power = tracker.powerDraw, standby = s.standby, needsPower = s.needsPower, cone = s.cone, cycleCone = s.cycleCone }
    end
    return spec
end

-- Run-time demand. rt = { zoomIndex = n, thermalOn = bool, locked = bool }. Always <= spec.ratedPower.
function Avionics.Demand(spec: any, rt: any): number
    if not spec then
        return 0
    end
    local total = spec.packagePower
    local radar = spec.radar
    if radar and radar.needsPower then
        total += radar.power -- the enhanced set is a continuous load; the integrated set rides on the idle bus (power 0)
    end
    local optics = spec.optics
    if optics then
        total += if (rt.zoomIndex or 1) > 1 then optics.power else optics.standby
    end
    local thermal = spec.thermal
    if thermal then
        total += if rt.thermalOn then thermal.power else thermal.standby
    end
    local tracker = spec.tracker
    if tracker then
        total += if rt.locked then tracker.power else tracker.standby
    end
    return total
end

-- What the equipment really does now. `factor` = share of the requested avionics power the ledger delivered (0..1), `health` = sensor mast
-- (core) health fraction. Pure function of those inputs; the service just applies the answer.
function Avionics.Capability(spec: any, factor: number?, health: number?): any
    local f = math.clamp(factor or 1, 0, 1)
    local h = math.clamp(health or 1, 0, 1)
    local D = Avionics.Damage
    local out: any = { factor = f, health = h, notes = {} }
    local reach = if h <= D.critical then D.criticalRange elseif h <= D.damaged then D.damagedRange else 1
    if reach < 1 then
        table.insert(out.notes, if h <= D.critical then "SENSOR MAST CRITICAL" else "SENSOR MAST DAMAGED")
    end
    local radar = spec and spec.radar
    if radar then
        local source, mode, state = radar, if radar.needsPower then "ENHANCED" else "BASIC", "ONLINE"
        if radar.needsPower and f < radar.needsPower and radar.fallback then
            source, mode, state = radar.fallback, "BASIC", "DEGRADED"
            table.insert(out.notes, "RADAR LOW POWER")
        end
        local interval = source.interval
        if h <= D.critical then
            interval *= 1.5
        end
        out.radar = {
            state = if reach < 1 and state == "ONLINE" then "DEGRADED" else state, mode = mode, id = source.id, range = source.range * reach, identRange = source.identRange * reach,
            interval = interval, stale = source.stale, lost = source.lost, obstruction = source.obstruction, distStep = source.distStep,
            bearingStep = source.bearingStep, heading = source.heading, wreckHold = source.wreckHold,
        }
    end
    local thermal = spec and spec.thermal
    if thermal then
        local reason = nil
        if h <= D.critical then
            reason = "SENSOR DAMAGE"
        elseif f < thermal.needsPower then
            reason = "NO POWER"
        end
        out.thermal = { available = reason == nil, reason = reason or "READY", range = thermal.range * (if h <= D.damaged then D.damagedRange else 1) }
        if reason then
            table.insert(out.notes, "THERMAL " .. reason)
        end
    end
    local tracker = spec and spec.tracker
    if tracker then
        local offline = f < Avionics.TrackerOffline
        local starved = f < tracker.needsPower
        out.tracker = {
            available = not offline, degraded = starved or h <= D.critical, range = tracker.range * (if h <= D.damaged then D.damagedRange else 1),
            loseTime = if starved then math.min(tracker.loseTime, 0.5) else tracker.loseTime,
            detail = if starved or h <= D.critical then 0 else tracker.detail, cone = tracker.cone, cycleCone = tracker.cycleCone,
        }
        if starved then
            table.insert(out.notes, "TRACKER LOW POWER")
        end
    end
    out.stabilized = f >= 0.5
    return out
end

-- Valid zoom index for the installed optics (1 when none).
function Avionics.ClampZoom(spec: any, index: any): number
    local optics = spec and spec.optics
    if not optics or type(index) ~= "number" or index ~= index then
        return 1
    end
    return math.clamp(math.floor(index), 1, #optics.magnifications)
end

function Avionics.Magnification(spec: any, index: number): number
    local optics = spec and spec.optics
    return if optics then optics.magnifications[Avionics.ClampZoom(spec, index)] else 1
end

-- TRUE optical magnification m relative to the baseline field of view (degrees, vertical): a distant object spans m times as much of the
-- screen, so tan(fov / 2) shrinks m-fold. Dividing the degrees by m is wrong: 74 deg / 4 = 18.5 deg has tan(9.25 deg) = 0.163 against
-- tan(37 deg) = 0.754, which is 4.6x, not 4x; the correct 4x field is 21.3 deg. Clamped to a usable minimum.
function Avionics.Fov(baseFov: number, magnification: number): number
    local m = math.max(magnification, 1)
    return math.clamp(math.deg(2 * math.atan(math.tan(math.rad(baseFov) / 2) / m)), 4, baseFov)
end

return Avionics
