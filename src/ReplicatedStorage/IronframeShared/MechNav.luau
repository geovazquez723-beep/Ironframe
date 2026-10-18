-- Lightweight navigation, steering and position choice for autonomous mechs (M10C). Pure: numbers and callbacks in, numbers out;
-- the server supplies the only things that touch the world (hull clearance and segment-clear tests as callbacks).
--
--   lattice      a coarse grid of nodes over the enemy's court. The server validates each node against real geometry (a hull-sized
--                overlap test) and each short edge with a hull-sized sweep, so a wall panel that stands is an obstacle and one that
--                was shot away is not (nodes are re-validated on demand).
--   route        direct when the straight sweep is clear, otherwise A* over the validated lattice, returned as waypoints.
--   drive        the mech cannot strafe or spin on the spot while walking: it turns toward a waypoint first and only walks when
--                roughly facing it, brakes for the goal and slows for what is ahead (clearances measured by the server).
--   progress     a stuck detector that notices "commanded to move, hardly moved" and runs a short reverse-and-turn recovery.
--   pick         scores lattice nodes for a tactical reason (regain line of sight, flank, take cover, open the range ...).
--
-- Conventions follow MechDrive: yaw 0 faces -Z, a positive yaw/steer turns left, heading = (-sin yaw, -cos yaw).

local Nav = {}

local function clamp(v: number, lo: number, hi: number): number
    return if v < lo then lo elseif v > hi then hi else v
end

function Nav.wrap(a: number): number
    return (a + math.pi) % (2 * math.pi) - math.pi
end

function Nav.dist(ax: number, az: number, bx: number, bz: number): number
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

-- Yaw that faces the point (tx, tz) from (x, z).
function Nav.yawTo(x: number, z: number, tx: number, tz: number): number
    return math.atan2(-(tx - x), -(tz - z))
end

-- Lattice ----------------------------------------------------------------------------------------------------------------------
-- court = { cols = {x...}, rowStart, rowStep, rowCount }, station = { x, z }. ox, oz offset the nodes into world space.
function Nav.BuildNodes(court, station, ox: number, oz: number)
    local nodes = {}
    for r = 0, court.rowCount - 1 do
        local z = court.rowStart + r * court.rowStep
        for _, x in ipairs(court.cols) do
            table.insert(nodes, { id = #nodes + 1, x = x + ox, z = z + oz, valid = true, station = false })
        end
    end
    table.insert(nodes, { id = #nodes + 1, x = station.x + ox, z = station.z + oz, valid = true, station = true })
    return nodes
end

-- edgeOk(a, b) -> boolean is the server's hull sweep between two nodes. Only valid nodes are connected.
function Nav.BuildGraph(nodes, reach: number, edgeOk: (any, any) -> boolean)
    local graph = { nodes = nodes, edges = {} }
    for _, node in ipairs(nodes) do
        graph.edges[node.id] = {}
    end
    for i, a in ipairs(nodes) do
        if a.valid then
            for j = i + 1, #nodes do
                local b = nodes[j]
                if b.valid then
                    local d = Nav.dist(a.x, a.z, b.x, b.z)
                    if d <= reach and edgeOk(a, b) then
                        table.insert(graph.edges[a.id], { to = b.id, cost = d })
                        table.insert(graph.edges[b.id], { to = a.id, cost = d })
                    end
                end
            end
        end
    end
    return graph
end

function Nav.EdgeCount(graph): number
    local n = 0
    for _, list in pairs(graph.edges) do
        n += #list
    end
    return n // 2
end

-- A* over the lattice (straight-line heuristic). Returns the list of node ids from..to inclusive, and the path cost, or nil.
function Nav.Path(graph, from: number, to: number): ({ number }?, number?)
    if from == to then
        return { from }, 0
    end
    local nodes = graph.nodes
    local open, g, parent, closed = { [from] = true }, { [from] = 0 }, {}, {}
    local function h(id: number): number
        local n, t = nodes[id], nodes[to]
        return Nav.dist(n.x, n.z, t.x, t.z)
    end
    local f = { [from] = h(from) }
    while true do
        local current, best = nil, math.huge
        for id in pairs(open) do
            if f[id] < best then
                current, best = id, f[id]
            end
        end
        if not current then
            return nil, nil
        end
        if current == to then
            local path, id = {}, to
            while id do
                table.insert(path, 1, id)
                id = parent[id]
            end
            return path, g[to]
        end
        open[current] = nil
        closed[current] = true
        for _, edge in ipairs(graph.edges[current]) do
            if not closed[edge.to] then
                local candidate = g[current] + edge.cost
                if g[edge.to] == nil or candidate < g[edge.to] then
                    g[edge.to], parent[edge.to] = candidate, current
                    f[edge.to] = candidate + h(edge.to)
                    open[edge.to] = true
                end
            end
        end
    end
end

-- The k valid nodes nearest (x, z) that satisfy `accept` (optional).
function Nav.Nearest(graph, x: number, z: number, k: number, accept: ((any) -> boolean)?)
    local ranked = {}
    for _, node in ipairs(graph.nodes) do
        if node.valid and (not accept or accept(node)) then
            table.insert(ranked, { node = node, d = Nav.dist(x, z, node.x, node.z) })
        end
    end
    table.sort(ranked, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(k, #ranked) do
        out[i] = ranked[i].node
    end
    return out
end

-- Waypoints from (sx, sz) to (gx, gz). `segmentClear(x1, z1, x2, z2)` is the server's hull sweep. Returns { {x, z} ... } ending at
-- the goal, or nil when no route exists (the caller then treats the goal as unreachable and picks another).
function Nav.Route(graph, sx: number, sz: number, gx: number, gz: number, segmentClear: (number, number, number, number) -> boolean)
    if segmentClear(sx, sz, gx, gz) then
        return { { x = gx, z = gz } }, Nav.dist(sx, sz, gx, gz)
    end
    local entries = Nav.Nearest(graph, sx, sz, 5, function(node) return segmentClear(sx, sz, node.x, node.z) end)
    local exits = Nav.Nearest(graph, gx, gz, 5, function(node) return segmentClear(node.x, node.z, gx, gz) end)
    local bestPath, bestCost
    for _, e in ipairs(entries) do
        for _, x in ipairs(exits) do
            local path, cost = Nav.Path(graph, e.id, x.id)
            if path and cost then
                local total = Nav.dist(sx, sz, e.x, e.z) + cost + Nav.dist(x.x, x.z, gx, gz)
                if not bestCost or total < bestCost then
                    bestPath, bestCost = path, total
                end
            end
        end
    end
    if not bestPath then
        return nil, nil
    end
    local points = {}
    for _, id in ipairs(bestPath) do
        local node = graph.nodes[id]
        table.insert(points, { x = node.x, z = node.z })
    end
    table.insert(points, { x = gx, z = gz })
    return points, bestCost
end

-- Steering -----------------------------------------------------------------------------------------------------------------------
-- Steering toward a facing: positive = turn left. `window` is the error (rad) that commands full steering.
function Nav.Face(yaw: number, wanted: number, window: number?): number
    return clamp(Nav.wrap(wanted - yaw) / (window or math.rad(20)), -1, 1)
end

-- State: { x, z, yaw, speed }.  P: the chassis drive parameters (maxForward, coastDecel).
-- opt: { cap = 0..1, stop = studs, clearAhead?, clearLeft?, clearRight?, hullMargin? }
-- Returns throttle, steer, distance to the goal.
function Nav.Drive(s, tx: number, tz: number, P, opt)
    local dx, dz = tx - s.x, tz - s.z
    local distance = math.sqrt(dx * dx + dz * dz)
    local err = Nav.wrap(Nav.yawTo(s.x, s.z, tx, tz) - s.yaw)
    local steer = clamp(err / math.rad(18), -1, 1)
    local speed = math.abs(s.speed)
    local brake = speed * speed / (2 * P.coastDecel) + 4
    local throttle = clamp((distance - (opt.stop or 2)) / math.max(brake, 10), 0, 1) * (opt.cap or 1)
    local misaligned = math.abs(err)
    if misaligned > math.rad(55) then
        throttle = 0 -- turn on the spot first
    else
        throttle *= clamp(1 - misaligned / math.rad(75), 0.25, 1)
    end
    -- Obstacle awareness from the server's forward sweeps.
    -- (Only while heading toward the goal: when the mech is still turning round to face a validated waypoint, what lies ahead of its
    -- CURRENT heading says nothing about the route, and steering away from it would fight the turn.)
    local ahead = opt.clearAhead
    if ahead and misaligned < math.rad(30) then
        local margin = (opt.hullMargin or 3) + speed * 0.5
        if ahead < margin + brake then
            throttle *= clamp((ahead - margin) / math.max(brake, 6), 0, 1)
        end
        local left, right = opt.clearLeft or ahead, opt.clearRight or ahead
        if ahead < 22 and math.abs(left - right) > 2 then
            steer = clamp(steer + (if left > right then 0.6 else -0.6), -1, 1) -- veer toward the open side
        end
    end
    return throttle, steer, distance
end

-- Progress / stuck detection --------------------------------------------------------------------------------------------------
function Nav.NewProgress()
    return { clock = 0, sampleAt = 0, x = nil, z = nil, still = 0, stuck = false, stuckCount = 0, recover = nil }
end

-- Call every frame. `wants` is true while the mech is commanded to travel (throttle clearly non-zero); `turns` (with the current yaw)
-- is true while it is commanded to turn hard: a hull pressed against a wall cannot sweep round, and that is "stuck" too.
function Nav.Track(p, dt: number, x: number, z: number, wants: boolean, yaw: number?, turns: boolean?)
    p.clock += dt
    if p.x == nil then
        p.x, p.z, p.sampleAt, p.yaw = x, z, p.clock, yaw
        return p.stuck
    end
    if p.clock - p.sampleAt >= 0.5 then
        local moved = Nav.dist(x, z, p.x, p.z)
        local turned = if yaw and p.yaw then math.abs(Nav.wrap(yaw - p.yaw)) else math.huge
        p.x, p.z, p.sampleAt, p.yaw = x, z, p.clock, yaw
        if (wants and moved < 1.2) or (turns == true and moved < 1.2 and turned < math.rad(4)) then
            p.still += 0.5
        else
            p.still = math.max(0, p.still - 0.5)
        end
        if p.still >= 2.0 and not p.stuck and not p.recover then
            p.stuck = true
            p.stuckCount += 1
        end
    end
    return p.stuck
end

-- Reverse out of trouble: back up for `duration`, turning toward the side with more room. Returns throttle, steer, finished.
function Nav.Recover(p, dt: number, clearLeft: number?, clearRight: number?, duration: number?)
    local r = p.recover
    if not r then
        local side = if (clearLeft or 0) >= (clearRight or 0) then 1 else -1
        r = { t = 0, side = side, duration = duration or 1.8 }
        p.recover = r
    end
    r.t += dt
    if r.t >= r.duration then
        p.recover, p.stuck, p.still = nil, false, 0
        return 0, 0, true
    end
    return -0.7, r.side * 0.9, false
end

function Nav.ResetProgress(p)
    p.x, p.z, p.still, p.stuck, p.recover = nil, nil, 0, false, nil
end

-- Position choice ------------------------------------------------------------------------------------------------------------------
-- ctx = {
--   x, z            current position            tx, tz   estimate of the target
--   reason          "regain_los" | "flank" | "cover" | "range" | "recover_energy" | "search"
--   band            { near, far } preferred range    los    { [nodeId] = bool }   whether the node sees the target
--   recent          { [nodeId] = number }  penalty for places used a moment ago     minTravel   ignore nodes closer than this
-- }
-- Returns the best node and its score (lower is better), or nil.
function Nav.Pick(graph, ctx)
    local nodes = graph.nodes
    local mid = (ctx.band[1] + ctx.band[2]) / 2
    local selfAngle = math.atan2(ctx.z - ctx.tz, ctx.x - ctx.tx)
    local best, bestScore
    for _, node in ipairs(nodes) do
        if node.valid then
            local range = Nav.dist(node.x, node.z, ctx.tx, ctx.tz)
            local travel = Nav.dist(ctx.x, ctx.z, node.x, node.z)
            local sees = ctx.los[node.id] == true
            local score = 0
            local reason = ctx.reason
            if travel < (ctx.minTravel or 0) then
                score += 500
            end
            local outside = 0
            if range < ctx.band[1] then
                outside = ctx.band[1] - range
            elseif range > ctx.band[2] then
                outside = range - ctx.band[2]
            end
            if reason == "regain_los" or reason == "search" then
                score += (if sees then 0 else 220) + outside * 0.5 + travel * 0.35 + math.abs(range - mid) * 0.15
            elseif reason == "flank" then
                local a = math.atan2(node.z - ctx.tz, node.x - ctx.tx)
                local swing = math.deg(math.abs(Nav.wrap(a - selfAngle)))
                score += (if sees then 0 else 160) + outside * 0.6 + travel * 0.2 - math.min(swing, 100) * 0.9
            elseif reason == "cover" or reason == "recover_energy" then
                score += (if sees then 300 else 0) + travel * 0.6 + math.abs(range - (ctx.band[2] + mid) / 2) * 0.1
            elseif reason == "range" then
                score += (if range < ctx.band[1] then 240 else 0) + (if sees then 0 else 60) + math.abs(range - mid) * 0.8 + travel * 0.25
            else
                score += math.abs(range - mid) + travel * 0.3
            end
            local recent = ctx.recent and ctx.recent[node.id]
            if recent then
                score += recent
            end
            if not bestScore or score < bestScore then
                best, bestScore = node, score
            end
        end
    end
    return best, bestScore
end

-- Keeps a point inside the court rectangle (centre limits).
function Nav.Clamp(court, ox: number, oz: number, x: number, z: number): (number, number)
    return clamp(x, court.minX + ox, court.maxX + ox), clamp(z, court.minZ + oz, court.maxZ + oz)
end

return Nav
