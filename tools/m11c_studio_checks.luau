-- M11C Studio checks (not run by tools/check.sh). Paste each block into the Studio MCP `execute_luau` of a Play session on build/Ironframe-M11C.rbxl
-- (datamodel noted per block). Everything uses the production paths: the real client controls (PlayerScripts.Iron*Control bindables, which call the same
-- functions the keys and buttons call), the real remotes, and the server-only audit bindable ServerScriptService.IronframeRangeAudit:
--   "av"        avionics snapshot (contacts, lock, capability, demand, factor, ray / packet counters)
--   "avcmd"     cmd, a, b: the validated RequestAvionics entry point ("zoom" | "thermal" | "acquire" | "release" | "reset")
--   "avcharge"  capacitor charge (starvation tests: call it every 0.1 s to hold the capacitor empty)
--   "teleport", "mode" PASSIVE|ACTIVE|MECH, "part" / "fire" (destroy a tank), "state", "build"
-- Studio notes (see the M10B / M11B notes): execute_luau calls time out at ~60-90 s; a rebuild needs a fresh Studio instance and a new studio id.

--[[ 1. [Client] install a full recon build through the real garage UI, enter the cockpit, deploy ]]
local function installReconAndDeploy()
    local p = game.Players.LocalPlayer.PlayerScripts
    local cc, ec = p.IronframeCockpitControl, p.IronframeEngineeringControl
    ec:Invoke("tab", "weapons"); ec:Invoke("slot", "left_shoulder"); ec:Invoke("select", "EMPTY"); task.wait(0.4); ec:Invoke("install"); task.wait(1.5) -- free 3 t
    ec:Invoke("tab", "cockpit"); ec:Invoke("select", "CKP_RECON"); task.wait(0.4); ec:Invoke("install"); task.wait(1.5)
    for _, spec in ipairs({ { "radar", "AV_RADAR_ENHANCED" }, { "optics", "AV_OPTICS_ZOOM" }, { "thermal", "AV_THERMAL" }, { "targeting", "AV_TRACKER" } }) do
        ec:Invoke("tab", "avionics"); ec:Invoke("avslot", spec[1]); ec:Invoke("select", spec[2]); task.wait(0.4); ec:Invoke("install"); task.wait(1.5)
    end
    cc:Invoke("toggle"); task.wait(3.5); cc:Invoke("skipBoot"); task.wait(2)
    p.IronframeDeploymentControl:Invoke("action")
    for _ = 1, 15 do task.wait(1); if p.IronframeDeploymentControl:Invoke("stats").deployment == "ACTIVE" then break end end
    return ec:Invoke("state").build
end

--[[ 2. [Server] Range 07 radar: real contacts with bearings and identification ]]
local function radar()
    local a = game.ServerScriptService.IronframeRangeAudit
    a:Invoke("teleport", Vector3.new(0, 0.5, 400), math.pi)
    task.wait(3)
    local av = a:Invoke("av")
    local out = { "radar=" .. av.radar.mode .. " " .. av.radar.state, "demand=" .. av.demand }
    for _, c in ipairs(av.contacts) do out[#out + 1] = string.format("[%s %s b=%d d=%d]", c.name or "UNK", c.status, c.bearing, c.distance) end
    return table.concat(out, " ")
end

--[[ 3. [Client] zoom: FOV against the baseline (true magnification), acquire, thermal ]]
local function zoomLockThermal()
    local av = game.Players.LocalPlayer.PlayerScripts.IronframeAvionicsControl
    local out = {}
    for _, label in ipairs({ "start", "2x", "4x", "1x" }) do
        if label ~= "start" then av:Invoke("zoom"); task.wait(1.2) end
        local s = av:Invoke("stats")
        out[#out + 1] = string.format("%s fov=%.2f zoom=%.3f", label, s.fov, s.zoom)
    end
    av:Invoke("acquire"); task.wait(1)
    av:Invoke("thermal"); task.wait(1.5)
    local pk, s = av:Invoke("packet"), av:Invoke("stats")
    out[#out + 1] = string.format("lock=%s st=%s thermal=%s lit=%d box=%s obscured=%s", tostring(pk.lock and pk.lock.nm), tostring(pk.lock and pk.lock.st), tostring(s.thermal.active), s.thermal.lit, tostring(s.boxVisible), tostring(s.boxObscured))
    return table.concat(out, "\n")
end

--[[ 4. [Server] cover: a test wall between the pilot and T-02. Radar keeps the contact (radar is not line of sight), thermal drops the machine, the lock coasts then releases ]]
local function cover()
    local wall = Instance.new("Part")
    wall.Name, wall.Size, wall.Position, wall.Anchored, wall.Parent = "M11CTestWall", Vector3.new(70, 60, 3), Vector3.new(14, 28, 440), true, workspace
    local a = game.ServerScriptService.IronframeRangeAudit
    local out = {}
    for i = 1, 6 do
        task.wait(1)
        local av = a:Invoke("av")
        out[#out + 1] = string.format("t=%ds lock=%s hot=%d contacts=%d", i, av.lock and (av.lock.state .. " " .. av.lock.reason) or "none", av.hot, #av.contacts)
    end
    wall:Destroy()
    return table.concat(out, "\n")
end

--[[ 5. [Server] energy starvation: hold the capacitor empty. Enhanced radar falls back to basic, thermal "NO POWER", tracker offline, recovery after release ]]
local function starve()
    local a = game.ServerScriptService.IronframeRangeAudit
    local out = {}
    local function sample(label)
        local av = a:Invoke("av")
        out[#out + 1] = string.format("%s factor=%.2f radar=%s/%s r=%.0f thermal=%s tracker=%s notes=%s", label, av.factor, av.radar.mode, av.radar.state, av.radar.range, tostring(av.thermal and av.thermal.available), tostring(av.tracker and av.tracker.available), table.concat(av.notes or {}, ","))
    end
    sample("healthy")
    for _ = 1, 40 do a:Invoke("avcharge", 0); task.wait(0.1) end
    sample("starved 4 s")
    task.wait(5)
    sample("recovered")
    return table.concat(out, "\n")
end

--[[ 6. [Server] a destroyed tank: radar status, lock release and thermal cooling ]]
local function destroyTank()
    local a = game.ServerScriptService.IronframeRangeAudit
    for _ = 1, 700 do a:Invoke("fire", a:Invoke("part", "tank", 2, "HULL"), "W_HMG_MAULER", 1) end
    local out = {}
    for i = 1, 4 do
        task.wait(1)
        local av = a:Invoke("av")
        local heat
        for _, ac in ipairs(av.actors) do if ac.id == "T-02" then heat = ac.heat end end
        out[#out + 1] = string.format("t=%d lock=%s T-02 heat=%.2f", i, av.lock and av.lock.state or "released", heat or -1)
    end
    return table.concat(out, "\n")
end

--[[ 7. [Client] ejection with zoom and thermal on, then the camera and avionics must be back at 1x / off, and the build retained ]]
local function ejection()
    local p = game.Players.LocalPlayer.PlayerScripts
    local av = p.IronframeAvionicsControl
    av:Invoke("zoom"); task.wait(0.8)
    p.IronframeCockpitControl:Invoke("eject")
    local log = {}
    for i = 1, 12 do
        task.wait(1)
        local s = av:Invoke("stats")
        log[#log + 1] = string.format("t=%d mode=%s fov=%.1f zoom=%.2f thermal=%s", i, p.IronframeCockpitControl:Invoke("stats").mode, s.fov, s.zoom, tostring(s.thermal.active))
    end
    return table.concat(log, "\n")
end

--[[ 8. [Client] hostile payloads through the real remotes (build must not change) ]]
local function hostile()
    local r = game.ReplicatedStorage.IronframeRemotes
    for _, payload in ipairs({ { cockpit = "CKP_FANCY" }, { avionics = { thermal = "AV_RADAR_BASIC" } }, { radarRange = 9999 }, { avionics = { thermal = { range = 9999 } } }, "x", {} }) do
        r.RequestLoadout:FireServer(payload); task.wait(0.3)
    end
    for _, args in ipairs({ { "zoom", 99 }, { "zoom", 0 / 0 }, { "thermal", 5 }, { "acquire", Vector3.new(0, 0, 0) }, { "acquire", Vector3.new(5, 5, 5) }, { 5 }, { string.rep("z", 40) } }) do
        r.RequestAvionics:FireServer(table.unpack(args)); task.wait(0.12)
    end
end

--[[ 9. [Client] cleanup: instance counts before / after repeated deploy cycles with avionics use (workspace, PlayerGui and camera children must be constant) ]]
local function cycles()
    local p = game.Players.LocalPlayer.PlayerScripts
    local function counts()
        return string.format("workspace=%d playerGui=%d cam=%d", #workspace:GetDescendants(), #game.Players.LocalPlayer.PlayerGui:GetDescendants(), #workspace.CurrentCamera:GetChildren())
    end
    local out = { "start: " .. counts() }
    for cycle = 1, 3 do
        p.IronframeDeploymentControl:Invoke("action")
        for _ = 1, 15 do task.wait(1); if p.IronframeDeploymentControl:Invoke("stats").deployment == "ACTIVE" then break end end
        local av = p.IronframeAvionicsControl
        av:Invoke("thermal"); task.wait(0.6); av:Invoke("zoom"); task.wait(0.6); av:Invoke("acquire"); task.wait(0.8)
        p.IronframeDeploymentControl:Invoke("return")
        for _ = 1, 25 do task.wait(1); if p.IronframeDeploymentControl:Invoke("stats").deployment == "STOWED" then break end end
        out[#out + 1] = string.format("cycle %d: %s", cycle, counts())
    end
    return table.concat(out, "\n")
end

return { installReconAndDeploy, radar, zoomLockThermal, cover, starve, destroyTank, ejection, hostile, cycles }
