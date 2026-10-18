-- Server side of the fitted mech hit volumes (M11B). The pure fitting and ray code is IronframeShared/VolumeHit; this file reads the built rig and
-- converts between the chassis frame and the world.
--
--   Build(model)                      fits oriented boxes to every armour / frame / joint / reactor / weapon part of a MechFactory model, in the chassis
--                                     frame (rest pose: MechRig.Solve(identity) * each part's LocalCF - the same numbers the clients pose the drawn rig from)
--   Ray(volumes, chassisCF, ...)      first surface along a world ray, normal and point back in world space
--
-- Nothing here is replicated: the volumes are plain tables, so a moving mech costs no network traffic for its hit geometry (the M10C hit parts had to be
-- re-moved and re-replicated every time ROOK moved). The Studio overlay (HitDebug) draws them from the same tables.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IronframeShared")
local MechRig = require(Shared:WaitForChild("MechRig"))
local VolumeHit = require(Shared:WaitForChild("VolumeHit"))

local MechHit = {}

MechHit.stats = { fits = 0, rays = 0 }

local function shapeOf(part: BasePart): string
    if part:IsA("WedgePart") then
        return "Wedge"
    elseif part:IsA("MeshPart") then
        return "Mesh"
    elseif part:IsA("Part") then
        return (part :: Part).Shape.Name
    end
    return "Block"
end
VolumeHit.shrink.Mesh = { 0.85, 0.85, 0.85 } -- AI-generated armour: the bounding box is larger than the surface

function MechHit.Build(model: Model)
    local rest = MechRig.Solve(CFrame.identity, nil)
    local parts = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("Joint") and not d:GetAttribute("LinkId") and d.Transparency < 0.95 then
            local joint = rest[d:GetAttribute("Joint")]
            local local_ = d:GetAttribute("LocalCF")
            if joint and typeof(local_) == "CFrame" then
                local cf = joint * local_
                table.insert(parts, {
                    name = d.Name, joint = d:GetAttribute("Joint"), group = d:GetAttribute("Group"), shape = shapeOf(d),
                    size = { d.Size.X, d.Size.Y, d.Size.Z }, m = { cf:GetComponents() },
                })
            end
        end
    end
    local fit = VolumeHit.Fit(parts)
    fit.bounds = VolumeHit.Bounds(fit.boxes)
    MechHit.stats.fits += 1
    return fit
end

-- World ray -> { t, comp, normal, position } | nil. `chassisCF` is Locomotion.ChassisCFrame of the machine; `inflate` is a swept-sphere radius.
function MechHit.Ray(volumes, chassisCF: CFrame, origin: Vector3, direction: Vector3, maxT: number, inflate: number?)
    MechHit.stats.rays += 1
    local lo, ld = chassisCF:PointToObjectSpace(origin), chassisCF:VectorToObjectSpace(direction)
    local hit = VolumeHit.Ray(volumes.boxes, volumes.bounds, lo.X, lo.Y, lo.Z, ld.X, ld.Y, ld.Z, maxT, inflate)
    if not hit then
        return nil
    end
    return {
        t = hit.t, comp = hit.region, normal = chassisCF:VectorToWorldSpace(Vector3.new(hit.nx, hit.ny, hit.nz)), position = origin + direction * hit.t,
        index = hit.index,
    }
end

-- The P-01 shield is a forward plane (client ShieldClient: 22 x 16 studs, 13 studs ahead of the chassis, centred 10 up). Where a shot's path crosses
-- it is where an interception is DRAWN, outside the hull, so a shield-absorbed round reads as a shield interaction and not as a round striking
-- invisible armour. `contact` is the armour contact, `direction` the unit direction of travel. Returns nil when the path does not cross the plane
-- (flank / rear hits).
MechHit.shieldPlane = { z = -13, halfWidth = 11, centreY = 10, halfHeight = 8 }
function MechHit.ShieldPoint(chassisCF: CFrame, contact: Vector3, direction: Vector3): Vector3?
    local o, d = chassisCF:PointToObjectSpace(contact), chassisCF:VectorToObjectSpace(direction)
    local x, y, z = VolumeHit.PlaneCrossing(MechHit.shieldPlane, o.X, o.Y, o.Z, d.X, d.Y, d.Z)
    if not x then
        return nil
    end
    return chassisCF:PointToWorldSpace(Vector3.new(x, y :: number, z :: number))
end

-- World-space box list for the overlay: { { cf = CFrame (chassis frame), size = Vector3, region = string } }.
function MechHit.Boxes(volumes)
    local list = {}
    for _, b in ipairs(volumes.boxes) do
        local cf = CFrame.new(b.c[1], b.c[2], b.c[3], b.r[1], b.r[2], b.r[3], b.r[4], b.r[5], b.r[6], b.r[7], b.r[8], b.r[9])
        table.insert(list, { cf = cf, size = Vector3.new(b.h[1] * 2, b.h[2] * 2, b.h[3] * 2), region = b.region })
    end
    return list
end

return MechHit
