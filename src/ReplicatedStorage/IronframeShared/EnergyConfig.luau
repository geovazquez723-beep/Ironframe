-- Component/chassis data -> runtime balance. No engine dependencies; units are energy, energy/sec and thermal percent.
local Config = {}
-- `mods` (optional, M11A) = the build's effective modifiers: { capacitorScale, chargeRateScale, thermalScale, coolingScale, movementEnergyScale }. Nothing
-- else changes: with no mods the result is exactly the M08A economy. referenceSpeed stays the chassis' own top speed, so a faster machine
-- really does pay more for the same fraction of its speed.
function Config.Build(chassis, reactor, capacitor, cooling, shield, mods)
    local capacityScale = mods and mods.capacitorScale or 1
    local movement = chassis.energy
    if mods and mods.movementEnergyScale and mods.movementEnergyScale ~= 1 then
        movement = table.clone(chassis.energy)
        for _, key in ipairs({ "drive", "speed", "acceleration", "turn", "braking", "sprintDemand" }) do
            movement[key] = chassis.energy[key] * mods.movementEnergyScale
        end
    end
    local thermalScale = mods and mods.thermalScale or 1
    return {
        output = reactor.powerOutput,
        referenceSpeed = chassis.locomotion.maxForward,
        capacity = capacitor.capacity * capacityScale, initialCharge = capacitor.initialCharge * capacityScale,
        chargeEfficiency = capacitor.chargeEfficiency, maxChargeRate = capacitor.maxChargeRate * (mods and mods.chargeRateScale or 1),
        maxDischargeRate = capacitor.maxDischargeRate, burstLimit = capacitor.burstLimit,
        cooling = cooling.coolingPerSecond * chassis.energy.coolingScale * (mods and mods.coolingScale or 1),
        thermalThreshold = 40, thermalMaximum = 100, outputPenalty = 0.45, chargePenalty = 0.5,
        thermalPerEnergy = 0.12 * thermalScale, thermalPerDischarge = 0.15 * thermalScale,
        movement = movement,
        shield = shield,
        weaponTestRate = 100, weaponTestDuration = 2,
    }
end
return Config
