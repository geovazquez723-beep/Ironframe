-- Avionics service (M11C): the one authoritative sensor evaluation behind every cockpit display.
--
-- Per deployed pilot it owns a small runtime state (`session.av`) built from the COMPILED build (`session.compiled.avionics`), never from
-- anything the client says. Ten times a second it
--   1. adapts the district's combat actors into the shared target contract (TargetRegistry; four of them in Range 07),
--   2. asks Avionics.Capability what the equipment really does right now (power delivered by the energy ledger, sensor mast damage),
--   3. runs a radar scan when one is due (SensorModel; obstruction costs range, it is not line of sight),
--   4. keeps the target lock honest with real line-of-sight rays (a lock is optical; a wall ends it after a short coast),
--   5. evaluates thermal visibility for the owner (real line of sight; a machine behind a wall has no thermal image),
--   6. sets the equipment's energy demand on the real ledger (`avionics`, the lowest priority) and sends ONE bounded packet to the owner.
-- Rays: the radar costs at most three per contact per scan, the lock two per tick, thermal two per machine in range per 0.15 s. Worst case in
-- Range 07 (four actors) is a few dozen rays per second per pilot; nothing runs per rendered frame and nothing runs for a docked machine.
--
-- Zoom, thermal and lock are REQUESTS: the client sends a command, the server validates it against the installed modules and applies it. The
-- client camera and thermal view then follow the replicated attributes. Nothing a client sends changes a range, a power draw or a statistic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local Avionics = require(Shared:WaitForChild("Avionics"))
local Sensors = require(Shared:WaitForChild("SensorModel"))
local Thermal = require(Shared:WaitForChild("ThermalSignature"))
local Contract = require(Shared:WaitForChild("TargetContract"))
local Damage = require(Shared:WaitForChild("MechDamage"))
local RigSpec = require(Shared:WaitForChild("RigSpec"))
local Registry = require(script.Parent.TargetRegistry)
local Destructibles = require(script.Parent.Destructibles)

local Service = {}

local V3 = Vector3.new
local TICK = 0.1 -- seconds between evaluations
local THERMAL_INTERVAL = 0.15
local SEND_MIN = 0.1 -- packet rate cap per pilot
local HEARTBEAT = 0.5 -- idle resend so the display never goes silent
local MAX_CONTACTS = 8
local MAX_HOT = 4
local DESTROYED_HOLD = 2 -- seconds the display keeps a destroyed lock before releasing
local COMMAND_GAP = 0.08

Service.stats = { ms = 0, worst = 0, ticks = 0, scans = 0, rays = 0, packets = 0, bytes = 0, lastPacketBytes = 0 }

local env: { remote: RemoteEvent, sessions: { [Player]: any } } = nil :: any

function Service.Init(options)
    env = options
end

-- Ray filters --------------------------------------------------------------------------------------------------------------------
-- Radar and optical rays both ignore the pilot's own machine and characters; the radar also ignores every combat actor, while an optical ray
-- ignores only its own target, so another machine standing in front of it is real cover (ROOK shadows a tank behind it).
local function baseFilter(session, district, withActors: boolean): { Instance }
    local av = session.av
    local now = os.clock()
    local key = if withActors then "filterActors" else "filterOwn"
    local at = key .. "At"
    if av[key] and now - av[at] < 1 then
        return av[key]
    end
    local list: { Instance } = {}
    if session.mech then
        table.insert(list, session.mech)
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            table.insert(list, player.Character)
        end
    end
    if withActors then
        for _, vehicle in ipairs(district.vehicles) do
            if vehicle.model then
                table.insert(list, vehicle.model)
            end
        end
        if district.mech and district.mech.model then
            table.insert(list, district.mech.model)
        end
        if district.rook and district.rook.model then
            table.insert(list, district.rook.model)
        end
    end
    av[key], av[at] = list, now
    return list
end

local function opticalParams(session, district)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = baseFilter(session, district, false)
    params.IgnoreWater = true
    return params
end

-- Line of sight from the pilot's eye to any sample of the actor: true when at least one sample is not behind world geometry or another machine.
local function clearTo(av, params: RaycastParams, eye: Vector3, actor): boolean
    local own = params.FilterDescendantsInstances
    local list = table.clone(own)
    if actor.model then
        table.insert(list, actor.model)
    end
    params.FilterDescendantsInstances = list
    local clear = false
    for _, offset in ipairs(actor.samples or { 0 }) do
        local target = V3(actor.x, actor.y + offset, actor.z)
        av.stats.rays += 1
        if not workspace:Raycast(eye, target - eye, params) then
            clear = true
            break
        end
    end
    params.FilterDescendantsInstances = own
    return clear
end

-- Number of distinct solid structures between the radar and the actor (cap 3): non-colliding props do not count.
local function countBlockers(session, district, av, eye: Vector3, actor): number
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.RespectCanCollide = true
    params.IgnoreWater = true
    local list = table.clone(baseFilter(session, district, true))
    params.FilterDescendantsInstances = list
    local target = V3(actor.x, actor.y, actor.z)
    local count = 0
    for _ = 1, 3 do
        av.stats.rays += 1
        local hit = workspace:Raycast(eye, target - eye, params)
        if not hit then
            break
        end
        count += 1
        table.insert(list, hit.Instance)
        params.FilterDescendantsInstances = list
    end
    return count
end

-- State ----------------------------------------------------------------------------------------------------------------------------
local function setAttr(session, name: string, value: any)
    local mech = session.mech
    local av = session.av
    if mech and mech.Parent and av.published[name] ~= value then
        av.published[name] = value
        mech:SetAttribute(name, value)
    end
end

-- Built after every assembly (garage install, preset, ejection rebuild): fresh trackers, no lock, zoom 1x, thermal off. The equipment itself
-- (session.compiled.avionics) comes from the session's loadout and therefore survives every reset the loadout survives.
function Service.Attach(session)
    local compiled = session.compiled
    session.av = {
        spec = compiled and compiled.avionics, tracker = Sensors.New(), zoom = 1, thermalReq = false, lock = nil, lockSerial = 0,
        nextTick = 0, nextScan = 0, nextThermalAt = 0, lastSend = -10, serial = 0, active = false, dirty = true,
        mem = {}, motion = {}, hot = {}, published = {}, filter = nil, filterAt = -10, cap = nil, lastCommand = -10,
        message = "", messageAt = -10, stats = { rays = 0, scans = 0 }, actors = {}, byId = {},
    }
    local av = session.av
    setAttr(session, "AvZoom", 1)
    setAttr(session, "AvMag", 1)
    setAttr(session, "AvThermal", false)
    setAttr(session, "AvLock", "")
    setAttr(session, "AvRadar", if av.spec and av.spec.radar then "STANDBY" else "NONE")
    setAttr(session, "AvPackage", av.spec and av.spec.packageId or "")
end

local function eyeOf(session): Vector3
    local s = session.controller.state
    local height = session.compiled.cockpit and session.compiled.cockpit.eyeHeight or 13.6
    return V3(s.x, s.y + height, s.z)
end

local function note(av, text: string, now: number)
    av.message, av.messageAt = text, now
    av.dirty = true
end

-- Collects the district's actors and refreshes the per-actor derived values (measured speed, shot timing, thermal level).
local function refreshActors(session, av, district, now: number)
    local list = Registry.Collect(district, now)
    local byId = {}
    for _, actor in ipairs(list) do
        byId[actor.id] = actor
        -- measured speed for actors that do not report one (training tanks move their models directly)
        if actor.derive then
            local m = av.motion[actor.id]
            if m and now - m.t > 0.04 then
                local forwardX, forwardZ = -math.sin(actor.yaw), -math.cos(actor.yaw)
                local measured = ((actor.x - m.x) * forwardX + (actor.z - m.z) * forwardZ) / (now - m.t)
                actor.speed = m.speed + (measured - m.speed) * 0.5
                av.motion[actor.id] = { x = actor.x, z = actor.z, t = now, speed = actor.speed }
            elseif m then
                actor.speed = m.speed
            else
                av.motion[actor.id] = { x = actor.x, z = actor.z, t = now, speed = 0 }
            end
        end
        -- shot timing and thermal memory (updated for every actor, seen or not: a wreck must cool from when it really died)
        local mem = av.mem[actor.id]
        if not mem then
            mem = { shots = actor.shotCounter or 0 }
            av.mem[actor.id] = mem
        end
        if (actor.shotCounter or 0) > mem.shots then
            mem.firedAt = now
        end
        mem.shots = actor.shotCounter or 0
        actor.firedAgo = if mem.firedAt then now - mem.firedAt else nil
        actor.heat = Thermal.Level(mem, actor, now)
    end
    av.actors, av.byId = list, byId
end

local function weaponRange(session): number?
    local weapons = session.weapons
    if not weapons then
        return nil
    end
    local socket = RigSpec.SocketOrder[weapons.selected or 1]
    local slot = socket and weapons.slots[socket]
    return slot and slot.spec.range or nil
end

local function bearingOf(session, actor): number
    local s = session.controller.state
    local b = math.deg(math.atan2(actor.x - s.x, -(actor.z - s.z)))
    return b % 360
end

local function lockPacket(session, av, now: number)
    local lock = av.lock
    if not lock then
        return nil
    end
    local actor = av.byId[lock.id]
    local tracker = av.cap and av.cap.tracker
    local eye = eyeOf(session)
    local out: any = { k = lock.serial, st = lock.state, rs = lock.reason }
    if actor then
        local d = (V3(actor.x, actor.y, actor.z) - eye).Magnitude
        out.nm, out.ar, out.kd = actor.label, actor.arch, if actor.kind == "MECH" then 2 else 1
        out.d, out.b = math.floor(d + 0.5), math.floor(bearingOf(session, actor) + 0.5)
        out.sp, out.hd = math.floor(math.abs(actor.speed) * 10 + 0.5) / 10, math.floor((-math.deg(actor.yaw)) % 360 + 0.5)
        out.ss = if actor.destroyed then 3 elseif actor.disabled then 2 else 1
        local range = weaponRange(session)
        out.wr = if range then d <= range else nil
        out.m, out.sz = actor.model, actor.size
        out.p = V3(actor.x, actor.y, actor.z)
        out.v = V3(-math.sin(actor.yaw), 0, -math.cos(actor.yaw)) * actor.speed
        out.lv = actor.heat
        if tracker and tracker.detail >= 2 and actor.components and lock.state ~= "LOST" then
            local parts = {}
            for _, c in ipairs(actor.components()) do
                table.insert(parts, { c.name, Contract.Band(c.fraction, c.offline) })
            end
            out.cm = parts
        end
    end
    out.dt = tracker and tracker.detail or 0
    return out
end

local function buildPacket(session, av, now: number)
    local cap = av.cap
    local radar = cap and cap.radar
    local contacts = {}
    for _, c in ipairs(Sensors.List(av.tracker, MAX_CONTACTS)) do
        table.insert(contacts, {
            k = c.key, kd = if c.kind == "MECH" then 2 else 1, b = math.floor(c.bearing + 0.5), d = math.floor(c.distance + 0.5),
            ss = if c.status == "DESTROYED" then 3 elseif c.status == "DISABLED" then 2 else 1, sl = c.stale or nil, ag = math.floor(c.age * 10 + 0.5) / 10,
            nm = c.name, ar = c.arch, mv = c.moving or nil, hd = c.heading and math.floor(c.heading + 0.5) or nil, sp = c.speed and math.floor(math.abs(c.speed) * 10 + 0.5) / 10 or nil,
        })
    end
    local thermal = cap and cap.thermal
    local packet: any = {
        n = av.serial, t = workspace:GetServerTimeNow(),
        rd = if radar then { s = radar.state, m = radar.mode, r = math.floor(radar.range + 0.5), i = radar.interval } else nil,
        c = contacts,
        th = if thermal then { on = av.thermalReq and thermal.available, av = thermal.available, why = thermal.reason, r = math.floor(thermal.range + 0.5) } else nil,
        hot = if av.thermalReq and thermal and thermal.available then av.hot else nil,
        tr = if cap and cap.tracker then { av = cap.tracker.available, dg = cap.tracker.degraded, dt = cap.tracker.detail, r = math.floor(cap.tracker.range + 0.5) } else nil,
        zm = av.zoom, mag = Avionics.Magnification(av.spec, av.zoom), st = cap and cap.stabilized,
        lock = lockPacket(session, av, now),
        notes = cap and cap.notes or nil,
        ms = if now - av.messageAt < 4 then av.message else nil,
    }
    return packet
end

local function send(session, av, now: number, force: boolean?)
    if not force and now - av.lastSend < SEND_MIN then
        return
    end
    av.lastSend = now
    av.serial += 1
    local packet = buildPacket(session, av, now)
    env.remote:FireClient(session.player, packet)
    Service.stats.packets += 1
end

local function releaseLock(session, av, reason: string, now: number)
    if av.lock then
        av.lock = nil
        note(av, reason, now)
        setAttr(session, "AvLock", "")
    end
end

local function thermalPass(session, av, district, now: number, eye: Vector3, params: RaycastParams)
    local cap = av.cap
    local list = {}
    if av.thermalReq and cap and cap.thermal and cap.thermal.available then
        local range = cap.thermal.range
        local candidates = {}
        for _, actor in ipairs(av.actors) do
            local d = (V3(actor.x, actor.y, actor.z) - eye).Magnitude
            if d <= range and actor.heat >= 0.08 and actor.model then
                table.insert(candidates, { actor = actor, d = d })
            end
        end
        table.sort(candidates, function(a, b) return a.d < b.d end)
        for _, c in ipairs(candidates) do
            if #list >= MAX_HOT then
                break
            end
            if clearTo(av, params, eye, c.actor) then
                table.insert(list, { m = c.actor.model, lv = math.floor(c.actor.heat * 100 + 0.5) / 100, d = math.floor(c.d + 0.5) })
            end
        end
    end
    av.hot = list
end

local function lockPass(session, av, now: number, eye: Vector3, params: RaycastParams)
    local lock = av.lock
    local cap = av.cap
    if not lock then
        return
    end
    local tracker = cap and cap.tracker
    if not tracker or not tracker.available then
        releaseLock(session, av, "TRACKER OFFLINE: LOCK RELEASED", now)
        return
    end
    local actor = av.byId[lock.id]
    if not actor then
        releaseLock(session, av, "TARGET LOST", now)
        return
    end
    if actor.destroyed then
        lock.state, lock.reason = "DESTROYED", "TARGET DESTROYED"
        lock.destroyedAt = lock.destroyedAt or now
        if now - lock.destroyedAt > DESTROYED_HOLD then
            releaseLock(session, av, "TARGET DESTROYED", now)
        end
        return
    end
    local d = (V3(actor.x, actor.y, actor.z) - eye).Magnitude
    if d > tracker.range * 1.15 then
        releaseLock(session, av, "TARGET OUT OF RANGE: LOCK RELEASED", now)
        return
    end
    if d <= tracker.range and clearTo(av, params, eye, actor) then
        lock.state, lock.reason, lock.lastVisual = "TRACK", "OPTICAL TRACK", now
    elseif now - lock.lastVisual <= tracker.loseTime then
        lock.state, lock.reason = "COAST", if d > tracker.range then "OUT OF TRACKER RANGE: COASTING" else "OBSCURED: COASTING"
    else
        releaseLock(session, av, "TARGET LOST: NO LINE OF SIGHT", now)
    end
end

local function applyModes(session, av, now: number)
    local cap = av.cap
    local spec = av.spec
    local power = session.power
    if power then
        power.avionicsDemand = Avionics.Demand(spec, { zoomIndex = av.zoom, thermalOn = av.thermalReq, locked = av.lock ~= nil })
    end
    setAttr(session, "AvZoom", av.zoom)
    setAttr(session, "AvMag", Avionics.Magnification(spec, av.zoom))
    setAttr(session, "AvThermal", av.thermalReq == true and cap ~= nil and cap.thermal ~= nil and cap.thermal.available == true)
    setAttr(session, "AvLock", if av.lock and av.byId[av.lock.id] then av.byId[av.lock.id].label else "")
    setAttr(session, "AvRadar", if cap and cap.radar then cap.radar.state else "NONE")
    setAttr(session, "AvStabilized", cap ~= nil and cap.stabilized == true)
end

local function tickSession(session, av, now: number)
    local d = Destructibles.Get(session.bay)
    if not d then
        return
    end
    local health = if session.damage then Damage.Fraction(session.damage, "CORE") else 1
    local factor = if session.power then session.power.avionicsFactor else 1
    local cap = Avionics.Capability(av.spec, factor, health)
    av.cap = cap
    if av.thermalReq and av.spec and av.spec.thermal and not cap.thermal.available and not av.thermalWarned then
        av.thermalWarned = true
        note(av, "THERMAL " .. cap.thermal.reason, now)
    elseif cap.thermal and cap.thermal.available then
        av.thermalWarned = false
    end
    refreshActors(session, av, d, now)
    local eye = eyeOf(session)
    local s = session.controller.state
    local observer = { x = s.x, y = s.y + 9, z = s.z, yaw = s.yaw }
    local params = opticalParams(session, d)
    local changed = false
    if cap.radar then
        if now >= av.nextScan - 0.02 then
            av.nextScan = now + cap.radar.interval
            Sensors.Scan(av.tracker, cap.radar, observer, av.actors, now, function(actor)
                return countBlockers(session, d, av, eye, actor)
            end)
            Service.stats.scans += 1
            changed = true
        else
            Sensors.Expire(av.tracker, cap.radar, now)
        end
    elseif next(av.tracker.contacts) then
        Sensors.Reset(av.tracker)
        changed = true
    end
    local lockWas = av.lock and av.lock.state
    lockPass(session, av, now, eye, params)
    if av.lock then
        changed = true -- lock data refreshes at tick rate
    elseif lockWas then
        changed = true
    end
    if now >= av.nextThermalAt then
        av.nextThermalAt = now + THERMAL_INTERVAL
        thermalPass(session, av, d, now, eye, params)
        if av.thermalReq then
            changed = true
        end
    end
    applyModes(session, av, now)
    if changed or av.dirty or now - av.lastSend >= HEARTBEAT then
        av.dirty = false
        send(session, av, now)
    end
end

local function isActive(session): boolean
    local mech = session.mech
    return session.av ~= nil and session.machineState == "OPERATIONAL" and session.deployment == "ACTIVE" and session.controller ~= nil
        and mech ~= nil and mech.Parent ~= nil and session.power ~= nil
end

local function deactivate(session, av)
    av.active = false
    Sensors.Reset(av.tracker)
    av.lock, av.zoom, av.thermalReq, av.hot = nil, 1, false, {}
    if session.mech and session.mech.Parent then
        applyModes(session, av, os.clock())
        setAttr(session, "AvRadar", if av.spec and av.spec.radar then "STANDBY" else "NONE")
    end
    if session.power then
        session.power.avionicsDemand = 0
    end
    if session.player and session.player.Parent then
        av.serial += 1
        env.remote:FireClient(session.player, { n = av.serial, off = true, zm = 1, mag = 1, c = {} })
    end
end

-- Called every Heartbeat from Main (after the drive and energy steps). Cheap when nothing is deployed.
function Service.Step(now: number)
    if not env then
        return
    end
    local started = os.clock()
    for _, session in pairs(env.sessions) do
        local av = session.av
        if av then
            if isActive(session) then
                if not av.active then
                    av.active, av.dirty, av.nextScan, av.nextTick = true, true, now, now
                    note(av, "AVIONICS ONLINE", now)
                end
                if now >= av.nextTick then
                    av.nextTick = now + TICK
                    local ok, err = pcall(tickSession, session, av, now)
                    if not ok then
                        warn("[IF-AVIONICS] tick failed:", err)
                    end
                end
            elseif av.active then
                deactivate(session, av)
            end
        end
    end
    local ms = (os.clock() - started) * 1000
    local st = Service.stats
    st.ticks += 1
    if ms > 0.001 then
        st.ms += (ms - st.ms) * 0.05
        st.worst = math.max(st.worst, ms)
    end
end

-- Commands (RequestAvionics) --------------------------------------------------------------------------------------------------------
local function finiteVector(v: any): boolean
    return typeof(v) == "Vector3" and v.X == v.X and v.Y == v.Y and v.Z == v.Z and v.Magnitude > 0.5 and v.Magnitude < 1.5
end

-- Candidates the pilot can legitimately target: real actors inside the tracker's range with an unobstructed optical line from the eye, inside
-- the selection cone around the sight line. Sorted by angle off the sight line. Returns the sorted list.
local function candidates(session, av, d, dir: Vector3, cone: number)
    local tracker = av.cap.tracker
    local eye = eyeOf(session)
    local params = opticalParams(session, d)
    local list = {}
    for _, actor in ipairs(Registry.Collect(d, os.clock())) do
        if not actor.destroyed then
            local to = V3(actor.x, actor.y, actor.z) - eye
            local dist = to.Magnitude
            if dist <= tracker.range and dist > 1 then
                local angle = math.deg(math.acos(math.clamp(dir.Unit:Dot(to / dist), -1, 1)))
                if angle <= cone and clearTo(av, params, eye, actor) then
                    table.insert(list, { actor = actor, angle = angle, d = dist })
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.angle ~= b.angle then
            return a.angle < b.angle
        end
        return a.actor.id < b.actor.id
    end)
    return list
end

function Service.Command(player: Player, cmd: any, a: any, b: any)
    local session = env and env.sessions[player]
    local av = session and session.av
    if not session or not av or type(cmd) ~= "string" or #cmd > 16 then
        return
    end
    local now = os.clock()
    if now - av.lastCommand < COMMAND_GAP then
        return
    end
    av.lastCommand = now
    if not isActive(session) then
        return
    end
    local spec = av.spec
    if not av.cap then
        av.cap = Avionics.Capability(spec, 1, 1)
    end
    if cmd == "zoom" then
        local optics = spec and spec.optics
        if not optics then
            note(av, "NO OPTICS FITTED", now)
            return
        end
        local index
        if a == "cycle" then
            index = av.zoom % #optics.magnifications + 1
        else
            index = Avionics.ClampZoom(spec, a)
        end
        av.zoom = index
        av.dirty = true
        applyModes(session, av, now)
    elseif cmd == "thermal" then
        local thermal = av.cap.thermal
        if not thermal then
            note(av, "NO THERMAL IMAGER FITTED", now)
            return
        end
        local want
        if a == "toggle" then
            want = not av.thermalReq
        elseif type(a) == "boolean" then
            want = a
        else
            return
        end
        av.thermalReq = want
        av.thermalWarned = false
        if want and not thermal.available then
            note(av, "THERMAL " .. thermal.reason, now)
        end
        av.dirty = true
        applyModes(session, av, now)
    elseif cmd == "reset" then -- the pilot left the cockpit view: 1x, imager off, lock released (the only command that changes several modes at once)
        av.zoom, av.thermalReq = 1, false
        releaseLock(session, av, "VIEW RESET", now)
        av.dirty = true
        applyModes(session, av, now)
    elseif cmd == "release" then
        releaseLock(session, av, "LOCK RELEASED", now)
        applyModes(session, av, now)
    elseif cmd == "acquire" then
        local tracker = av.cap.tracker
        if not tracker then
            note(av, "NO TARGET TRACKER FITTED", now)
            return
        end
        if not tracker.available then
            note(av, "TRACKER OFFLINE", now)
            return
        end
        if not finiteVector(a) then
            return
        end
        local d = Destructibles.Get(session.bay)
        if not d then
            return
        end
        local mag = Avionics.Magnification(spec, av.zoom)
        local cycling = b == "next" and av.lock ~= nil
        local cone = (if cycling then tracker.cycleCone else tracker.cone) / mag
        local list = candidates(session, av, d, (a :: Vector3).Unit, cone)
        if #list == 0 then
            note(av, "NO TARGET IN SIGHT", now)
            return
        end
        local pick = list[1]
        if cycling then
            local index
            for i, c in ipairs(list) do
                if c.actor.id == av.lock.id then
                    index = i
                end
            end
            if index then
                pick = list[index % #list + 1]
            end
        end
        if not av.lock or av.lock.id ~= pick.actor.id then
            av.lockSerial += 1
            av.lock = { id = pick.actor.id, serial = av.lockSerial, state = "TRACK", reason = "OPTICAL TRACK", lastVisual = now, since = now }
            note(av, "LOCK " .. pick.actor.label, now)
        end
        av.dirty = true
        applyModes(session, av, now)
    end
end

-- Test and audit snapshot (server only).
function Service.Audit(session)
    local av = session.av
    if not av then
        return nil
    end
    local contacts = {}
    for _, c in ipairs(Sensors.List(av.tracker, 16)) do
        table.insert(contacts, { key = c.key, name = c.name, kind = c.kind, status = c.status, stale = c.stale, age = c.age, bearing = c.bearing, distance = c.distance, identified = c.identified })
    end
    local cap = av.cap
    local lock = av.lock and { id = av.lock.id, state = av.lock.state, reason = av.lock.reason, since = os.clock() - av.lock.since } or nil
    local actors = {}
    for _, actor in ipairs(av.actors) do
        table.insert(actors, { id = actor.id, heat = actor.heat, powered = actor.powered, destroyed = actor.destroyed, speed = actor.speed, firedAgo = actor.firedAgo })
    end
    return {
        active = av.active, zoom = av.zoom, thermalReq = av.thermalReq, contacts = contacts, lock = lock, actors = actors,
        radar = cap and cap.radar, thermal = cap and cap.thermal, tracker = cap and cap.tracker, notes = cap and cap.notes, factor = session.power and session.power.avionicsFactor,
        demand = session.power and session.power.avionicsDemand, hot = #av.hot, rays = av.stats.rays, scans = Service.stats.scans, serial = av.serial,
        spec = av.spec and { package = av.spec.packageId, installed = av.spec.installed, rated = av.spec.ratedPower, mass = av.spec.mass }, message = av.message, stats = table.clone(Service.stats),
    }
end

Service.CountBlockers = countBlockers
Service.ClearTo = clearTo

return Service
