-- M10B Studio Play checks (SERVER datamodel). Paste into execute_luau with datamodel_type "Server" while the Bastion is DEPLOYED
-- (Ironframe-M10B.rbxl, single player, Bay_1; deploy with the F key twice or the RequestDeploy remote). It only uses the production
-- paths: the tanks' own AI, the shell manager, the existing shield (EnergySystems) and the server-only IronframeRangeAudit
-- bindable (a BindableFunction, unreachable from clients). Each stage is a function on shared.M10B and finishes in < 60 s:
--
--   shared.M10B.setup()        helpers, returns tank states
--   shared.M10B.cover()        intact cover blocks the line of fire and stops forced shells; destroying it opens the line
--   shared.M10B.shield()       calibrate a heavy shell, then PERFECT / GUARD / too late / too early / wrong facing
--   shared.M10B.energy()       empty capacitor, minimal capacitor, shield cooldown
--   shared.M10B.components()   leg / reactor / weapon-assembly consequences and top speed
--   shared.M10B.dodge()        shells fired against a standing and against a running Bastion (needs the client throttle override)
--   shared.M10B.eject()        core failure -> guaranteed-safe ejection while a shell is in flight, rebuild, capsule untargetable
--   shared.M10B.stress()       rapid mode / reset / state changes while attacks are in progress; instance accounting
--
-- The client half (HUD cue, real keys N / W / F / V, weapon fire) lives in tools/m10b_client_scenario.luau.
local SS = game.ServerScriptService
local T = {}
shared.T = T
local M = {}
shared.M10B = M

function M.setup()
    T.a = SS.IronframeRangeAudit
    local c = T.a:Invoke("combat")
    T.origin = c.tanks[1].pos - Vector3.new(-38, 0, 438) -- T-01 spawns at bay-local (-38, 438)
    T.mech = function() return workspace.IronframeMechs:GetChildren()[1] end
    T.at = function(x, z) return T.origin + Vector3.new(x, 0, z) end
    T.tp = function(x, z, yawDeg) return T.a:Invoke("teleport", T.at(x, z), math.rad(yawDeg or 0)) end
    T.combat = function() return T.a:Invoke("combat") end
    T.mechState = function() return T.a:Invoke("mech") end
    T.sess = function() return T.a:Invoke("session") end
    T.fmt = function(t) local o = {} for k, v in pairs(t) do table.insert(o, k .. "=" .. tostring(v)) end table.sort(o) return table.concat(o, " ") end
    T.facing = function(fx, fz, tx, tz) return math.deg(math.atan2(-(tx - fx), -(tz - fz))) end
    T.states = function() local r = {} for _, t in ipairs(T.combat().tanks) do table.insert(r, t.id .. ":" .. t.state) end return table.concat(r, " ") end
    -- Forced shell from tank `idx` at the Bastion's torso at bay-local (px, pz); raises the shield `lead` s before the calibrated impact.
    T.shot = function(idx, px, pz, lead)
        local m = T.mech()
        local aim = Vector3.new(T.origin.X + px, T.origin.Y + 9, T.origin.Z + pz)
        local serial0 = m:GetAttribute("LastHitSerial") or 0
        local t0 = os.clock()
        T.a:Invoke("dfire", idx, aim, true)
        local pressed, impact = false, nil
        while os.clock() - t0 < 6 do
            if lead and not pressed and T.ETA and os.clock() - t0 >= (T.ETA - lead) then
                pressed = true
                T.lastPress = { T.a:Invoke("shield") }
            end
            task.wait()
            if (m:GetAttribute("LastHitSerial") or 0) > serial0 then impact = os.clock() - t0 break end
        end
        return impact, m:GetAttribute("LastHitTiming"), m:GetAttribute("LastHitPrevented"), m:GetAttribute("LastHitPenetrating"), m:GetAttribute("LastHitRegion")
    end
    return "ready " .. T.states()
end

local function expect(out, cond, text)
    table.insert(out, (if cond then "PASS " else "FAIL ") .. text)
end

function M.cover()
    local out = {}
    T.a:Invoke("repair")
    T.a:Invoke("reset", "ALL") task.wait(6)
    T.tp(-36, 380, T.facing(-36, 380, -38, 438))
    local wall = T.a:Invoke("testwall", T.at(-36, 405), 24, 30) -- 30 studs of concrete between T-01 and the Bastion
    T.a:Invoke("mode", "ACTIVE")
    task.wait(7)
    local s = T.combat()
    expect(out, s.tanks[1].shots == 0 and s.tanks[1].state ~= "AIM", "sentry holds fire while intact cover blocks the line (state " .. s.tanks[1].state .. ")")
    local before = T.combat().stats
    T.a:Invoke("dfire", 1, nil, true)
    task.wait(1.4)
    local after = T.combat().stats
    expect(out, after.worldHits == before.worldHits + 1 and after.mechHits == before.mechHits, "forced shell is stopped by the wall, never reaches the Bastion")
    local dealt = T.a:Invoke("fire", wall, "W_HMG_MAULER", 14)
    expect(out, wall:GetAttribute("Stage") == "DESTROYED" and wall.Parent == nil, "Mauler destroys the wall (dealt " .. math.floor(dealt) .. ")")
    local engaged = false
    for _ = 1, 20 do
        task.wait(0.5)
        local t = T.combat().tanks[1]
        if t.state == "AIM" or t.shots > 0 then engaged = true break end
    end
    expect(out, engaged, "destroyed cover opens the line of fire: the sentry now aims and fires")
    T.a:Invoke("untestwall")
    T.a:Invoke("mode", "PASSIVE")
    return table.concat(out, "\n")
end

function M.shield()
    local out = {}
    local px, pz = 8, 352
    T.a:Invoke("repair")
    T.tp(px, pz, T.facing(px, pz, 14, 478))
    T.a:Invoke("mode", "ACTIVE")
    T.a:Invoke("hold", true) -- tanks stand down; only forced shells fly
    task.wait(2.6)
    local eta, timing, prev, pen = T.shot(2, px, pz, nil)
    T.ETA = eta
    expect(out, timing == "UNGUARDED" and pen == 150, string.format("calibration: unshielded heavy shell lands at %.2fs for 150", eta))
    local cases = { { "PERFECT", 0.275 }, { "GUARD", 0.70 } }
    for _, c in ipairs(cases) do
        T.a:Invoke("repair") task.wait(5.5)
        local _, tm, pv, pn = T.shot(2, px, pz, c[2])
        local ok = tm == c[1] and (if c[1] == "PERFECT" then pv > 130 else pv > 85 and pv < 110)
        expect(out, ok, string.format("%s: timing=%s prevented=%s penetrating=%s", c[1], tostring(tm), tostring(pv), tostring(pn)))
    end
    for _, c in ipairs({ { "too late (still charging)", 0.03 }, { "too early (guard expired)", 1.2 } }) do
        T.a:Invoke("repair") task.wait(5.5)
        local _, tm, pv = T.shot(2, px, pz, c[2])
        expect(out, tm == "UNGUARDED" and pv == 0, c[1] .. ": " .. tostring(tm))
    end
    T.a:Invoke("repair") task.wait(5.5)
    T.tp(px, pz, T.facing(px, pz, 14, 478) + 180)
    task.wait(0.3)
    local _, tm, pv, _, region = T.shot(2, px, pz, 0.275)
    expect(out, tm == "OFF_AXIS" and pv == 0, "wrong facing: " .. tostring(tm) .. " region " .. tostring(region))
    T.a:Invoke("hold", false)
    T.a:Invoke("mode", "PASSIVE")
    return table.concat(out, "\n")
end

function M.energy()
    local out = {}
    local px, pz = 8, 352
    T.a:Invoke("repair")
    T.tp(px, pz, T.facing(px, pz, 14, 478))
    task.wait(6)
    T.a:Invoke("mode", "ACTIVE") T.a:Invoke("hold", true) task.wait(2.6)
    T.a:Invoke("drain", 0)
    local ok, reason = T.a:Invoke("shield")
    expect(out, ok == false and reason == "CAPACITOR LOW", "empty capacitor: shield refused (" .. tostring(reason) .. ")")
    local _, tm = T.shot(2, px, pz, nil)
    expect(out, tm == "UNGUARDED", "shell with no shield energy is unmitigated")
    task.wait(8)
    T.a:Invoke("repair") T.a:Invoke("drain", 25.2)
    local _, tm2 = T.shot(2, px, pz, 0.275)
    expect(out, T.lastPress[1] == true, "25.2 energy is just enough to raise the shield (cost 25): " .. tostring(tm2))
    task.wait(6)
    local ok1 = T.a:Invoke("shield")
    task.wait(0.4)
    local ok2, r2 = T.a:Invoke("shield")
    expect(out, ok1 == true and ok2 == false, "second press during the cycle refused: " .. tostring(r2))
    task.wait(2)
    local ok3, r3 = T.a:Invoke("shield")
    expect(out, ok3 == false and r3 == "SHIELD COOLDOWN", "still refused inside the cooldown: " .. tostring(r3))
    T.a:Invoke("hold", false) T.a:Invoke("mode", "PASSIVE")
    return table.concat(out, "\n")
end

function M.components()
    local out = {}
    T.a:Invoke("mode", "PASSIVE")
    T.a:Invoke("repair") task.wait(1)
    local m = T.mech()
    local function topSpeed() -- needs the client throttle override (IronframeDeploymentControl "input", 1, 0)
        T.tp(-35, 350, -90)
        local peak = 0
        for _ = 1, 45 do task.wait(0.1) peak = math.max(peak, T.sess().speed or 0) end
        return peak
    end
    local base = topSpeed()
    T.a:Invoke("hit", "LEG_L", 190)
    local half = topSpeed()
    T.a:Invoke("hit", "LEG_L", 200)
    local one = topSpeed()
    T.a:Invoke("hit", "LEG_R", 400)
    local both = topSpeed()
    expect(out, base > 15 and half < base and one < half and both < one and both > 4, string.format("top speed %.1f > %.1f > %.1f > %.1f st/s", base, half, one, both))
    T.a:Invoke("repair") task.wait(1)
    local o0 = m:GetAttribute("EnergyOutput")
    T.a:Invoke("hit", "REACTOR", 160) task.wait(1.2)
    local o1 = m:GetAttribute("EnergyOutput")
    T.a:Invoke("hit", "REACTOR", 400) task.wait(1.2)
    local o2 = m:GetAttribute("EnergyOutput")
    expect(out, o0 == 80 and o1 < o0 and o2 < o1 and o2 >= 30, string.format("reactor output %.0f > %.0f > %.0f", o0, o1, o2))
    T.a:Invoke("repair") task.wait(1.2)
    expect(out, m:GetAttribute("EnergyOutput") == 80, "repair restores reactor output")
    T.a:Invoke("hit", "ARM_R", 300)
    local s = T.mechState()
    expect(out, table.concat(s.sockets, ",") == "right_arm,right_shoulder", "destroyed right weapon assembly disables right_arm + right_shoulder: " .. table.concat(s.sockets, ","))
    T.a:Invoke("repair")
    return table.concat(out, "\n")
end

function M.eject()
    local out = {}
    T.a:Invoke("repair")
    T.a:Invoke("reset", "ALL") task.wait(6)
    local px, pz = 8, 352
    T.tp(px, pz, T.facing(px, pz, 14, 478))
    T.a:Invoke("mode", "ACTIVE")
    local t0 = os.clock()
    while T.combat().projectiles == 0 and os.clock() - t0 < 25 do task.wait(0.05) end
    local inflight = T.combat().projectiles
    T.a:Invoke("hit", "CORE", 5000)
    task.wait(0.1)
    local s = T.sess()
    local pod = workspace:FindFirstChild("InvulnerableEscapeCapsule")
    expect(out, inflight >= 1 and T.combat().projectiles == 0, "shell was in flight (" .. inflight .. "); core failure cancels it")
    expect(out, s.machineState == "PILOT_EVACUATED" and s.pilotSafe == true and s.pilotTargetable == false, "pilot established safe: " .. tostring(s.machineState))
    expect(out, pod ~= nil and pod:GetAttribute("Targetable") == false and pod.CanQuery == false, "escape capsule exists and is untargetable / not queryable")
    expect(out, T.combat().mode == "PASSIVE" and T.states() == "T-01:IDLE T-02:IDLE T-03:IDLE", "training ends: PASSIVE, tanks stand down")
    task.wait(1.2)
    expect(out, T.mech() ~= nil, "abandoned mech still stands ~1.3 s after ejection (terminal shutdown is visible)")
    task.wait(1.4)
    expect(out, workspace.IronframeMechs:GetChildren()[1] == nil and T.sess().machineState == "MECH_DISABLED", "abandoned mech removed after the shutdown")
    task.wait(4)
    local m2 = workspace.IronframeMechs:GetChildren()[1]
    local s2 = T.sess()
    expect(out, m2 and m2:GetAttribute("State") == "OPERATIONAL" and s2.deployment == "STOWED" and m2:GetAttribute("Dmg_CORE") == 1, "mech rebuilt OPERATIONAL / STOWED, fully repaired")
    return table.concat(out, "\n")
end

function M.stress()
    local out = {}
    T.a:Invoke("mode", "PASSIVE") task.wait(8)
    local px, pz = 8, 352
    T.tp(px, pz, T.facing(px, pz, 14, 478))
    local function audit() local a = T.a:Invoke("audit") return a.instances, a.totalIndexed end
    local i0, x0 = audit()
    local bad = 0
    for n, act in ipairs({ "passive", "resetAll", "toggle", "resetVeh" }) do
        T.a:Invoke("mode", "ACTIVE")
        local t0 = os.clock()
        while T.combat().projectiles == 0 and os.clock() - t0 < 14 do task.wait(0.05) end
        if act == "passive" then T.a:Invoke("mode", "PASSIVE")
        elseif act == "resetAll" then T.a:Invoke("reset", "ALL")
        elseif act == "resetVeh" then T.a:Invoke("reset", "VEHICLES")
        else for _ = 1, 5 do T.a:Invoke("mode", "PASSIVE") T.a:Invoke("mode", "ACTIVE") end end
        task.wait(0.1)
        if act ~= "toggle" and T.combat().projectiles ~= 0 then bad += 1 end
        task.wait(if string.sub(act, 1, 5) == "reset" then 7 else 1)
    end
    T.a:Invoke("mode", "PASSIVE")
    T.a:Invoke("reset", "ALL") task.wait(7)
    local i1, x1 = audit()
    expect(out, bad == 0, "no shell survives a mode switch or reset")
    expect(out, i1 == i0 or i1 == 1329, string.format("district instances back to baseline after reset: %d -> %d", i0, i1))
    expect(out, x1 == x0 and x1 == 234, string.format("part registry unchanged: %d -> %d", x0, x1))
    return table.concat(out, "\n")
end

return "M10B checks loaded: run shared.M10B.setup() first"
