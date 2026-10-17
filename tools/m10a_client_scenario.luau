-- M10A live scenario. Run with execute_luau on the CLIENT during Play (Ironframe-M10A.rbxl, single player, Bay_1). It uses only the
-- production client test interfaces (IronframeDeploymentControl / IronframeWeaponControl / IronframeRangeControl /
-- IronframeDestructionControl), i.e. the same remotes and server validation as a human pilot. Each stage is a separate call:
--
--   stage "deploy"   AUTOCANNON loadout (LR-12 slot 1, HMG-20 slot 2, MG-9 slot 3), enter cockpit, deploy, drive hangar -> district
--   stage "fire"     hold-fire a weapon slot at a world point (aim override), e.g. ("fire", 2, Vector3.new(-38, 6, 428))
--   stage "reset"    press RESET ENTIRE DISTRICT through the HUD remote
--   stage "return"   recall to the hangar
--   stage "eject"    safe ejection while deployed
--
-- Waypoints avoid the pre-existing proving-ground obstacles (range drone pedestal at x = 0 z = 205, distance-marker posts at
-- x = +-25.5, gantry arch pillars x = +-17 at z = 228): the Bastion hull is 14 wide.
local lp = game.Players.LocalPlayer
local ps = lp.PlayerScripts
local dep, wc = ps:WaitForChild("IronframeDeploymentControl"), ps:WaitForChild("IronframeWeaponControl")
local function wrap(a) return (a + 180) % 360 - 180 end

shared.drive = function(waypoints, sprintAfterZ)
    shared.auto = { wp = waypoints, i = 1, run = true }
    local token = shared.auto
    task.spawn(function()
        local lastP, lastT, reverseUntil = nil, os.clock(), 0
        while token.run do
            task.wait(0.1)
            local m = workspace.IronframeMechs:FindFirstChild(tostring(lp.UserId))
            local c = m and m:FindFirstChild("Chassis")
            if not c then continue end
            local p, t = c.Position, token.wp[token.i]
            local want = math.deg(math.atan2(t.X - p.X, -(t.Z - p.Z))) % 360
            local err = wrap(want - dep:Invoke("stats").heading)
            local dist = Vector3.new(t.X - p.X, 0, t.Z - p.Z).Magnitude
            token.pos, token.err = p, err
            local now = os.clock()
            if now - lastT > 1.5 then -- wedge detector: back off for 1.5 s
                if lastP and (p - lastP).Magnitude < 0.6 and dist > 6 then reverseUntil = now + 1.5 end
                lastP, lastT = p, now
            end
            if now < reverseUntil then
                dep:Invoke("input", -1, 0, false)
            elseif dist < 5 then
                if token.i < #token.wp then token.i += 1 else token.arrived, token.run = true, false end
            else
                -- positive steer DEcreases the heading, hence the minus sign.
                dep:Invoke("input", math.clamp(1 - math.abs(err) / 40, 0, 1), math.clamp(-err / 40, -1, 1), p.Z > (sprintAfterZ or 250))
            end
        end
        dep:Invoke("input", 0, 0, false)
    end)
end

local stage, a, b = ...
if stage == "deploy" then
    game.ReplicatedStorage.IronframeRemotes.SetPreset:FireServer("AUTOCANNON")
    task.wait(2)
    dep:Invoke("action") task.wait(2.5) -- enter cockpit
    dep:Invoke("action") task.wait(5) -- deploy (doors open, reactor starts)
    shared.drive({ Vector3.new(0, 0, 100), Vector3.new(14, 0, 180), Vector3.new(14, 0, 213), Vector3.new(2, 0, 228), Vector3.new(0, 0, 250), Vector3.new(0, 0, 372) })
    return "driving"
elseif stage == "fire" then
    wc:Invoke("select", a)
    wc:Invoke("fire", true, b)
    return "firing (release with wc:Invoke('fire', false))"
elseif stage == "reset" then
    ps.IronframeRangeControl:Invoke("reset", a or "ALL")
elseif stage == "return" then
    dep:Invoke("return")
elseif stage == "eject" then
    dep:Invoke("eject")
end
return "ok"
