-- Pure numeric helpers for M10B (no Roblox types): angle wrapping, target lead, ray/box sweeps and shell timing.
-- The server converts world vectors into these plain numbers; offline tests cover every function.

local Math = {}

function Math.wrap(a: number): number
    return (a + math.pi) % (2 * math.pi) - math.pi
end

-- Aim point on a target moving at (vx, vz): where it will be after `lead` x the shell's flight time.
-- Two refinement passes converge the flight time to the displaced point. Returns (ax, az, flightTime).
function Math.lead(ox: number, oz: number, tx: number, tz: number, vx: number, vz: number, speed: number, lead: number): (number, number, number)
    local t = math.sqrt((tx - ox) ^ 2 + (tz - oz) ^ 2) / speed
    local ax, az = tx, tz
    for _ = 1, 2 do
        ax, az = tx + vx * t * lead, tz + vz * t * lead
        t = math.sqrt((ax - ox) ^ 2 + (az - oz) ^ 2) / speed
    end
    return ax, az, t
end

-- Slab test of a ray against a box centred on the origin (half extents hx, hy, hz). The ray starts at (ox, oy, oz) with UNIT
-- direction (dx, dy, dz) and is tested over [0, maxT]. Returns (t, nx, ny, nz) for the first contact, or nil. A ray that starts
-- inside the box reports t = 0 with the normal opposing the direction. Inflating the half extents by a shell radius gives a
-- conservative swept-sphere test.
function Math.rayBox(ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, hx: number, hy: number, hz: number, maxT: number): (number?, number?, number?, number?)
    local tmin, tmax = 0, maxT
    local nx, ny, nz = 0, 0, 0
    local o = { ox, oy, oz }
    local d = { dx, dy, dz }
    local h = { hx, hy, hz }
    local inside = true
    for axis = 1, 3 do
        local origin, dir, half = o[axis], d[axis], h[axis]
        if math.abs(origin) > half then
            inside = false
        end
        if math.abs(dir) < 1e-9 then
            if math.abs(origin) > half then
                return nil
            end
        else
            local t1, t2 = (-half - origin) / dir, (half - origin) / dir
            local sign = -1
            if t1 > t2 then
                t1, t2 = t2, t1
                sign = 1
            end
            if t1 > tmin then
                tmin = t1
                nx, ny, nz = 0, 0, 0
                if axis == 1 then nx = sign elseif axis == 2 then ny = sign else nz = sign end
            end
            if t2 < tmax then
                tmax = t2
            end
            if tmin > tmax then
                return nil
            end
        end
    end
    if inside then
        return 0, -dx, -dy, -dz
    end
    return tmin, nx, ny, nz
end

-- Closest-approach time of a straight shell to a point (the Bastion's centre), and the miss distance at that time.
-- Returns (timeToClosest, missDistance); time is negative when the shell has already passed.
function Math.closest(px: number, py: number, pz: number, vx: number, vy: number, vz: number, cx: number, cy: number, cz: number): (number, number)
    local speed2 = vx * vx + vy * vy + vz * vz
    if speed2 < 1e-9 then
        return math.huge, math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2 + (cz - pz) ^ 2)
    end
    local t = ((cx - px) * vx + (cy - py) * vy + (cz - pz) * vz) / speed2
    local mx, my, mz = px + vx * t - cx, py + vy * t - cy, pz + vz * t - cz
    return t, math.sqrt(mx * mx + my * my + mz * mz)
end

-- Relative bearing in degrees of a world direction (x, z) from a facing yaw (MechDrive convention: heading = (-sin, -cos)).
-- 0 = dead ahead, +90 = to the pilot's right, -90 = left, +-180 = behind.
function Math.relativeBearing(yaw: number, dirX: number, dirZ: number): number
    local fx, fz = -math.sin(yaw), -math.cos(yaw)
    local cross = fx * dirZ - fz * dirX -- >0 when the direction lies to the right of the facing
    local dot = fx * dirX + fz * dirZ
    return math.deg(math.atan2(cross, dot))
end

return Math
