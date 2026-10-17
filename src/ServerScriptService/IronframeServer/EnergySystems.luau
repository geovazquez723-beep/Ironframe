-- Authoritative adapter for the pure ledger/shield. No client may specify damage, cost, timing or mitigation.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("IronframeShared")
local Energy = require(Shared.Energy)
local Shield = require(Shared.PulseShield)
local Profiles = require(Shared.EnergyProfiles)
local Systems = {}
Systems.TestPatterns = {
    LASER = { category = "laser", damage = 60, delay = 1.5, rear = false },
    BALLISTIC = { category = "ballistic", damage = 60, delay = 1.5, rear = false },
    PLASMA = { category = "plasma", damage = 60, delay = 1.5, rear = false },
    REAR_MISSILE = { category = "missile", damage = 60, delay = 1.5, rear = true },
}
function Systems.Create(model, config, profileId)
    return { model = model, config = config, energy = Energy.New(config), shield = Shield.New(config.shield),
        profile = Profiles.New(profileId), clock = 0, weaponRate = 0, sprintLimitedUntil = -1, weaponLimitedUntil = -1,
        publishAt = -1, published = {}, propulsion = 0, sprintFraction = 0, weaponUntil = 0,
        pending = nil, lastTest = -100, testReport = "H: scheduled impact / J: category / K: weapon load SIM" }
end
function Systems.Publish(p, force)
    if not p.model or not p.model.Parent then return end
    local now = os.clock()
    if not force and now - p.publishAt < 0.1 then return end
    p.publishAt = now
    local e, s = p.energy, p.shield
    local function rounded(n) return math.floor(n * 10 + 0.5) / 10 end
    local values = {
        EnergyCharge = rounded(e.charge), EnergyCapacity = p.config.capacity,
        EnergyOutput = rounded(e.output), EnergyDemand = rounded(e.demand), EnergySupply = rounded(e.reactorSupply),
        EnergyCapRate = rounded(e.capacitorRate), EnergyThermal = rounded(e.thermal), EnergyDeficit = rounded(e.deficit),
        EnergyPropulsion = rounded(p.propulsion), EnergyWeaponDemand = rounded(e.delivered.weapons or 0),
        SprintFraction = rounded(p.sprintFraction), ShieldState = s.state, ShieldCooldown = rounded(Shield.Cooldown(s)),
        ShieldIntegrity = rounded(s.integrity), ShieldReason = s.reason, ShieldSerial = s.serial,
        ShieldChargeTime = p.config.shield.chargeTime, ShieldRecoveryTime = p.config.shield.recoveryTime,
        ShieldImpactSerial = s.impactSerial, ShieldPhase = rounded(math.clamp((s.time - s.phaseStart) / math.max(s.phaseEnd - s.phaseStart, 0.001), 0, 1)),
        EnergyProfile = p.profile.active, EnergyProfilePending = p.profile.pending or "", EnergyProfileEta = rounded(Profiles.Remaining(p.profile, p.clock)),
        EnergyProfileSerial = p.profile.serial, EnergyProfileReason = p.profile.reason, EnergyFocus = Profiles.Policy(p.profile).focus,
        EnergyLimited = Systems.Limited(p), EnergyWeaponRate = rounded(p.weaponRate), EnergyShieldDemand = rounded(e.delivered.shield or 0),
        EnergySprintDemand = rounded(e.delivered.sprint or 0), EnergySprintReserve = rounded(Energy.Reserve(e, "sprint")),
        EnergyWeaponReserve = rounded(Energy.Reserve(e, "weapons")),
        EnergyTestReport = p.testReport, EnergyTestPending = p.pending ~= nil,
        EnergyTestETA = p.pending and rounded(math.max(0, p.pending.at - s.time)) or 0,
    }
    if s.lastResult then
        local r = s.lastResult
        values.ShieldLastPrevented, values.ShieldLastPenetrating = rounded(r.prevented), rounded(r.penetrating)
        values.ShieldLastEnergy, values.ShieldLastTiming = rounded(r.energy), r.timing
        values.ShieldLastCategory = r.category
    end
    for key, value in pairs(values) do
        if p.published[key] ~= value then p.model:SetAttribute(key, value); p.published[key] = value end
    end
end
-- Which discretionary subsystem the active profile is currently holding back ("" when nothing is limited).
function Systems.Limited(p)
    local parts = {}
    if p.clock < p.sprintLimitedUntil then table.insert(parts, "SPRINT") end
    if p.clock < p.weaponLimitedUntil then table.insert(parts, "WEAPONS") end
    if p.shield.reason == "CAPACITOR LOW" then table.insert(parts, "SHIELD") end
    return table.concat(parts, "+")
end
-- Called by the weapon controller when a funded-looking shot is refused (reserve or empty capacitor).
function Systems.NoteWeaponLimited(p)
    p.weaponLimitedUntil = p.clock + 0.6
end
-- Server-authoritative profile change: valid id, ACTIVE deployment, transition delay and minimum interval enforced.
function Systems.RequestProfile(p, id)
    if p.model:GetAttribute("Deployment") ~= "ACTIVE" then
        p.profile.reason = "DEPLOY FIRST"
        Systems.Publish(p, true)
        return false, "DEPLOY FIRST"
    end
    local ok, reason = Profiles.Request(p.profile, id, p.clock)
    Systems.Publish(p, true)
    return ok, reason
end
-- Every sortie starts from the default policy; thermal state, charge and shield timers are untouched.
function Systems.ResetProfile(p)
    p.profile = Profiles.New()
    p.sprintLimitedUntil, p.weaponLimitedUntil = -1, -1
    Systems.Publish(p, true)
end
function Systems.Activate(p, enabled)
    local ok = Shield.Activate(p.shield, p.config.shield, function(cost) return Energy.Spend(p.energy, cost, "shield") end, enabled)
    Systems.Publish(p, true)
    return ok, p.shield.reason
end
function Systems.Cancel(p)
    Shield.Cancel(p.shield, p.config.shield)
    Profiles.Cancel(p.profile)
    p.pending, p.weaponUntil, p.sprintFraction = nil, 0, 0
    Systems.Publish(p, true)
end

-- Future server weapons submit a continuous rate before the next locomotion step. Ledger priorities are order-independent.
function Systems.RequestPower(p, category, rate)
    if p.model:GetAttribute("Deployment") ~= "ACTIVE" then return false end
    return Energy.Request(p.energy, category, rate)
end

-- Trusted server interface for future weapons: nominal damage remains diagnostic until physical damage is implemented.
function Systems.ResolveImpact(p, attack, yaw)
    local result, reason = Shield.Resolve(p.shield, p.config.shield, attack, yaw, function(cost)
        return Energy.Consume(p.energy, cost, true)
    end)
    if result then
        p.testReport = string.format("%s %s | BLOCK %.1f / PASS %.1f | COST %.1f | INTEGRITY %.1f",
            string.upper(result.category), result.timing, result.prevented, result.penetrating, result.energy, result.integrity)
        Systems.Publish(p, true)
    end
    return result, reason
end
function Systems.RequestTest(p, patternId, yaw, position)
    if p.shield.time - p.lastTest < 2.5 or p.pending then return false end
    if type(patternId) ~= "string" then return false end
    if patternId ~= "WEAPON_LOAD" and not Systems.TestPatterns[patternId] then return false end
    -- Controlled test equipment is available only on the outdoor proving ground.
    if position.Z < 70 or position.Z > 320 then p.testReport = "TEST RANGE: exit the hangar first"; Systems.Publish(p, true); return false end
    p.lastTest = p.shield.time
    if patternId == "WEAPON_LOAD" then
        p.weaponUntil = p.shield.time + p.config.weaponTestDuration
        p.testReport = "WEAPON LOAD SIM: 100 u/s for 2s (no projectile / health damage)"
    else
        local spec = Systems.TestPatterns[patternId]
        local sign = if spec.rear then -1 else 1
        p.pending = { at = p.shield.time + spec.delay, attack = {
            category = spec.category, damage = spec.damage, fromX = -math.sin(yaw) * sign, fromZ = -math.cos(yaw) * sign,
        } }
        p.testReport = string.format("%s %s IMPACT IN 1.5s | press G near 1.2s for PERFECT", patternId, if spec.rear then "REAR" else "FRONT")
    end
    Systems.Publish(p, true)
    return true
end

-- Called at the same bounded substep as locomotion. Request order is priority: idle, basic drive, shield, weapons, sprint.
function Systems.Step(p, dt, drive, throttle, steer, sprint, enabled)
    local e, s, cfg = p.energy, p.shield, p.config
    p.clock += math.clamp(dt, 0, 0.25)
    if Profiles.Update(p.profile, p.clock) then Systems.Publish(p, true) end
    Energy.SetPolicy(e, Profiles.Policy(p.profile))
    Shield.Advance(s, cfg.shield, dt, enabled)
    local propulsion, boost = 0, 0
    if enabled then
        Energy.Request(e, "idle", cfg.movement.idle)
        if drive then propulsion, boost = Energy.MovementDemand(cfg, drive, throttle, steer, sprint) end
        Energy.Request(e, "propulsion", propulsion)
        if Shield.Protects(s) then Energy.Request(e, "shield", cfg.shield.activeDrain) end
        if s.time < p.weaponUntil then Energy.Request(e, "weapons", cfg.weaponTestRate) end
        Energy.Request(e, "sprint", boost)
    else p.pending, p.weaponUntil = nil, 0 end
    Energy.Advance(e, dt, enabled)
    if s.state == "READY" and enabled then
        s.reason = if math.min(e.charge,e.tokens) < cfg.shield.activationCost then "CAPACITOR LOW" else "READY"
    end
    if Shield.Protects(s) and (e.delivered.shield or 0) + 1e-6 < cfg.shield.activeDrain then
        s.reason = "SUSTAIN ENERGY LOW"
        Shield.Cancel(s, cfg.shield)
    end
    if p.pending and s.time >= p.pending.at then
        local attack = p.pending.attack
        p.pending = nil
        Systems.ResolveImpact(p, attack, drive and drive.yaw or 0)
    end
    local base, fraction = Energy.Performance(e, propulsion, boost)
    p.propulsion, p.sprintFraction = propulsion + boost, fraction
    if boost > 0 and fraction < 0.95 then p.sprintLimitedUntil = p.clock + 0.4 end
    -- Discrete weapon payments appear as a smoothed rate so the HUD can show weapon demand next to continuous loads.
    local spent = e.spent.weapons or 0
    e.spent.weapons = 0
    if dt > 0 then p.weaponRate += (spent / dt - p.weaponRate) * (1 - math.exp(-dt / 0.35)) end
    Systems.Publish(p)
    return base, fraction
end
return Systems
