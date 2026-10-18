-- M11A Studio checks (not run by tools/check.sh). Paste each block into the Studio MCP `execute_luau` of a Play session on
-- build/Ironframe-M11A.rbxl (datamodel noted per block). Real input where the engineering UI is concerned: user_mouse_input with
-- instance paths LocalPlayer.PlayerGui.IronframeEngineeringUI.Panel.{Tab_weapons|Tab_reactor|Tab_actuators|Tab_armor, Slot_<socket>,
-- Option1..Option5, Install, Revert}. Everything else goes through the real remotes (RequestLoadout / RequestLoadoutRevert / SetPreset /
-- RequestDeploy / RequestReturn / DriveInput / WeaponIntent) and the server-only audit bindable (ServerScriptService.IronframeRangeAudit):
--   "build"  -> compiled label / stats / structure / weapons + what the DEPLOYED runtime actually uses (controller limits, energy config,
--               damage capacities, mounts, TopSpeed attribute) + the last sortie report
--   "mech" / "combat" / "session" / "rook" / "mode" / "reset" / "teleport" / "hit"  (M10B / M10C test equipment)
-- Deploy with the real keys: F, F (user_keyboard_input). The `shared` tables below persist per datamodel between calls.

--[[ [Client] helpers ]]
local function clientHelpers()
    local R = game.ReplicatedStorage.IronframeRemotes
    local ctrl = game.Players.LocalPlayer.PlayerScripts.IronframeDeploymentControl
    local wc = game.Players.LocalPlayer.PlayerScripts.IronframeWeaponControl
    shared.cfg = function(req) R.RequestLoadout:FireServer(req) end
    shared.preset = function(id) R.SetPreset:FireServer(id) end
    shared.revert = function() R.RequestLoadoutRevert:FireServer() end
    shared.deploy = function() R.RequestDeploy:FireServer() end
    shared.ret = function() R.RequestReturn:FireServer() end
    shared.th, shared.st, shared.sp = 0, 0, false
    task.spawn(function() while true do ctrl:Invoke("input", shared.th, shared.st, shared.sp) task.wait(0.08) end end) -- the client sends DriveInput ~12 Hz
    shared.setDrive = function(th, st, sp) shared.th, shared.st, shared.sp = th, st, sp end
    local function model() return workspace.IronframeMechs:FindFirstChild(tostring(game.Players.LocalPlayer.UserId)) end
    local function waitDep(d) for _ = 1, 300 do if model() and model():GetAttribute("Deployment") == d then return true end task.wait(0.2) end return false end
    -- dock (if deployed), optionally reset to a factory preset, apply a request, deploy: the full configure -> deploy loop
    shared.switch = function(preset, req)
        shared.setDrive(0, 0, false)
        if model():GetAttribute("Deployment") ~= "STOWED" then shared.ret() assert(waitDep("STOWED"), "no dock") end
        task.wait(0.5)
        if preset then shared.preset(preset) task.wait(1.3) end
        if req then shared.cfg(req) task.wait(1.3) end
        shared.deploy()
        assert(waitDep("ACTIVE"), "no active")
        return "ACTIVE"
    end
    shared.fire = function(on, idx, aimRook)
        shared.firing = on
        if on then task.spawn(function()
            while shared.firing do
                pcall(function()
                    local m, rk = model(), workspace.IronframeMechs:FindFirstChild("ROOK-01")
                    local p = (aimRook and rk and rk:FindFirstChild("Chassis")) and (rk.Chassis.Position + Vector3.new(0, -1.6, 0)) or (m.Chassis.Position + m.Chassis.CFrame.LookVector * 90)
                    wc:Invoke("select", idx or 1)
                    wc:Invoke("fire", true, p + Vector3.new(0, 9, 0))
                end)
                task.wait(0.1)
            end
            pcall(function() wc:Invoke("fire", false, nil) end)
        end) end
    end
end

--[[ [Server] helpers: wait for a state, measure a run, run a standard ROOK duel ]]
local function serverHelpers()
    local a = game.ServerScriptService.IronframeRangeAudit
    shared.waitFor = function(dep, t) for _ = 1, (t or 30) * 4 do if a:Invoke("session").deployment == dep then return true end task.wait(0.25) end return false end
    -- Full throttle on the proving ground: top speed, cruise propulsion demand, capacitor and thermal behaviour (client: setDrive(1, 0, false))
    shared.measure = function(label)
        assert(shared.waitFor("ACTIVE", 20))
        a:Invoke("teleport", Vector3.new(0, 0.5, 120), math.pi)
        task.wait(0.4)
        local model = workspace.IronframeMechs[tostring(game.Players:GetPlayers()[1].UserId)]
        local top, prop, n, minCharge, maxTherm, t0 = 0, 0, 0, 1e9, 0, os.clock()
        while os.clock() - t0 < 12 do
            task.wait(0.1)
            local s = a:Invoke("session")
            top = math.max(top, s.speed)
            if math.abs(s.speed) > top * 0.97 and os.clock() - t0 > 6 then prop += model:GetAttribute("EnergyPropulsion") or 0; n += 1 end
            minCharge, maxTherm = math.min(minCharge, model:GetAttribute("EnergyCharge") or 0), math.max(maxTherm, model:GetAttribute("EnergyThermal") or 0)
        end
        local b = a:Invoke("build")
        return string.format("%s | top %.1f (compiled %.1f) | cruise propulsion %.1f u/s | min charge %.0f/%.0f | peak thermal %.1f%% | output %.0f", label, top, b.stats.topSpeed, n > 0 and prop / n or 0, minCharge, b.runtime.capacity, maxTherm, b.runtime.output)
    end
    -- Held-fire energy test (client: shared.fire(true, slotIndex)): shots, capacitor floor, thermal peak, time the weapons were held back
    shared.fireTest = function(label, seconds)
        assert(shared.waitFor("ACTIVE", 20))
        a:Invoke("teleport", Vector3.new(0, 0.5, 120), math.pi)
        task.wait(0.6)
        local model = workspace.IronframeMechs[tostring(game.Players:GetPlayers()[1].UserId)]
        local shots0, minCharge, maxTherm, limited, t0 = model:GetAttribute("WeaponShots") or 0, 1e9, 0, 0, os.clock()
        while os.clock() - t0 < seconds do
            task.wait(0.1)
            minCharge, maxTherm = math.min(minCharge, model:GetAttribute("EnergyCharge") or 0), math.max(maxTherm, model:GetAttribute("EnergyThermal") or 0)
            if (model:GetAttribute("EnergyLimited") or "") ~= "" then limited += 0.1 end
        end
        local shots = (model:GetAttribute("WeaponShots") or 0) - shots0
        return string.format("%s | %d shots / %.0fs | min charge %.0f/%.0f | peak thermal %.1f%% | weapon-limited %.1fs | %s", label, shots, seconds, minCharge, a:Invoke("build").runtime.capacity, maxTherm, limited, tostring(model:GetAttribute("WeaponName")))
    end
    -- Standard ROOK duel: fresh ROOK, the player at (-6, 505) facing it; stops early when ROOK is down. Pair with client shared.fire / weaving.
    shared.duel = function(label, seconds)
        assert(shared.waitFor("ACTIVE", 25))
        a:Invoke("mode", "PASSIVE") task.wait(0.4)
        a:Invoke("reset", "MECH") task.wait(2.6)
        a:Invoke("teleport", Vector3.new(-6, 0.5, 505), math.pi)
        a:Invoke("mode", "MECH")
        local c0, t0 = a:Invoke("combat").stats, os.clock()
        while os.clock() - t0 < seconds do task.wait(0.5) if a:Invoke("rook").down then break end end
        local c1, m, r, b = a:Invoke("combat").stats, a:Invoke("mech"), a:Invoke("rook"), a:Invoke("build")
        return string.format("%s | %.0fs | ROOK rounds hit %d/%d | penetrating %.0f | player core %.0f/%d | ROOK core %.0f/700 down=%s", label, os.clock() - t0, c1.mechHits - c0.mechHits, c1.shots - c0.shots, c1.penetrating - c0.penetrating, m.regions.CORE, b.runtime.damageCapacity.CORE, r.regions.CORE, tostring(r.down))
    end
end

--[[ [Client] Hostile requests: none may change the build (the server compiles and validates every field) ]]
local function hostileRequests()
    local bad = {
        { systems = { reactor = "CORE_300" } }, { systems = { reactor = "CORE_260", powerOutput = 9999 } }, { stats = { speed = 99 } }, "string", 5,
        { mounts = { left_shoulder = "W_HMG_MAULER" } }, { mounts = { left_torso = "W_MACHINE_GUN" } }, { systems = { armor = {} } },
        { mounts = { left_arm = "W_MISSILE_POD" } }, { systems = { actuators = "ACT_MOBILITY" }, mounts = { right_arm = "W_NOPE" } },
        { systems = { reactor = string.rep("A", 5000) } }, { mounts = { [1] = "W_MACHINE_GUN" } },
    }
    for _, r in ipairs(bad) do shared.cfg(r) task.wait(0.35) end
end

--[[ [Server] Mode matrix and reset retention with an engineered build (expects an installed engineered build) ]]
local function matrixAndReset()
    local a = game.ServerScriptService.IronframeRangeAudit
    local b = a:Invoke("build")
    a:Invoke("mode", "PASSIVE") task.wait(0.5) a:Invoke("reset", "ALL") task.wait(3)
    a:Invoke("teleport", Vector3.new(0, 0.5, 430), math.pi)
    local out = { "build: " .. b.label .. " core=" .. b.structure.CORE .. " top=" .. string.format("%.1f", b.stats.topSpeed) }
    local c0 = a:Invoke("combat") task.wait(4) local c1 = a:Invoke("combat")
    table.insert(out, "PASSIVE: shots+" .. (c1.stats.shots - c0.stats.shots))
    a:Invoke("mode", "ACTIVE") task.wait(14) local c2 = a:Invoke("combat")
    table.insert(out, "ACTIVE: shots+" .. (c2.stats.shots - c1.stats.shots) .. " rook=" .. c2.rook.status)
    a:Invoke("mode", "MECH") task.wait(6) local c3 = a:Invoke("combat")
    table.insert(out, "MECH: rook=" .. c3.rook.state .. "/" .. c3.rook.status .. " tanks=" .. c3.tanks[1].state)
    a:Invoke("mode", "PASSIVE") a:Invoke("reset", "MECH") task.wait(3)
    local after = a:Invoke("build")
    table.insert(out, "after reset MECH: " .. after.label .. " core capacity=" .. after.runtime.damageCapacity.CORE .. " core health=" .. a:Invoke("mech").regions.CORE)
    a:Invoke("hit", "CORE", 99999) -- player core failure: the existing guaranteed-safe ejection; the rebuilt machine keeps the build
    for _ = 1, 20 do task.wait(0.5) local s = a:Invoke("session") if s.machineState == "OPERATIONAL" and s.deployment == "STOWED" then break end end
    local rebuilt = a:Invoke("build")
    table.insert(out, "after ejection: " .. rebuilt.label .. " customized=" .. tostring(rebuilt.customized) .. " last sortie outcome=" .. tostring(rebuilt.lastSortie and rebuilt.lastSortie.outcome))
    return table.concat(out, "\n")
end

return { clientHelpers, serverHelpers, hostileRequests, matrixAndReset }
