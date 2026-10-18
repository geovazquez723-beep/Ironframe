-- Shared target contract (M11C): what a combat actor must expose to be detected, tracked and shown on the avionics. The sensor service
-- never reads tank or mech internals; every kind of actor (training tank, ROOK, a future second chassis, a drone) is adapted into this
-- one flat table by a provider, so the radar, tracker and thermal view are written once.
--
--   id            unique stable string ("T-01", "ROOK-01")
--   label         what the display calls it once identified
--   kind          "VEHICLE" | "MECH"
--   arch          archetype tag shown on identification ("SENTRY", "HEAVY", "PATROL"), optional
--   x, y, z, yaw  world position of the machine centre (studs) and heading (radians; 0 faces -Z, positive turns left, as the drive model)
--   speed         studs / s along its heading (signed)
--   speedMax      its normal top speed, for the thermal rule
--   operational   can fight; disabled = not (any reason); destroyed = permanently wrecked
--   powered       reactor / engine running (thermal rule)
--   reactorHeat   0..1, the machine's own thermal ledger share, when it has one
--   firedAgo      seconds since its last shot, when known
--   burning       true while a wreck burns
--   size          { x, y, z } nominal bounding box, for the tracking box
--   model         Instance of the machine (server side; only ever sent to the owner while locked or thermally visible)
--   components    function() -> { { key, name, fraction (0..1), offline (bool) } } , used only at tracker detail 2
local Contract = {}

Contract.Kinds = { VEHICLE = true, MECH = true }

local function finite(v: any): boolean
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end

function Contract.Validate(actor: any): (boolean, string?)
    if type(actor) ~= "table" then
        return false, "not a table"
    end
    if type(actor.id) ~= "string" or #actor.id == 0 or #actor.id > 32 then
        return false, "bad id"
    end
    if type(actor.label) ~= "string" then
        return false, "bad label"
    end
    if not Contract.Kinds[actor.kind] then
        return false, "bad kind"
    end
    for _, field in ipairs({ "x", "y", "z", "yaw", "speed" }) do
        if not finite(actor[field]) then
            return false, "bad " .. field
        end
    end
    for _, field in ipairs({ "operational", "disabled", "destroyed" }) do
        if type(actor[field]) ~= "boolean" then
            return false, "bad " .. field
        end
    end
    return true, nil
end

-- Component condition band for a damage fraction, with the same thresholds the Bastion damage model uses.
function Contract.Band(fraction: number, offline: boolean?): string
    if offline or fraction <= 0 then
        return "OFFLINE"
    end
    return if fraction <= 0.25 then "CRITICAL" elseif fraction <= 0.6 then "DAMAGED" else "NOMINAL"
end

return Contract
