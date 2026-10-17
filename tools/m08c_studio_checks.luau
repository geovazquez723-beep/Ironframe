-- Run on CLIENT during Play, after normal BALANCED deployment. Exercises one full magazine through the existing validated intent remote.
local player=game.Players.LocalPlayer
local control=player.PlayerScripts:WaitForChild("IronframeWeaponControl")
local model=workspace.IronframeMechs:FindFirstChild(tostring(player.UserId))
assert(model and model:GetAttribute("Deployment")=="ACTIVE","deploy first")
control:Invoke("fire",false)
control:Invoke("select",2)
task.wait(0.3)
control:Invoke("reload")
task.wait(3.3)
assert(control:Invoke("stats").ammo==60,"full magazine required")
local before=control:Invoke("stats")
local fxBefore=control:Invoke("effects")
local root=workspace.IronframeWeaponEffects
local frameCount,frameSum,worstFrame,peakCases,protected=0,0,0,0,0
local firstPortDistance,firstMuzzleDistance
local ok,result=pcall(function()
    -- Aim toward the chassis front; no target/hit claims are submitted by this test.
    local hull=model.Chassis
    local direction=hull.CFrame.LookVector
    control:Invoke("fire",true,hull.Position+direction*100)
    local deadline=os.clock()+12
    repeat
        local dt=game:GetService("RunService").RenderStepped:Wait()
        frameCount+=1;frameSum+=dt;worstFrame=math.max(worstFrame,dt)
        local brass=root.Brass
        peakCases=math.max(peakCases,#brass:GetChildren())
        local interior=workspace.IronframeCockpitClient:FindFirstChild("IronframeCockpit")
        local torso=interior and interior.CockpitRoot.CFrame
        for _,case in ipairs(brass:GetChildren()) do
            for _,part in ipairs(case:GetChildren()) do
                assert(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch,"brass participates in gameplay physics")
                if torso then
                    local p=torso:PointToObjectSpace(part.Position)
                    if p.X>-4.6 and p.X<4.6 and p.Y>1.3 and p.Y<6.35 and p.Z>-5 and p.Z<3.3 then protected+=1 end
                end
            end
            if not firstPortDistance then
                firstPortDistance=(case.BrassWall.Position-model.Weapon_right_arm_EjectionPort.EjectionPort.WorldPosition).Magnitude
                firstMuzzleDistance=(case.BrassWall.Position-model.Weapon_right_arm_Emitter.Position).Magnitude
            end
        end
    until control:Invoke("stats").ammo==0 or os.clock()>deadline
    control:Invoke("fire",false)
    task.wait(0.2)
    assert(control:Invoke("stats").ammo==0,"magazine not depleted")
    local during=control:Invoke("effects")
    assert(during.casings.spawned-fxBefore.casings.spawned==60,"one casing per authorized shot contract failed")
    assert(during.shots-fxBefore.shots==60 and peakCases<=28 and protected==0)
    assert(firstPortDistance<1 and firstMuzzleDistance>4,"brass did not originate at receiver")
    assert(during.audio.active<=12)
    task.wait(3.3)
    local after=control:Invoke("effects")
    assert(after.casings.active==0 and after.active==0 and after.audio.active==0,"transient effect leak")
    assert(control:Invoke("stats").ammo==60,"automatic reload regression")
    return {shots=60,casings=60,peakCases=peakCases,protectedArtifacts=protected,firstPortDistance=firstPortDistance,firstMuzzleDistance=firstMuzzleDistance,
        meanFrameMs=frameSum/frameCount*1000,worstFrameMs=worstFrame*1000,during=during,after=after}
end)
control:Invoke("fire",false)
assert(ok,result)
return result
