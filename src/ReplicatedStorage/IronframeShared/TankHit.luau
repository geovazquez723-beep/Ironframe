-- Pure hit-region rules for the training tank (M11B). No Roblox types: offline tests load this file directly.
--
-- Physical geometry decides WHERE a shell lands (the visible mesh, see TankParts); this module decides WHICH LOGICAL COMPONENT that surface
-- belongs to. Four of the tank's five components own a whole mesh (hull, turret, left track, right track). The engine has no mesh of its own: it
-- is the rear upper deck of the hull mesh, so a hit on that part of the hull resolves to ENGINE instead of HULL. The decision uses the registered
-- surface point in the tank-root frame (ground at y = 0, the tank faces -Z), never the part that was struck, so it stays correct while the
-- tank drives and while the hull is posed by damage.

local TankHit = {}

-- Rear deck of the hull mesh (tank-root frame, studs). The mesh's top surface reaches y = 8.5; the louvred engine grilles lie behind the turret ring.
TankHit.engine = { minZ = 1.0, minY = 6.0 }

-- Returns "ENGINE" or "HULL" for a point on the hull mesh given in the tank-root frame.
function TankHit.HullComponent(y: number, z: number): string
    local e = TankHit.engine
    if z >= e.minZ and y >= e.minY then
        return "ENGINE"
    end
    return "HULL"
end

-- Bounded instance budget of one tank's damage presentation (TrainingTank reads these; the offline tests add them up). Everything the tank builds when
-- it is damaged is a welded, non-queryable part owned by the model, so a reset removes all of it.
TankHit.Limits = {
    pits = 16, -- machine-gun marks (recycled oldest first)
    burns = 6, -- laser char rings (a molten dot is added for ~2.6 s and removed)
    craters = 6, craterParts = 4, -- heavy marks: crater, rim, two cracks
    linksPerTrack = 10, lostWheelParts = 2, -- a broken track: thrown tread and a lost road wheel (two tracks at most)
    plates = 8, -- hull breakup plates
    shells = 4, -- soot shells over the four meshes
    anchors = 6, -- invisible effect anchors (engine, turret vent, gun mount, two track hubs, spare)
    engineParts = 2, -- engine burn patch and ember
}

function TankHit.MaxParts(): number
    local l = TankHit.Limits
    return l.pits + l.burns + 1 + l.craters * l.craterParts + 2 * (l.linksPerTrack + l.lostWheelParts) + l.plates + l.shells + l.anchors + l.engineParts
end

-- Delays (seconds after the failure) of the beats of the destruction sequences; TrainingTank schedules them, the tests check order and duration.
TankHit.Sequence = {
    TRACK = { animate = 0.55 }, -- the track sags into its broken pose
    TURRET = { animate = 0.4 }, -- the turret slumps
    HULL = { turretThrow = 0.3, cookoff1 = 0.55, cookoff2 = 1.0, plates = 1.0, wreck = 1.1, animate = 0.7 },
}

-- Cosmetic event kind each component loss sends (DestructionFx has a branch for each).
TankHit.FailureEvent = { TRACK_L = "trackbreak", TRACK_R = "trackbreak", TURRET = "turretbreak", HULL = "explosion", ENGINE = "explosion" }

return TankHit
