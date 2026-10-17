-- Offline (Luau CLI) tests for the pure locomotion modules.
-- Run: luau tools/offline_tests.luau      (tools/check.sh does this automatically)
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local Drive = require("../src/ReplicatedStorage/IronframeShared/MechDrive")
local Gait = require("../src/ReplicatedStorage/IronframeShared/MechGait")
local DriveP = Chassis.IF42_BASTION.locomotion
local GaitP = Chassis.IF42_BASTION.gait

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= tol, string.format("%s: %.4f vs %.4f (tol %.4f)", what or "value", a, b, tol)) end

local function run(state, input, seconds, dt, probe)
    local t, last = 0, state.speed
    local maxJump, peak = 0, 0
    while t < seconds - 1e-9 do
        Drive.Advance(state, input, dt, DriveP, probe)
        maxJump = math.max(maxJump, math.abs(state.speed - last))
        last = state.speed
        peak = math.max(peak, math.abs(state.speed))
        t += dt
    end
    return maxJump, peak
end

print("MechDrive")
test("starts stationary and stable at idle", function()
    local s = Drive.New(0, 0, 0, 0)
    run(s, { throttle = 0, steer = 0 }, 5, 1 / 60)
    assert(s.speed == 0 and s.x == 0 and s.z == 0 and s.yaw == 0)
    assert(Drive.Classify(s, DriveP) == "IDLE")
end)
test("forward: gradual acceleration reaches ~95% in 2-3.2 s, never exceeds max", function()
    local s = Drive.New(0, 0, 0, 0)
    local t, t95, prev = 0, nil, 0
    while t < 6 do
        Drive.Advance(s, { throttle = 1, steer = 0 }, 1 / 60, DriveP)
        t += 1 / 60
        assert(s.speed >= prev - 1e-9, "speed must rise monotonically")
        prev = s.speed
        assert(s.speed <= DriveP.maxForward + 1e-6)
        if not t95 and s.speed >= 0.95 * DriveP.maxForward then t95 = t end
    end
    assert(t95 and t95 >= 2.0 and t95 <= 3.2, "t95 = " .. tostring(t95))
    near(s.speed, DriveP.maxForward, 0.05, "top speed")
    assert(s.z < 0, "forward moves toward -Z at yaw 0")
end)
test("acceleration is jerk-limited (no step change in acceleration)", function()
    local s = Drive.New(0, 0, 0, 0)
    local dt, lastAccel, worst = 1 / 60, 0, 0
    for _ = 1, 240 do
        Drive.Advance(s, { throttle = 1, steer = 0 }, dt, DriveP)
        worst = math.max(worst, math.abs(s.accel - lastAccel) / dt)
        lastAccel = s.accel
    end
    assert(worst <= DriveP.jerk + 1e-6, "jerk " .. worst)
end)
test("reverse is slower than forward and capped", function()
    local s = Drive.New(0, 0, 0, 0)
    local _, peak = run(s, { throttle = -1, steer = 0 }, 8, 1 / 60)
    near(peak, DriveP.maxReverse, 0.05, "reverse top speed")
    assert(DriveP.maxReverse < DriveP.maxForward * 0.5)
    assert(s.z > 0, "reverse moves toward +Z at yaw 0")
end)
test("braking and coasting take noticeable time; reverse input brakes harder than coasting", function()
    local function stopTime(input)
        local s = Drive.New(0, 0, 0, 0)
        run(s, { throttle = 1, steer = 0 }, 4, 1 / 60)
        local t = 0
        while s.speed > 0.1 and t < 10 do Drive.Advance(s, input, 1 / 60, DriveP); t += 1 / 60 end
        return t
    end
    local coast = stopTime({ throttle = 0, steer = 0 })
    local brake = stopTime({ throttle = -1, steer = 0 })
    assert(coast > 1.2 and coast < 5, "coast stop " .. coast)
    assert(brake > 0.8 and brake < coast, "brake " .. brake .. " vs coast " .. coast)
end)
test("no instant direction reversal: speed is continuous through W -> S", function()
    local s = Drive.New(0, 0, 0, 0)
    run(s, { throttle = 1, steer = 0 }, 4, 1 / 60)
    local dt = 1 / 60
    local jump, signChangeT, t = 0, nil, 0
    local last = s.speed
    while t < 6 do
        Drive.Advance(s, { throttle = -1, steer = 0 }, dt, DriveP)
        jump = math.max(jump, math.abs(s.speed - last))
        if not signChangeT and s.speed < 0 then signChangeT = t end
        last = s.speed; t += dt
    end
    assert(jump <= DriveP.brakeDecel * dt * 1.01, "speed jump " .. jump)
    assert(signChangeT and signChangeT > 0.8, "reversed too quickly: " .. tostring(signChangeT))
end)
test("steering: ~35 deg/s, gradual build-up, rotates in place, left = positive yaw", function()
    local s = Drive.New(0, 0, 0, 0)
    local dt, first = 1 / 60, nil
    for i = 1, 60 do
        Drive.Advance(s, { throttle = 0, steer = 1 }, dt, DriveP)
        if i == 6 then first = s.yawRate end
    end
    assert(first < DriveP.turnRate * 0.6, "turn rate should build up, not snap")
    near(math.deg(s.yawRate), 35, 0.5, "turn rate deg/s")
    assert(s.x == 0 and s.z == 0, "in-place turn does not translate")
    assert(s.yaw > 0)
    run(s, { throttle = 0, steer = 0 }, 2, dt)
    assert(s.yawRate == 0)
end)
test("turn rate falls at speed but stays positive", function()
    local s = Drive.New(0, 0, 0, 0)
    run(s, { throttle = 1, steer = 0 }, 5, 1 / 60)
    run(s, { throttle = 1, steer = -1 }, 2, 1 / 60)
    local rate = math.deg(math.abs(s.yawRate))
    assert(rate > 20 and rate < 35, "rate at speed " .. rate)
end)
test("frame-rate independence (15/30/60/144 Hz agree within ~half a stud; 15 Hz within 1)", function()
    local finals = {}
    for _, hz in ipairs({ 15, 30, 60, 144 }) do
        local s = Drive.New(0, 0, 0, 0)
        local dt = 1 / hz
        for i = 0, hz * 12 - 1 do
            local t = i / hz
            local input = if t < 4 then { throttle = 1, steer = 0 } elseif t < 7 then { throttle = 1, steer = 1 } elseif t < 9 then { throttle = 0, steer = 0 } else { throttle = -1, steer = -1 }
            Drive.Advance(s, input, dt, DriveP)
        end
        finals[hz] = s
    end
    for _, hz in ipairs({ 15, 30, 144 }) do
        local a, b = finals[hz], finals[60]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
        assert(d < (if hz == 15 then 1.0 else 0.5), hz .. " Hz drifted " .. d)
        near(a.yaw, b.yaw, 0.02, hz .. " Hz yaw")
    end
end)
test("a huge frame hitch cannot launch the machine", function()
    local s = Drive.New(0, 0, 0, 0)
    Drive.Advance(s, { throttle = 1, steer = 0 }, 30, DriveP) -- clamped to 0.25 s
    assert(math.abs(s.z) < 2, "moved " .. s.z)
end)
test("malformed client input is neutralised", function()
    for _, bad in ipairs({ "x", 0 / 0, math.huge, -math.huge, {}, true }) do
        local t, st = Drive.SanitizeInput(bad, bad)
        assert(t == 0 and st == 0)
    end
    local t, st = Drive.SanitizeInput(50, -50)
    assert(t == 1 and st == -1)
end)
test("locked input (ejection/deploying) brakes to a halt and ignores steering", function()
    local s = Drive.New(0, 0, 0, 0)
    run(s, { throttle = 1, steer = 0 }, 4, 1 / 60)
    run(s, { throttle = 1, steer = 1, locked = true }, 6, 1 / 60)
    assert(s.speed == 0 and s.yawRate == 0)
end)
test("walls stop the hull and report an impact; slide keeps the survivor speed", function()
    local probe = {
        move = function(x, y, z, yaw, dx, dz)
            if z + dz < -50 then return x, -50, 0.5, 0, 1 end -- wall at z = -50, normal +Z
            return x + dx, z + dz, 1, 0, 0
        end,
    }
    local s = Drive.New(0, 0, -40, 0)
    local bump = 0
    for _ = 1, 600 do
        local e = Drive.Advance(s, { throttle = 1, steer = 0 }, 1 / 60, DriveP, probe)
        bump = math.max(bump, e.bump or 0)
    end
    assert(s.z >= -50.0001, "passed through the wall: " .. s.z)
    assert(bump > DriveP.bumpSpeed)
    assert(s.speed < 1, "should have lost speed against the wall")
end)
test("blocked turns hold heading", function()
    local probe = { blocked = function() return true end }
    local s = Drive.New(0, 0, 0, 0)
    local e = Drive.Advance(s, { throttle = 0, steer = 1 }, 1, DriveP, probe)
    assert(s.yaw == 0 and e.turnBlocked)
end)
test("ground following: climbs rate-limited, tilt clamped", function()
    local probe = { ground = function() return 5, 1.0, -1.0 end }
    local s = Drive.New(0, 0, 0, 0)
    Drive.Advance(s, { throttle = 0, steer = 0 }, 0.1, DriveP, probe)
    assert(s.y <= DriveP.climbRate * 0.1 + 1e-6 and s.y > 0)
    run(s, { throttle = 0, steer = 0 }, 3, 1 / 60, probe)
    near(s.y, 5, 0.01, "settled height")
    assert(math.abs(s.pitch) <= DriveP.maxTilt + 1e-6 and math.abs(s.roll) <= DriveP.maxTilt + 1e-6)
end)
test("autopilot docks onto a pose and stops", function()
    local s = Drive.New(10, 0, 40, math.rad(200))
    local done, t = false, 0
    while not done and t < 90 do
        local th, st, arrived = Drive.Autopilot(s, 0, 0, 0)
        Drive.Advance(s, { throttle = th, steer = st }, 1 / 30, DriveP)
        done = arrived; t += 1 / 30
    end
    assert(done, "never docked")
    assert(math.sqrt(s.x ^ 2 + s.z ^ 2) < 4, "docked " .. s.x .. "," .. s.z)
end)

print("MechGait")
-- Joint ranges from RigSpec (rest +- limit), duplicated here because RigSpec needs Roblox types.
local RANGE = {
    Thigh = { math.rad(25 - 56), math.rad(25 + 56) },
    Knee = { math.rad(-50 - 62), math.rad(-50 + 62) },
    Ankle = { math.rad(25 - 68), math.rad(25 + 68) },
}
local function walk(seconds, speed, yawRate, dt)
    local g = Gait.New()
    local log = { events = {}, bothSwing = false }
    local odo, t = 0, 0
    local plantedStart = { L = nil, R = nil }
    local maxSlip = 0
    local ramp = 0
    while t < seconds do
        ramp = math.min(1, ramp + dt / 2) -- ease in so the first steps are realistic
        local v = speed * ramp
        local pose, events = Gait.Update(g, dt, v, yawRate * ramp, GaitP)
        odo += v * dt
        for _, e in ipairs(events) do table.insert(log.events, { t = t, leg = e.leg }) end
        if g.legs.L.state == "swing" and g.legs.R.state == "swing" then log.bothSwing = true end
        for side, leg in pairs(g.legs) do
            local world = odo + leg.f -- world position of the foot along the direction of travel (f is forward of the hip)
            if leg.state == "stance" then
                if plantedStart[side] == nil then plantedStart[side] = world end
                if yawRate == 0 then
                    maxSlip = math.max(maxSlip, math.abs(world - plantedStart[side]))
                end
            else
                plantedStart[side] = nil
            end
            for _, name in ipairs({ "Thigh", "Knee", "Ankle" }) do
                local a = pose.angles[name .. side]
                local r = RANGE[name]
                assert(a >= r[1] - 1e-6 and a <= r[2] + 1e-6, string.format("%s%s %.1f deg outside joint range", name, side, math.deg(a)))
            end
            local f = Gait.FootFromAngles(pose.angles["Thigh" .. side], pose.angles["Knee" .. side], GaitP.thighLength, GaitP.shinLength)
            assert(math.abs(f - leg.f) < 0.02, "IK does not reach the foot target")
        end
        t += dt
    end
    log.maxSlip, log.steps, log.g = maxSlip, #log.events, g
    return log
end
test("IK reaches targets across the full stride envelope within RigSpec limits", function()
    for f = -GaitP.reach, GaitP.reach, 0.2 do
        for lift = 0, GaitP.liftMax * (1 - (f / GaitP.reach) ^ 2), 0.25 do -- lift peaks mid-swing, never at the stride ends
            local th, kn, an = Gait.LegIK(f, GaitP.restFootDrop - GaitP.crouch - lift, GaitP.thighLength, GaitP.shinLength)
            assert(th >= RANGE.Thigh[1] and th <= RANGE.Thigh[2], string.format("thigh %.1f at f=%.1f lift=%.2f", math.deg(th), f, lift))
            assert(kn >= RANGE.Knee[1] and kn <= RANGE.Knee[2], string.format("knee %.1f at f=%.1f lift=%.2f", math.deg(kn), f, lift))
            assert(an >= RANGE.Ankle[1] and an <= RANGE.Ankle[2], string.format("ankle %.1f at f=%.1f lift=%.2f", math.deg(an), f, lift))
        end
    end
    local th, kn = Gait.LegIK(0, GaitP.restFootDrop, GaitP.thighLength, GaitP.shinLength)
    near(math.deg(th), 25, 1.0, "rest thigh matches the showroom stance")
    near(math.deg(kn), -50, 2.0, "rest knee matches the showroom stance")
end)
test("walking: planted feet do not slide, feet alternate, both never airborne", function()
    for _, dt in ipairs({ 1 / 30, 1 / 60, 1 / 144 }) do
        local log = walk(14, 16, 0, dt)
        assert(log.maxSlip < 0.03, string.format("foot slid %.3f studs at dt=%.4f", log.maxSlip, dt))
        assert(not log.bothSwing, "both feet airborne")
        local alternating = true
        for i = 2, #log.events do
            if log.events[i].leg == log.events[i - 1].leg then alternating = false end
        end
        assert(alternating, "footfalls must alternate L/R")
        assert(log.steps >= 18, "too few footfalls: " .. log.steps)
    end
end)
test("full-speed cadence is heavy: 1.8-2.8 footfalls per second", function()
    local log = walk(16, 16, 0, 1 / 60)
    local n, first, last = 0, nil, nil
    for _, e in ipairs(log.events) do
        if e.t > 6 then n += 1; first = first or e.t; last = e.t end
    end
    local rate = (n - 1) / (last - first)
    assert(rate > 1.8 and rate < 2.8, "cadence " .. rate)
end)
test("reversing and creeping also hold their feet and alternate", function()
    for _, speed in ipairs({ -7, 3, 1 }) do
        local log = walk(12, speed, 0, 1 / 60)
        assert(log.maxSlip < 0.03, "slip " .. log.maxSlip .. " at speed " .. speed)
        assert(not log.bothSwing)
        assert(log.steps >= 3, "steps " .. log.steps .. " at speed " .. speed)
    end
end)
test("turning in place steps the feet (alternating, bounded reach)", function()
    local log = walk(12, 0, math.rad(35), 1 / 60)
    assert(log.steps >= 6, "steps " .. log.steps)
    assert(not log.bothSwing)
    assert(log.g.slip < 0.5, "reach clamp slip " .. log.g.slip)
end)
test("stopping recentres both feet", function()
    local g = Gait.New()
    for _ = 1, 600 do Gait.Update(g, 1 / 60, 16, 0, GaitP) end
    for _ = 1, 300 do Gait.Update(g, 1 / 60, 0, 0, GaitP) end
    assert(math.abs(g.legs.L.f) <= GaitP.settleDist + 1e-6 and math.abs(g.legs.R.f) <= GaitP.settleDist + 1e-6, string.format("feet %.2f %.2f", g.legs.L.f, g.legs.R.f))
    assert(g.legs.L.state == "stance" and g.legs.R.state == "stance")
    assert(math.abs(g.dip) < 0.01)
end)
test("idle is stable: no motion, no footsteps", function()
    local g = Gait.New()
    local steps = 0
    for _ = 1, 600 do
        local _, ev = Gait.Update(g, 1 / 60, 0, 0, GaitP)
        steps += #ev
    end
    assert(steps == 0 and g.legs.L.f == 0 and g.legs.R.f == 0)
end)
test("pose amplitudes stay small enough for the pilot camera", function()
    local g = Gait.New()
    local maxDip, maxTorso, maxRoll = 0, 0, 0
    for _ = 1, 1200 do
        local pose = Gait.Update(g, 1 / 60, 16, 0, GaitP)
        maxDip = math.max(maxDip, math.abs(pose.dip))
        maxTorso = math.max(maxTorso, math.abs(pose.torsoYaw))
        maxRoll = math.max(maxRoll, math.abs(pose.hipRoll))
    end
    assert(maxDip < 0.3 and maxTorso < math.rad(3) and maxRoll < math.rad(3), string.format("dip %.2f torso %.2f roll %.2f", maxDip, math.deg(maxTorso), math.deg(maxRoll)))
end)

local Deployment = require("../src/ServerScriptService/IronframeServer/Deployment")
local Ejection = require("../src/ServerScriptService/IronframeServer/EjectionSequence")
test("deployment permits exactly the documented transitions", function()
    local allowed = { STOWED = { DEPLOYING = true, EJECTED = true }, DEPLOYING = { ACTIVE = true, EJECTED = true, STOWED = true }, ACTIVE = { DOCKING = true, EJECTED = true }, DOCKING = { STOWED = true, EJECTED = true }, EJECTED = { STOWED = true } }
    for _, from in ipairs(Deployment.STATES) do
        for _, to in ipairs(Deployment.STATES) do
            assert(Deployment.CanTransition(from, to) == (allowed[from][to] == true), from .. " -> " .. to)
        end
    end
    assert(not Deployment.CanTransition("BAD", "ACTIVE"))
end)
test("deployment rejects unsafe, invalid and duplicate deploys", function()
    local s = { deployment = "STOWED", machineState = "OPERATIONAL", mech = {}, pilotSafe = true, loadout = { systems = { reactor = "core" } } }
    assert(Deployment.ValidateDeploy(s, { valid = true }))
    for _, key in ipairs({ "machineState", "mech", "pilotSafe", "loadout" }) do
        local previous = s[key]; s[key] = nil
        assert(not Deployment.ValidateDeploy(s, { valid = true }), key)
        s[key] = previous
    end
    assert(not Deployment.ValidateDeploy(s, { valid = false }))
    assert(Deployment.Transition(s, "DEPLOYING"))
    assert(not Deployment.ValidateDeploy(s, { valid = true }))
    assert(not Deployment.AcceptsInput(s.deployment))
    assert(not Deployment.AllowsLoadoutChange(s.deployment))
    assert(Deployment.Transition(s, "ACTIVE") and Deployment.AcceptsInput(s.deployment))
    assert(Deployment.Transition(s, "DOCKING"))
    assert(Deployment.Transition(s, "STOWED") and Deployment.AllowsLoadoutChange(s.deployment))
end)
test("ejection survives failing movement and cleanup hooks and still rebuilds", function()
    for _, state in ipairs(Deployment.STATES) do
        local s = { deployment = state, pilotSafe = false }
        local queue, rebuilt = {}, false
        Ejection.Run(s, {
            onPilotSafe = function() assert(s.pilotSafe and not Ejection.IsPilotTargetable(s)); error("drive failure") end,
            onMechDisabled = function() assert(s.pilotSafe); error("animation failure") end,
            onCleanup = function() error("visual failure") end,
            onRebuild = function() rebuilt = true end,
            isStale = function() return false end,
        }, function(_, fn) table.insert(queue, fn) end)
        assert(s.pilotSafe and s.pilotTargetable == false and #queue == 2)
        for _, callback in ipairs(queue) do callback() end
        assert(rebuilt)
    end
end)
test("stale ejection never rebuilds a disconnected session", function()
    local rebuilt = false
    local s = {}
    Ejection.Run(s, { onPilotSafe = function() end, onMechDisabled = function() error("stale") end,
        onCleanup = function() end, onRebuild = function() rebuilt = true end, isStale = function() return true end }, function(_, fn) fn() end)
    assert(s.pilotSafe and not rebuilt)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("offline tests failed") end
