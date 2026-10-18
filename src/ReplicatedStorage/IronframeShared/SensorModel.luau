-- Radar contact model (M11C). Pure and deterministic: positions in, contacts out. The engine-specific parts (which actors exist, how many
-- solid structures stand between two points) are supplied by the caller, so the same rules run on the server and in the offline tests.
--
-- A SCAN is one radar return. For each actor the scan decides, from the sensor's capability and the distance:
--   detected      inside the (obstruction-reduced) range -> the contact is created or refreshed with a fresh, resolution-limited fix
--   not detected  the contact keeps its last fix, is marked STALE after `stale` seconds and is dropped after `lost` seconds
-- Contacts are keyed by an opaque number, never by the actor id: an unidentified contact cannot be matched to a name by anyone who only
-- reads the display. Identification (name, archetype) needs the contact to be inside `identRange`.
--
-- Radar is NOT line of sight. A solid structure between the radar and the target does not hide it outright; each one costs
-- `obstruction` of the range (two or more count as two). Optical targeting and thermal imaging use real line of sight on the server.

local Model = {}

local DEG = 180 / math.pi

export type Actor = {
    id: string, kind: string, label: string, x: number, y: number, z: number, yaw: number, speed: number,
    operational: boolean, disabled: boolean, destroyed: boolean, arch: string?,
}

function Model.New()
    return { contacts = {}, byActor = {}, nextKey = 1, cleared = {}, scans = 0 }
end

-- Bearing in degrees clockwise from north (-Z), distance in studs. dy is included in the distance, not in the bearing.
function Model.Polar(ox: number, oy: number, oz: number, x: number, y: number, z: number): (number, number)
    local dx, dy, dz = x - ox, y - oy, z - oz
    local bearing = math.atan2(dx, -dz) * DEG
    if bearing < 0 then
        bearing += 360
    end
    return bearing, math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Signed difference a - b wrapped to (-180, 180].
function Model.Wrap(angle: number): number
    angle = (angle + 180) % 360 - 180
    return if angle == -180 then 180 else angle
end

local function snap(value: number, step: number): number
    if step <= 1e-9 then
        return value
    end
    return math.floor(value / step + 0.5) * step
end

-- Effective range against `blockers` intervening structures.
function Model.EffectiveRange(radar: any, blockers: number): number
    return radar.range * (1 - radar.obstruction * math.min(blockers, 2) / 2)
end

local function classify(actor: Actor): string
    return if actor.kind == "MECH" then "MECH" else "VEHICLE"
end

local function statusOf(actor: Actor): string
    return if actor.destroyed then "DESTROYED" elseif actor.disabled then "DISABLED" else "ACTIVE"
end

-- observer = { x, y, z, yaw }; actors = { Actor }; radar = Avionics.Capability(...).radar; blockers(actor) -> count of intervening solids (only
-- called for actors inside the unobstructed range). Returns the number of contacts refreshed.
function Model.Scan(tracker: any, radar: any, observer: any, actors: { Actor }, now: number, blockers: (Actor) -> number): number
    tracker.scans += 1
    local refreshed = 0
    local seen: { [string]: boolean } = {}
    for _, actor in ipairs(actors) do
        seen[actor.id] = true
        if tracker.byActor[actor.id] then
            tracker.byActor[actor.id].gone = nil
        end
        if tracker.cleared[actor.id] and not actor.destroyed then
            tracker.cleared[actor.id] = nil -- a rebuilt machine is a new contact
        end
        if not tracker.cleared[actor.id] then
            local bearing, distance = Model.Polar(observer.x, observer.y, observer.z, actor.x, actor.y, actor.z)
            local detected = false
            if distance <= radar.range then
                local count = blockers(actor)
                detected = distance <= Model.EffectiveRange(radar, count)
            end
            local contact = tracker.byActor[actor.id]
            if detected then
                if not contact then
                    contact = { key = tracker.nextKey, actor = actor.id, first = now }
                    tracker.nextKey += 1
                    tracker.byActor[actor.id] = contact
                    tracker.contacts[contact.key] = contact
                end
                contact.last, contact.stale, contact.age = now, false, 0
                contact.kind = classify(actor)
                contact.identified = distance <= radar.identRange
                contact.name = if contact.identified then actor.label else nil
                contact.arch = if contact.identified then actor.arch else nil
                contact.status = statusOf(actor)
                contact.bearing = snap(bearing, radar.bearingStep) % 360
                contact.distance = snap(distance, radar.distStep)
                contact.heading = if radar.heading then (-actor.yaw * DEG) % 360 else nil
                contact.speed = if radar.heading then actor.speed else nil
                contact.moving = math.abs(actor.speed) > 0.5
                contact.x, contact.y, contact.z = actor.x, actor.y, actor.z -- server-side only; never sent
                if actor.destroyed then
                    contact.destroyedAt = contact.destroyedAt or now
                else
                    contact.destroyedAt = nil
                end
                refreshed += 1
            end
        end
    end
    -- An actor that vanished from the provider (removed from the world) simply stops returning.
    for id, contact in pairs(tracker.byActor) do
        if not seen[id] then
            contact.gone = true
        end
    end
    Model.Expire(tracker, radar, now)
    return refreshed
end

-- Ageing / expiry, run every server tick (a radar that is not scanning must still let its contacts go stale).
function Model.Expire(tracker: any, radar: any, now: number)
    for key, contact in pairs(tracker.contacts) do
        contact.age = now - contact.last
        contact.stale = contact.age > radar.stale
        local drop = contact.age > radar.lost or contact.gone == true
        if contact.destroyedAt and now - contact.destroyedAt > radar.wreckHold then
            drop = true
            tracker.cleared[contact.actor] = true -- the wreck stops being a contact until the machine is rebuilt
        end
        if drop then
            tracker.contacts[key] = nil
            tracker.byActor[contact.actor] = nil
        end
    end
end

-- Clears everything (sortie ended, radar removed, machine rebuilt). Keys restart so a stale display can never alias a new contact.
function Model.Reset(tracker: any)
    tracker.contacts, tracker.byActor, tracker.cleared = {}, {}, {}
    tracker.nextKey = 1
end

-- Contacts nearest first, at most `limit`, as plain data for the display packet.
function Model.List(tracker: any, limit: number): { any }
    local list = {}
    for _, contact in pairs(tracker.contacts) do
        table.insert(list, contact)
    end
    table.sort(list, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.key < b.key
    end)
    while #list > limit do
        table.remove(list)
    end
    return list
end

return Model
