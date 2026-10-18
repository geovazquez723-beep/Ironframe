-- Cockpit annunciator rules (M11C). Pure: real telemetry in, a caution level per lamp out. The six lamps on the dash are never arbitrary alarms; each
-- one lights only for the condition it names, amber for a caution and red for a critical state. There is no sound and no continuous flashing: only a
-- critical lamp pulses.
--
--   CAP   capacitor reserve          RCTR  reactor housing / output       SENS  sensors (a fitted radar or module is impaired)
--   THRM  thermal load               WPN   weapon assemblies              CORE  core structure
-- Levels: 0 normal, 1 caution, 2 critical.
local Warnings = {}

Warnings.Keys = { "CAP", "RCTR", "SENS", "THRM", "WPN", "CORE" }

-- v: { deployed, capFraction, reactorFraction, reactorFactor, coreFraction, thermal, radarFitted, radarState, impaired, armsFailed }
function Warnings.Evaluate(v: any): { [string]: number }
    local out = { CAP = 0, RCTR = 0, SENS = 0, THRM = 0, WPN = 0, CORE = 0 }
    if v.deployed then
        local cap = v.capFraction or 1
        out.CAP = if cap <= 0.06 then 2 elseif cap <= 0.15 then 1 else 0
        local thermal = v.thermal or 0
        out.THRM = if thermal >= 90 then 2 elseif thermal >= 70 then 1 else 0
    end
    local reactor, factor = v.reactorFraction or 1, v.reactorFactor or 1
    out.RCTR = if reactor <= 0.25 or factor <= 0.5 then 2 elseif reactor <= 0.6 or factor < 0.999 then 1 else 0
    local core = v.coreFraction or 1
    out.CORE = if core <= 0.25 then 2 elseif core <= 0.6 then 1 else 0
    local arms = v.armsFailed or 0
    out.WPN = if arms >= 2 then 2 elseif arms == 1 then 1 else 0
    if v.deployed and v.radarFitted then
        out.SENS = if v.radarState == "OFFLINE" or v.radarState == "NONE" then 2 elseif v.radarState == "DEGRADED" or v.impaired then 1 else 0
    end
    return out
end

return Warnings
