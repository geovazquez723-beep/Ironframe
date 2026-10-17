-- Pure functional rules for multi-component training machines. Input: a table of Units by component name.
-- Both the armored training tank and the stationary training mech read their operational status from here, so the server
-- code only reacts to status CHANGES and the offline tests can prove the rules without Roblox.
--
-- Training machines are unmanned and autonomous: nothing in this file models an occupant, an injury or a casualty.

local Rules = {}

local function down(units, name)
    local u = units[name]
    return u ~= nil and u.health <= 0
end

-- Tank components: HULL, TURRET, TRACK_L, TRACK_R, ENGINE.
--   hull destroyed       -> vehicle destroyed (everything disabled)
--   either track gone    -> mobility disabled
--   engine gone          -> mobility disabled, fire
--   turret gone          -> turret/weapon disabled, hull still mobile
function Rules.Tank(units)
    local destroyed = down(units, "HULL")
    local trackLost = down(units, "TRACK_L") or down(units, "TRACK_R")
    local engineLost = down(units, "ENGINE")
    return {
        destroyed = destroyed,
        mobile = not destroyed and not trackLost and not engineLost,
        turretOperational = not destroyed and not down(units, "TURRET"),
        trackLost = trackLost,
        engineLost = engineLost,
        disabled = destroyed, -- "VEHICLE DESTROYED"
        status = if destroyed then "VEHICLE DESTROYED"
            elseif trackLost or engineLost then "IMMOBILIZED"
            elseif down(units, "TURRET") then "TURRET DISABLED"
            else "OPERATIONAL",
    }
end

-- Training-mech components: CHASSIS, ARM_MOUNT, SHOULDER_ARMOR, LEG_ASSEMBLY.
--   chassis destroyed    -> TARGET DISABLED (terminal)
--   leg assembly gone    -> kneeling, cannot be repositioned
--   arm mount gone       -> weapon mount lost
function Rules.Mech(units)
    local disabled = down(units, "CHASSIS")
    return {
        disabled = disabled,
        weaponMountLost = down(units, "ARM_MOUNT"),
        armorLost = down(units, "SHOULDER_ARMOR"),
        legsLost = down(units, "LEG_ASSEMBLY"),
        status = if disabled then "TARGET DISABLED"
            elseif down(units, "LEG_ASSEMBLY") then "MOBILITY DISABLED"
            elseif down(units, "ARM_MOUNT") then "WEAPON MOUNT LOST"
            elseif down(units, "SHOULDER_ARMOR") then "ARMOR STRIPPED"
            else "OPERATIONAL",
    }
end

-- Number of components in each stage, for the range display.
function Rules.Count(units)
    local counts = { INTACT = 0, DAMAGED = 0, DESTROYED = 0 }
    for _, u in pairs(units) do
        counts[u.stage] += 1
    end
    return counts
end

return Rules
