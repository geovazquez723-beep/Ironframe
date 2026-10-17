-- Pure directional defense. Attack data comes from server combat/test systems, never a client hit report.
local Shield = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
function Shield.New(config)
    return { state = "READY", time = 0, phaseStart = 0, phaseEnd = 0, cooldownUntil = 0,
        integrity = config.integrity, serial = 0, impactSerial = 0, lastResult = nil, reason = "READY" }
end
local function phase(s, state, duration)
    s.state, s.phaseStart, s.phaseEnd = state, s.time, s.time + duration
end
function Shield.Protects(s) return s.state == "PERFECT_GUARD" or s.state == "ACTIVE" end
function Shield.Cooldown(s) return math.max(0, s.cooldownUntil - s.time) end
function Shield.Cancel(s, config)
    if s.state == "CHARGING" or Shield.Protects(s) then
        phase(s, "RECOVERY", config.recoveryTime)
        if s.reason ~= "SUSTAIN ENERGY LOW" then s.reason = "RECOVERY" end
    end
end
function Shield.Activate(s, config, spend, enabled)
    if not enabled then s.reason = "DEPLOY FIRST"; return false end
    if s.state ~= "READY" then s.reason = "SHIELD " .. s.state; return false end
    if not finite(config.activationCost) or config.activationCost <= 0 then s.reason = "INVALID GENERATOR"; return false end
    if not spend(config.activationCost) then s.reason = "CAPACITOR LOW"; return false end
    s.serial += 1
    s.integrity = config.integrity
    s.reason = "CHARGING"
    s.cooldownUntil = s.time + config.chargeTime + config.perfectTime + config.activeTime + config.recoveryTime + config.cooldown
    phase(s, "CHARGING", config.chargeTime)
    return true
end
function Shield.Advance(s, config, elapsed, enabled)
    if not finite(elapsed) or elapsed < 0 then return end
    if not enabled then Shield.Cancel(s, config) end
    s.time += math.min(elapsed, 0.25)
    for _ = 1, 6 do
        if s.state == "READY" or s.time + 1e-9 < s.phaseEnd then break end
        local at = s.phaseEnd
        if s.state == "CHARGING" then
            s.state, s.phaseStart, s.phaseEnd = "PERFECT_GUARD", at, at + config.perfectTime
        elseif s.state == "PERFECT_GUARD" then
            s.state, s.phaseStart, s.phaseEnd = "ACTIVE", at, at + config.activeTime
        elseif s.state == "ACTIVE" then
            s.state, s.phaseStart, s.phaseEnd = "RECOVERY", at, at + config.recoveryTime
        elseif s.state == "RECOVERY" then
            s.state, s.phaseStart, s.phaseEnd = "COOLDOWN", at, math.max(at, s.cooldownUntil)
        elseif s.state == "COOLDOWN" then
            s.state, s.phaseStart, s.phaseEnd = "READY", at, at
            s.reason = "READY"
        end
        if s.reason == "CHARGING" or s.reason == "PERFECT_GUARD" or s.reason == "ACTIVE" or s.reason == "RECOVERY" then s.reason = s.state end
    end
end

-- fromX/fromZ point FROM the victim TOWARD the attacker in world space. yaw follows MechDrive's convention.
-- consume(amount) returns the energy actually removed, allowing a partially exhausted shield to mitigate partially.
function Shield.Resolve(s, config, attack, yaw, consume)
    if type(attack) ~= "table" or not finite(attack.damage) or attack.damage < 0
        or not finite(attack.fromX) or not finite(attack.fromZ) or not finite(yaw)
        or not config.mitigation[attack.category] then return nil, "invalid server attack" end
    local damage = attack.damage
    local result = { damage = damage, prevented = 0, penetrating = damage, energy = 0, integrity = s.integrity,
        category = attack.category, timing = "UNGUARDED" }
    local length = math.sqrt(attack.fromX ^ 2 + attack.fromZ ^ 2)
    if Shield.Protects(s) and length > 1e-6 then
        local dot = (-math.sin(yaw) * attack.fromX - math.cos(yaw) * attack.fromZ) / length
        if dot >= config.arcCos then
            local perfect = s.state == "PERFECT_GUARD"
            local angular = 0.65 + 0.35 * (dot - config.arcCos) / (1 - config.arcCos)
            local ratio = math.min(if perfect then 0.98 else 0.82, config.mitigation[attack.category] * config.quality * (if perfect then config.perfectMultiplier else 1)) * angular
            local desired = math.min(damage * ratio, s.integrity)
            local perDamage = config.impactEnergy * (if perfect then 0.5 else 1)
            if perDamage <= 0 or not finite(perDamage) then return nil, "invalid generator impact cost" end
            local used = consume(desired * perDamage)
            result.energy = math.clamp(used, 0, desired * perDamage)
            result.prevented = math.min(desired, result.energy / perDamage)
            result.penetrating = math.max(0, damage - result.prevented)
            s.integrity = math.max(0, s.integrity - result.prevented)
            result.integrity = s.integrity
            result.timing = if perfect then "PERFECT" else "GUARD"
            if s.integrity == 0 or result.prevented + 1e-6 < desired then Shield.Cancel(s, config) end
        else result.timing = "OFF_AXIS" end
    end
    s.impactSerial += 1
    s.lastResult = result
    return result
end
return Shield
