-- Pure compound hit volumes for the rigged mechs (M11B). No Roblox types: offline tests load this file.
--
-- Through M11A a mech was hit either through ONE box around the whole machine (the Bastion, when a tank shell flew at it) or through 18 hand-placed
-- boxes (ROOK). Measured against the drawn armour those boxes were 1-2 studs off on average and up to 6 studs away: shots registered on air between the
-- limbs. The rig is made of ~480 plain parts whose rest pose is known exactly (RigSpec / MechRig.Solve + each part's LocalCF), so the hit volumes are now
-- FITTED to that geometry: every armour / frame / joint / reactor / weapon part of useful size becomes one oriented box in the chassis frame,
-- classified into the SAME damage region the rest of the game uses (MechDamage.ClassifyPart), with a shrink for rounded shapes so the box does not
-- claim the empty corners of a cylinder or a wedge.
--
-- `Fit` is data in, data out; the server extracts the parts (Joint / LocalCF / Group attributes) and calls `Ray` in the chassis frame. A ray is
-- resolved to the FIRST surface along its path (nearest box), so overlapping volumes of the same machine damage one region once.
--
-- Limit (documented in docs/M11B_PHYSICAL_COMBAT_FIDELITY.md): the volumes are the machine's rest pose carried with the chassis. Client animation
-- (gait, arm aiming) moves the drawn limbs by up to a few studs while walking, and the server does not see that pose.

local Math = if script then require((script :: any).Parent.CombatMath) else require("./CombatMath" :: any)
local Damage = if script then require((script :: any).Parent.MechDamage) else require("./MechDamage" :: any)

local VolumeHit = {}

-- Which rig-part groups carry armour / structure that a shot can strike. Hydraulics, glow strips and detail parts are decoration.
VolumeHit.keepGroups = { armor = true, frame = true, joint = true, reactor = true, weapon = true }
VolumeHit.minDimension = 0.9 -- longest side below this is greeble
VolumeHit.minVolume = 0.9
VolumeHit.weaponMinDimension = 0.5 -- barrels are thin but real
VolumeHit.shrink = {
    Ball = { 0.88, 0.88, 0.88 },
    Cylinder = { 1.0, 0.9, 0.9 }, -- axis along local X
    Wedge = { 1.0, 0.72, 0.82 },
}

export type Part = { name: string, joint: string?, group: string?, shape: string?, size: { number }, m: { number } }
export type Box = { region: string, c: { number }, r: { number }, h: { number }, name: string }

-- m = the 12 numbers of CFrame:GetComponents(): x, y, z, R00 R01 R02 R10 R11 R12 R20 R21 R22 (row-major rotation, columns are the local axes).
-- Returns { boxes, counts = { [region] = n }, dropped }.
function VolumeHit.Fit(parts: { Part }): { boxes: { Box }, counts: { [string]: number }, dropped: number }
    local boxes, counts, dropped = {}, {}, 0
    for _, p in ipairs(parts) do
        local sx, sy, sz = p.size[1], p.size[2], p.size[3]
        local group = p.group or "frame"
        local longest = math.max(sx, sy, sz)
        local floor = if group == "weapon" then VolumeHit.weaponMinDimension else VolumeHit.minDimension
        if not VolumeHit.keepGroups[group] or p.name == "RigRoot" or longest < floor or (sx * sy * sz) < VolumeHit.minVolume * (if group == "weapon" then 0.25 else 1) then
            dropped += 1
        else
            local k = VolumeHit.shrink[p.shape or "Block"] or { 1, 1, 1 }
            local m = p.m
            local region = Damage.ClassifyPart(p.name, p.joint, p.group, m[1])
            table.insert(boxes, {
                region = region, name = p.name,
                c = { m[1], m[2], m[3] },
                r = { m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12] },
                h = { sx * k[1] / 2, sy * k[2] / 2, sz * k[3] / 2 },
            })
            counts[region] = (counts[region] or 0) + 1
        end
    end
    return { boxes = boxes, counts = counts, dropped = dropped }
end

-- Bounding sphere of every box (broad phase): { cx, cy, cz, radius }.
function VolumeHit.Bounds(boxes: { Box }): { number }
    local mn, mx = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for _, b in ipairs(boxes) do
        local reach = math.sqrt(b.h[1] ^ 2 + b.h[2] ^ 2 + b.h[3] ^ 2)
        for axis = 1, 3 do
            mn[axis] = math.min(mn[axis], b.c[axis] - reach)
            mx[axis] = math.max(mx[axis], b.c[axis] + reach)
        end
    end
    if #boxes == 0 then
        return { 0, 0, 0, 0 }
    end
    local cx, cy, cz = (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2
    return { cx, cy, cz, math.sqrt((mx[1] - cx) ^ 2 + (mx[2] - cy) ^ 2 + (mx[3] - cz) ^ 2) }
end

-- Ray (origin o, UNIT direction d, over [0, maxT]) against the boxes, all in the boxes' own frame. `inflate` grows every box by a swept-sphere
-- radius. Returns the nearest contact { t, region, index, nx, ny, nz } (normal in the boxes' frame) or nil.
function VolumeHit.Ray(boxes: { Box }, bounds: { number }?, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, maxT: number, inflate: number?)
    local grow = inflate or 0
    if bounds and bounds[4] > 0 then
        -- Closest approach of the SEGMENT [0, maxT] to the bounding sphere's centre.
        local t = (bounds[1] - ox) * dx + (bounds[2] - oy) * dy + (bounds[3] - oz) * dz
        t = math.clamp(t, 0, maxT)
        local mx, my, mz = ox + dx * t - bounds[1], oy + dy * t - bounds[2], oz + dz * t - bounds[3]
        if mx * mx + my * my + mz * mz > (bounds[4] + grow) ^ 2 then
            return nil -- the segment never comes near the machine
        end
    end
    local bestT, bestIndex, bnx, bny, bnz = maxT, nil, 0, 0, 0
    for i, b in ipairs(boxes) do
        local r = b.r
        -- into the box frame: local = R^T * (world - c)
        local px, py, pz = ox - b.c[1], oy - b.c[2], oz - b.c[3]
        local lox = r[1] * px + r[4] * py + r[7] * pz
        local loy = r[2] * px + r[5] * py + r[8] * pz
        local loz = r[3] * px + r[6] * py + r[9] * pz
        local ldx = r[1] * dx + r[4] * dy + r[7] * dz
        local ldy = r[2] * dx + r[5] * dy + r[8] * dz
        local ldz = r[3] * dx + r[6] * dy + r[9] * dz
        local t, nx, ny, nz = Math.rayBox(lox, loy, loz, ldx, ldy, ldz, b.h[1] + grow, b.h[2] + grow, b.h[3] + grow, bestT)
        if t and t <= bestT then
            -- tie goes to the earlier box (stable); a start inside a box (t = 0) is a contact at the origin
            if bestIndex == nil or t < bestT then
                bestT, bestIndex = t, i
                -- normal back to the outer frame: world = R * local
                local lnx, lny, lnz = nx :: number, ny :: number, nz :: number
                bnx = r[1] * lnx + r[2] * lny + r[3] * lnz
                bny = r[4] * lnx + r[5] * lny + r[6] * lnz
                bnz = r[7] * lnx + r[8] * lny + r[9] * lnz
            end
        end
    end
    if not bestIndex then
        return nil
    end
    return { t = bestT, region = boxes[bestIndex].region, index = bestIndex, nx = bnx, ny = bny, nz = bnz }
end

-- Where a straight path crosses a vertical rectangular plane (the pulse shield, in the chassis frame: the plane z = `plane.z`, centred x = 0 and
-- y = plane.centreY, half extents halfWidth / halfHeight). (ox, oy, oz) is the contact point and (dx, dy, dz) the UNIT direction of travel, both in the
-- chassis frame (front = -Z, so a shot from the front travels toward +Z). Returns (x, y, z) of the crossing, or nil when the path does not cross the
-- rectangle BEFORE the contact (flank / rear shots, or a contact that is already in front of the plane).
function VolumeHit.PlaneCrossing(plane: { z: number, halfWidth: number, centreY: number, halfHeight: number }, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number): (number?, number?, number?)
    if dz <= 0.05 then
        return nil
    end
    local t = (plane.z - oz) / dz
    if t > 0 then
        return nil
    end
    local x, y = ox + dx * t, oy + dy * t
    if math.abs(x) > plane.halfWidth or math.abs(y - plane.centreY) > plane.halfHeight then
        return nil
    end
    return x, y, plane.z
end

return VolumeHit
