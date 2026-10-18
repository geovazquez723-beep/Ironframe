-- Simulated thermal signature (M11C). This is a GAME rule, not heat physics: a machine's signature is a number from 0 (ambient) to 1
-- (white-hot) derived from what the machine is actually doing, and it is the only input of the thermal view's brightness.
--
--   running engine / reactor    a steady base signature; hotter while moving and with the machine's own reactor heat where it has one
--   recent weapon fire          adds a pulse that cools back over FIRE_COOL seconds
--   engine / reactor lost       the signature at the moment of failure cools exponentially (half-life COOL_HALF_LIFE); a wreck that
--                               burns (engine fire) is the caller's `burning` flag and holds extra heat for BURN_TIME
--   intact but unpowered        ambient-warm metal, barely above the background
--
-- Seeing a signature also needs line of sight (the server checks it); nothing here can reveal a hidden machine.

local Thermal = {}

Thermal.IDLE = 0.42 -- running engine / reactor at idle
Thermal.MOVING = 0.18 -- added while moving, scaled by speed fraction
Thermal.REACTOR = 0.28 -- weight of the machine's own reactor heat fraction (0..1)
Thermal.FIRE = 0.34 -- peak pulse after a shot
Thermal.FIRE_COOL = 6 -- seconds for the pulse to fade
Thermal.COOL_HALF_LIFE = 28 -- seconds
Thermal.AMBIENT = 0.06
Thermal.BURN = 0.22 -- extra while an engine fire / burning wreck lasts
Thermal.BURN_TIME = 45 -- seconds a fire keeps adding heat after the machine went down

function Thermal.Band(level: number): string
    return if level >= 0.7 then "HOT" elseif level >= 0.4 then "WARM" elseif level >= 0.15 then "COOL" else "COLD"
end

-- actor: { powered (engine / reactor running), destroyed, speed, speedMax, reactorHeat (0..1, optional), firedAgo (seconds, optional), burning }
-- memory: per-actor table owned by the caller. It must be updated continuously (also while the machine is out of sight) because a machine that
-- is seen already dead has no history: it is treated as cold. A machine seen running and then losing power cools from the level it had.
function Thermal.Level(memory: any, actor: any, now: number): number
    local running = actor.powered and not actor.destroyed
    local level
    if running then
        memory.downAt, memory.downLevel = nil, nil
        local speedFraction = math.clamp(math.abs(actor.speed or 0) / math.max(actor.speedMax or 1, 1e-3), 0, 1)
        level = Thermal.IDLE + Thermal.MOVING * speedFraction + Thermal.REACTOR * math.clamp(actor.reactorHeat or 0, 0, 1)
        memory.upLevel = level
    elseif memory.upLevel or memory.downAt then
        if not memory.downAt then
            memory.downAt = now
            memory.downLevel = memory.upLevel or Thermal.IDLE
        end
        level = memory.downLevel * 0.5 ^ ((now - memory.downAt) / Thermal.COOL_HALF_LIFE)
        if actor.burning and now - memory.downAt < Thermal.BURN_TIME then
            level += Thermal.BURN
        end
    else
        level = Thermal.AMBIENT
    end
    if actor.firedAgo and actor.firedAgo >= 0 and actor.firedAgo < Thermal.FIRE_COOL then
        level += Thermal.FIRE * (1 - actor.firedAgo / Thermal.FIRE_COOL) ^ 1.5
    end
    return math.clamp(level, 0, 1)
end

return Thermal
