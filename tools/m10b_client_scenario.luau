-- M10B live scenario, CLIENT side (execute_luau datamodel_type "Client" during Play of Ironframe-M10B.rbxl). Uses only production
-- client interfaces (same remotes and server validation as a pilot) plus real keyboard / mouse input from the Studio MCP:
--
--   1. SetPreset AUTOCANNON (remote) then keys F (enter cockpit) and F (deploy) with user_keyboard_input
--   2. server: teleport the Bastion to the staging field (the hangar drive is covered by earlier milestones)
--   3. key W held 4.5 s: real drive into the district (zone HANGAR -> STAGING -> DISTRICT)
--   4. key N: ACTIVE TRAINING (the hotkey only works while the Range panel is visible, i.e. inside the district)
--   5. guard assist (below) presses the real shield action when the HUD ring says GUARD NOW
--   6. key 2 + mouse left held: HMG-20 fire; keys V (view), C (profile), X (eject, exterior view only)
--
-- Guard assist: a stand-in for human reaction timing. It presses the same action as the G key (IronframeDeploymentControl "shield").
local lp = game.Players.LocalPlayer
local ctl = lp.PlayerScripts:WaitForChild("IronframeCombatControl")
local dep = lp.PlayerScripts:WaitForChild("IronframeDeploymentControl")
shared.guard = { presses = 0, run = true, log = {} }
task.spawn(function()
    while shared.guard.run do
        task.wait(0.02)
        local st = ctl:Invoke("state")
        if string.find(st.ringLabel, "NOW") then
            dep:Invoke("shield")
            shared.guard.presses += 1
            table.insert(shared.guard.log, st.threat)
            task.wait(1.2)
        end
    end
end)
return "guard assist running; stop with shared.guard.run = false"
