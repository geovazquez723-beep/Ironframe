-- M10C Studio checks. Not run by tools/check.sh: each stage is pasted into the Studio MCP `execute_luau` of a Play session on
-- build/Ironframe-M10C.rbxl (stages marked [Server] with datamodel Server, [Client] with Client).
--
-- Setup (real input): wait ~6 s after Play starts, then press F, F (enter the cockpit, deploy) through user_keyboard_input.
-- Hotkeys under test: M = MECH TRIAL (the Range panel button does the same), N = ACTIVE TRAINING (unchanged), B = reset all.
-- All test equipment goes through the server-only `ServerScriptService.IronframeRangeAudit` bindable (unreachable from clients):
--   "rook" audit | "mode" PASSIVE|ACTIVE|MECH | "reset" ALL|MECH|VEHICLES|STRUCTURES | "teleport" Vector3, yaw | "repair"
--   "rookhit" region, weaponId, shots   -> the shot goes CombatTargets.Hit -> Destructibles.Hit -> shield -> armour -> region
--   "rookwreck" region, damage          -> penetrating damage straight to a region (component / terminal tests)
--   "rookteleport" x, z, yaw | "rookdrain" charge | "hit" region, damage (the PLAYER's Bastion) | "combat" | "session" | "mech"

--[[ [Server] 1. Acquire, approach through the cover chicane, fire (real AI, real locomotion) ]]
local function stage1()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("teleport", Vector3.new(0, 0.5, 440), math.pi)
    a:Invoke("mode", "MECH")
    local log = {}
    for i = 1, 24 do
        task.wait(1)
        local r = a:Invoke("rook")
        table.insert(log, string.format("t%d %s/%s pos=(%.0f,%.0f) spd=%.1f charge=%.0f profile=%s atk=%s wp=%s stuck=%d", i, r.state, r.reason,
            r.position.X, r.position.Z, r.speed, r.charge, r.profile, r.attack and (r.attack.id .. ":" .. r.attack.phase) or "-", r.wp, r.stuckCount))
    end
    return table.concat(log, "\n")
end

--[[ [Server] 2. Cover blocks fire: ROOK north of cover A, the player south of it (x = -13 avoids the panel seam at x = -11) ]]
local function stage2()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("mode", "MECH")
    task.wait(3.5)
    a:Invoke("rookteleport", -13, 556, 0)
    a:Invoke("teleport", Vector3.new(-13, 0.5, 520), math.pi)
    local r0 = a:Invoke("rook")
    task.wait(5)
    local r = a:Invoke("rook")
    return "rounds fired behind cover: " .. (r.counters.rounds - r0.counters.rounds) .. " (expected 0)"
end

--[[ [Server] 3. Shield mitigation of ROOK's laser: press the real shield at (first pulse arrival - 0.275 s) ]]
local function stage3()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("teleport", Vector3.new(0, 0.5, 520), math.pi)
    a:Invoke("mode", "MECH")
    task.wait(4)
    local rook = workspace.IronframeMechs["ROOK-01"]
    local c0 = a:Invoke("combat").stats
    local armedFor, t0 = nil, os.clock()
    while os.clock() - t0 < 40 do
        task.wait(0.03)
        if rook:GetAttribute("AiAttack") == "LR" and rook:GetAttribute("AiPhase") == "CHARGE" and not armedFor then
            local dist = (rook.Chassis.Position - Vector3.new(0, 0, 520)).Magnitude
            armedFor = rook:GetAttribute("AiAimAt") + rook:GetAttribute("AiWarn") + dist / 520 - 0.275
        end
        if armedFor and workspace:GetServerTimeNow() >= armedFor then
            a:Invoke("shield")
            armedFor = nil
        end
    end
    local c1 = a:Invoke("combat").stats
    return string.format("hits %d perfect %d guard %d unguarded %d prevented %.0f", c1.mechHits - c0.mechHits, c1.perfect - c0.perfect, c1.guard - c0.guard, c1.unguarded - c0.unguarded, c1.prevented - c0.prevented)
end

--[[ [Server] 4. Components through the real hit path: weapon assembly, legs, reactor, then core (terminal) ]]
local function stage4()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("reset", "MECH")
    task.wait(2.5)
    local function snap(tag)
        local r = a:Invoke("rook")
        return string.format("%s | core=%.0f armL=%.0f legR=%.0f reactor=%.0f speedF=%.2f reactorF=%.2f sockets=%s", tag, r.regions.CORE, r.regions.ARM_L, r.regions.LEG_R, r.regions.REACTOR, r.speedFactor, r.reactorFactor, table.concat(r.sockets, ","))
    end
    local out = { snap("fresh") }
    a:Invoke("rookhit", "ARM_L", "W_LASER_RIFLE", 14)
    table.insert(out, snap("laser x14 ARM_L"))
    a:Invoke("rookhit", "LEG_R", "W_LASER_RIFLE", 16)
    table.insert(out, snap("laser x16 LEG_R"))
    a:Invoke("rookhit", "REACTOR", "W_LASER_RIFLE", 22)
    table.insert(out, snap("laser x22 REACTOR"))
    a:Invoke("teleport", Vector3.new(0, 0.5, 520), math.pi)
    a:Invoke("mode", "MECH")
    task.wait(5)
    for i = 1, 60 do
        a:Invoke("rookhit", "CORE", "W_LASER_RIFLE", 1)
        if a:Invoke("rook").down then
            table.insert(out, "core failed after " .. i .. " hits")
            break
        end
    end
    task.wait(8)
    local r = a:Invoke("rook")
    table.insert(out, string.format("terminal: state=%s status=%s locked=%s rounds=%d (no further rounds) projectiles=%d", r.state, r.status, tostring(r.locked), r.counters.rounds, a:Invoke("combat").projectiles))
    return table.concat(out, "\n")
end

--[[ [Server] 5. Movement penalty and reactor output on a LIVE ROOK (damage applied after the trial starts; a trial start rebuilds ROOK) ]]
local function stage5()
    local a = game.ServerScriptService.IronframeRangeAudit
    local function run(tag, setup)
        a:Invoke("mode", "PASSIVE"); task.wait(0.6)
        a:Invoke("reset", "MECH"); task.wait(2.5)
        a:Invoke("teleport", Vector3.new(0, 0.5, 440), math.pi)
        a:Invoke("mode", "MECH"); task.wait(0.3)
        if setup then setup() end
        local top, out = 0, 0
        for _ = 1, 160 do
            task.wait(0.1)
            local r = a:Invoke("rook")
            top = math.max(top, r.speed)
            if r.live then out = math.max(out, r.output) end
        end
        return string.format("%s: top speed %.1f, reactor output %.0f", tag, top, out)
    end
    return table.concat({
        run("healthy"),
        run("legs destroyed", function() a:Invoke("rookwreck", "LEG_L", 400); a:Invoke("rookwreck", "LEG_R", 400) end),
        run("reactor destroyed", function() a:Invoke("rookwreck", "REACTOR", 400) end),
    }, "\n")
end

--[[ [Server] 6. Player core failure while ROOK is shooting: safe ejection, bolts cancelled, capsule untargetable, ROOK stands down ]]
local function stage6()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("repair")
    a:Invoke("teleport", Vector3.new(0, 0.5, 520), math.pi)
    a:Invoke("mode", "MECH")
    task.wait(6)
    a:Invoke("hit", "CORE", 5000)
    local out = {}
    for i = 1, 8 do
        task.wait(0.6)
        local s, c = a:Invoke("session"), a:Invoke("combat")
        local cap = workspace:FindFirstChild("InvulnerableEscapeCapsule")
        table.insert(out, string.format("%s %s mode=%s projectiles=%d rook=%s rounds=%d capsule=%s targetable=%s", s.machineState, s.deployment, c.mode, c.projectiles, c.rook.status, c.rook.counters.rounds, tostring(cap ~= nil), cap and tostring(cap:GetAttribute("Targetable")) or "-"))
    end
    return table.concat(out, "\n")
end

--[[ [Server] 7. Mode matrix: PASSIVE holds fire, ACTIVE arms the tanks only, MECH arms ROOK only ]]
local function stage7()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("repair"); a:Invoke("mode", "PASSIVE"); task.wait(0.6); a:Invoke("reset", "ALL"); task.wait(3)
    a:Invoke("teleport", Vector3.new(0, 0.5, 430), math.pi)
    local out = {}
    local function note(tag)
        local c = a:Invoke("combat")
        table.insert(out, string.format("%s: mode=%s tanks=%s,%s,%s rook=%s/%s shots=%d", tag, c.mode, c.tanks[1].state, c.tanks[2].state, c.tanks[3].state, c.rook.state, c.rook.status, c.stats.shots))
    end
    task.wait(4); note("PASSIVE")
    a:Invoke("mode", "ACTIVE"); task.wait(14); note("ACTIVE")
    a:Invoke("mode", "MECH"); task.wait(5); note("MECH")
    a:Invoke("mode", "PASSIVE"); task.wait(1); note("PASSIVE again")
    return table.concat(out, "\n")
end

--[[ [Server] 8. Cleanup over repeated trials: instance counts must return to baseline after every reset ]]
local function stage8()
    local a = game.ServerScriptService.IronframeRangeAudit
    local function counts()
        local au, r = a:Invoke("audit"), a:Invoke("rook")
        return string.format("district=%d indexed=%d rook=%d mechsFolder=%d workspace=%d", au.instances, au.totalIndexed, r.instances, #workspace.IronframeMechs:GetDescendants(), #workspace:GetDescendants())
    end
    local out = { "baseline: " .. counts() }
    a:Invoke("teleport", Vector3.new(0, 0.5, 520), math.pi)
    for i = 1, 6 do
        a:Invoke("mode", "PASSIVE"); task.wait(0.5); a:Invoke("reset", "MECH"); task.wait(2.2); a:Invoke("mode", "MECH"); task.wait(5)
        for _ = 1, 40 do a:Invoke("rookhit", "CORE", "W_LASER_RIFLE", 1); if a:Invoke("rook").down then break end end
        task.wait(1)
        table.insert(out, "cycle " .. i .. ": " .. counts())
    end
    return table.concat(out, "\n")
end

--[[ [Client] 9. Weapon-to-enemy through the REAL client weapon path (client aims the left-arm LR-12 at ROOK's chassis) ]]
local function stage9()
    local ctrl = game.Players.LocalPlayer.PlayerScripts.IronframeWeaponControl
    ctrl:Invoke("select", 1)
    local t0 = os.clock()
    while os.clock() - t0 < 24 do
        local p = workspace.IronframeMechs["ROOK-01"].Chassis.Position
        ctrl:Invoke("fire", true, Vector3.new(p.X, 9, p.Z))
        task.wait(0.1)
    end
    ctrl:Invoke("fire", false, nil)
end

--[[ [Client] 10. Dodge run through the real drive input (the client sends DriveInput at ~12 Hz; server SetInput would be overwritten) ]]
local function stage10()
    local ctrl = game.Players.LocalPlayer.PlayerScripts.IronframeDeploymentControl
    shared.dodge = true
    task.spawn(function()
        local t0 = os.clock()
        while shared.dodge do
            local t = os.clock() - t0
            ctrl:Invoke("input", if math.floor(t / 4) % 2 == 0 then 0.6 else -0.5, if math.floor(t / 1.2) % 2 == 0 then 0.7 else -0.7, false)
            task.wait(0.08)
        end
        ctrl:Invoke("input", 0, 0, false)
    end)
end

return { stage1, stage2, stage3, stage4, stage5, stage6, stage7, stage8, stage9, stage10 }
