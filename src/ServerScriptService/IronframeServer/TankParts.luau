-- Precise hit meshes for the textured training tank (M11B).
--
-- Why this exists: through M11A the AI tank (TNK_001) was drawn by four visual-only MeshParts (CanQuery = false) and hit by a handful of
-- hand-placed invisible boxes. The boxes were up to several studs larger than the armour (the turret box rose above the roof, the barrel box
-- floated beside the real, off-centre gun), so shells "struck" air. The fix is not bigger or smaller boxes: the visible mesh itself is the
-- hit geometry.
--
-- How: MeshPart.CollisionFidelity cannot be changed on a MeshPart that was loaded from the cloud model, but
-- AssetService:CreateMeshPartAsync accepts it as an option. Each tank mesh is rebuilt ONCE per server as a PreciseConvexDecomposition
-- MeshPart (about one second each, in parallel, during world setup), the texture is copied across, and every tank clones that part. A clone keeps
-- the collision data, so building or resetting a tank never touches the decomposer. Measured against the raw triangle data of the mesh (Studio,
-- docs/M11B_PHYSICAL_COMBAT_FIDELITY.md) the precise proxy lies within 0.03 studs of the visible surface on average.
--
-- If a mesh cannot be rebuilt (no AssetService permission, failed decomposition) the tank falls back to the M11A boxes and reports
-- `HitFidelity = "BOX"` on its model, so the degradation is visible to the audit and the diagnostic overlay instead of silent.

local AssetService = game:GetService("AssetService")

local TankParts = {}

local ready: { [string]: MeshPart } = {}
local failures: { [string]: string } = {}
local prepared = false

TankParts.stats = { built = 0, failed = 0, seconds = 0 }

-- `sources`: key -> MeshPart of the cached template. Yields until every part is built (or has failed).
function TankParts.Prepare(sources: { [string]: MeshPart }): (number, number)
    if prepared then
        return TankParts.stats.built, TankParts.stats.failed
    end
    prepared = true
    local started = os.clock()
    local pending = 0
    for key, source in pairs(sources) do
        pending += 1
        task.spawn(function()
            local ok, result = pcall(AssetService.CreateMeshPartAsync, AssetService, source.MeshContent, {
                CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
                RenderFidelity = source.RenderFidelity,
            })
            if ok and result and result.CollisionFidelity == Enum.CollisionFidelity.PreciseConvexDecomposition then
                local part: MeshPart = result
                part.Name = source.Name
                part.TextureID = source.TextureID
                part.Size = source.Size
                part.Material, part.Color, part.Reflectance = source.Material, source.Color, source.Reflectance
                part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
                ready[key] = part
                TankParts.stats.built += 1
            else
                failures[key] = tostring(result)
                TankParts.stats.failed += 1
            end
            pending -= 1
        end)
    end
    local deadline = os.clock() + 90
    while pending > 0 and os.clock() < deadline do
        task.wait(0.05)
    end
    TankParts.stats.seconds = os.clock() - started
    for key, message in pairs(failures) do
        warn(string.format("[IF-TANK] precise hit mesh '%s' unavailable, tanks fall back to box hit volumes: %s", key, message))
    end
    return TankParts.stats.built, TankParts.stats.failed
end

-- The precise part for `key` (callers must Clone it), or nil.
function TankParts.Get(key: string): MeshPart?
    return ready[key]
end

function TankParts.Complete(keys: { string }): boolean
    for _, key in ipairs(keys) do
        if not ready[key] then
            return false
        end
    end
    return true
end

return TankParts
