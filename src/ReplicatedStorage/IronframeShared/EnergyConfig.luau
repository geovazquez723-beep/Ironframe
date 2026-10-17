-- Component/chassis data -> runtime balance. No engine dependencies; units are energy, energy/sec and thermal percent.
local Config = {}
function Config.Build(chassis, reactor, capacitor, cooling, shield)
    return {
        output = reactor.powerOutput,
        referenceSpeed = chassis.locomotion.maxForward,
        capacity = capacitor.capacity, initialCharge = capacitor.initialCharge,
        chargeEfficiency = capacitor.chargeEfficiency, maxChargeRate = capacitor.maxChargeRate,
        maxDischargeRate = capacitor.maxDischargeRate, burstLimit = capacitor.burstLimit,
        cooling = cooling.coolingPerSecond * chassis.energy.coolingScale,
        thermalThreshold = 40, thermalMaximum = 100, outputPenalty = 0.45, chargePenalty = 0.5,
        thermalPerEnergy = 0.12, thermalPerDischarge = 0.15,
        movement = chassis.energy,
        shield = shield,
        weaponTestRate = 100, weaponTestDuration = 2,
    }
end
return Config
