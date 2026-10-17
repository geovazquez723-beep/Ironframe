-- Pure authoritative energy ledger. Requests are rates for the NEXT Advance, in priority order.
-- Capacitor bursts and continuous consumers use the same charge and discharge token bucket.
local Energy = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function positive(v) return finite(v) and v >= 0 end
Energy.IsAmount = positive
Energy.Priority = { idle = 1, propulsion = 2, shield = 3, weapons = 4, sprint = 5 }

function Energy.New(config, charge)
    assert(positive(config.capacity) and positive(config.output) and config.chargeEfficiency > 0 and config.chargeEfficiency <= 1)
    assert(positive(config.maxDischargeRate) and positive(config.maxChargeRate) and positive(config.burstLimit))
    local initial = math.clamp(charge or config.initialCharge or config.capacity, 0, config.capacity)
    return { config = config, charge = initial, thermal = 0, tokens = config.burstLimit, requests = {},
        delivered = {}, demand = 0, served = 0, deficit = 0, output = 0, reactorSupply = 0,
        capacitorRate = 0, dischargeRate = 0, efficiency = config.chargeEfficiency,
        ledger = { initial = initial, generated = 0, consumed = 0, loss = 0, wasted = 0 }, lastBurst = 0 }
end

-- One request per key per frame; duplicate keys accumulate without creating another energy source.
function Energy.Request(s, key, rate)
    if type(key) ~= "string" or not positive(rate) then return false end
    for _, r in ipairs(s.requests) do
        if r.key == key then r.rate += rate; return true end
    end
    table.insert(s.requests, { key = key, rate = rate, priority = Energy.Priority[key] or 4 })
    return true
end

-- Discrete capacitor consumption. partial=true supports damage mitigation proportional to energy actually spent.
function Energy.Consume(s, amount, partial, thermalPerUnit)
    if not positive(amount) then return 0 end
    local available = math.min(s.charge, s.tokens)
    if not partial and available + 1e-8 < amount then return 0 end
    local used = math.min(amount, available)
    s.charge = math.max(0, s.charge - used)
    s.tokens = math.max(0, s.tokens - used)
    s.ledger.consumed += used
    s.lastBurst = used
    s.thermal = math.clamp(s.thermal + used * (thermalPerUnit or s.config.thermalPerDischarge), 0, s.config.thermalMaximum)
    return used
end
function Energy.Spend(s, amount)
    return positive(amount) and Energy.Consume(s, amount, false) == amount
end

function Energy.Advance(s, elapsed, online)
    local c = s.config
    if not positive(elapsed) then return false end
    local dt = math.min(elapsed, 0.25)
    local requests = s.requests
    s.requests = {}
    table.sort(requests, function(a,b)
        return if a.priority == b.priority then a.key < b.key else a.priority < b.priority
    end)
    if dt == 0 then return true end
    local count = math.max(1, math.ceil(dt * 120))
    local h = dt / count
    local total, demand, delivered, supply, charged, discharged = 0, 0, {}, 0, 0, 0
    for _, r in ipairs(requests) do demand += r.rate end
    for _ = 1, count do
        local strain = math.clamp((s.thermal - c.thermalThreshold) / (c.thermalMaximum - c.thermalThreshold), 0, 1)
        local output = if online then c.output * (1 - c.outputPenalty * strain) else 0
        local efficiency = c.chargeEfficiency * (1 - c.chargePenalty * strain)
        s.output, s.efficiency = output, efficiency
        s.tokens = math.min(c.burstLimit, s.tokens + c.maxDischargeRate * h)
        local reactor = output * h
        local capBudget = math.min(s.charge, s.tokens, c.maxDischargeRate * h)
        local consumed, usedCap = 0, 0
        s.ledger.generated += reactor
        for _, r in ipairs(requests) do
            local wanted = r.rate * h
            local fromReactor = math.min(reactor, wanted)
            reactor -= fromReactor
            local fromCap = math.min(capBudget, wanted - fromReactor)
            capBudget -= fromCap
            s.charge -= fromCap
            s.tokens -= fromCap
            usedCap += fromCap
            local used = fromReactor + fromCap
            delivered[r.key] = (delivered[r.key] or 0) + used
            consumed += used
        end
        -- Charge only from unused reactor output, never from the capacitor or another independently computed budget.
        local intoCharge = math.min(reactor, c.maxChargeRate * h, (c.capacity - s.charge) / efficiency)
        local stored = intoCharge * efficiency
        s.charge = math.clamp(s.charge + stored, 0, c.capacity)
        s.ledger.loss += intoCharge - stored
        s.ledger.wasted += reactor - intoCharge
        s.ledger.consumed += consumed
        supply += output * h - (reactor - intoCharge)
        total += consumed
        charged += stored
        discharged += usedCap
        local heat = consumed * c.thermalPerEnergy + usedCap * c.thermalPerDischarge
        local cooling = c.cooling / (1 + s.thermal / c.thermalMaximum)
        s.thermal = math.clamp(s.thermal + heat - cooling * h, 0, c.thermalMaximum)
    end
    s.demand, s.served, s.deficit = demand, total / dt, math.max(0, demand - total / dt)
    s.reactorSupply = supply / dt
    s.capacitorRate, s.dischargeRate = (charged - discharged) / dt, discharged / dt
    s.delivered = {}
    for key, amount in pairs(delivered) do s.delivered[key] = amount / dt end
    return true
end

function Energy.MovementDemand(config, drive, throttle, steer, sprint)
    local p = config.movement
    local fraction = math.min(math.abs(drive.speed) / config.referenceSpeed, config.movement.sprintMultiplier)
    local propulsion = math.abs(throttle) * p.drive + fraction * p.speed + math.abs(drive.accel) * p.acceleration
        + math.abs(steer) * p.turn + (if throttle == 0 then math.abs(drive.speed) * p.braking else 0)
    local boost = if sprint and throttle > 0 then p.sprintDemand else 0
    return propulsion, boost
end
function Energy.Performance(s, propulsion, sprint)
    local base = if propulsion > 0 then math.clamp((s.delivered.propulsion or 0) / propulsion, 0, 1) else 1
    local boost = if sprint > 0 then math.clamp((s.delivered.sprint or 0) / sprint, 0, 1) else 0
    -- A mechanically conservative limp mode remains available; starvation never locks or teleports the chassis.
    return 0.65 + 0.35 * base, boost
end
return Energy
