-- Run on CLIENT during Play: AUTOCANNON preset deployed, mech facing the range (aim cone), right_arm = HMG-20.
-- Fires one authorized magazine through the production intent remote and measures casings, effects, audio and frame cost.
local player=game.Players.LocalPlayer
local RunService=game:GetService("RunService")
local control=player.PlayerScripts:WaitForChild("IronframeWeaponControl")
local model=workspace.IronframeMechs:FindFirstChild(tostring(player.UserId))
assert(model and model:GetAttribute("Deployment")=="ACTIVE","deploy first")
local drone=workspace.IronframeHangar.Bay_1.ProvingGround.MechanicalTarget2.RangeDrone2
control:Invoke("fire",false)
control:Invoke("select",2)
task.wait(0.3)
control:Invoke("reload")
task.wait(4.2)
assert(control:Invoke("stats").ammo==24 and model:GetAttribute("WeaponName")=="HMG-20 Mauler","full Mauler magazine required")
local fxBefore=control:Invoke("effects")
local hpBefore,hitsBefore=drone:GetAttribute("Durability"),drone:GetAttribute("Hits")
local root=workspace.IronframeWeaponEffects
local frames,sum,worst,peakCases,peakInstances,protected,peakEffects=0,0,0,0,0,0,0
local firstPort,firstMuzzle,caseDims
local caseSeenFlags=true
local ok,result=pcall(function()
    control:Invoke("fire",true,drone.Position)
    local deadline=os.clock()+30
    repeat
        local dt=RunService.RenderStepped:Wait()
        frames+=1;sum+=dt;worst=math.max(worst,dt)
        local brass=root.Brass
        peakCases=math.max(peakCases,#brass:GetChildren())
        peakInstances=math.max(peakInstances,#root:GetDescendants())
        local interior=workspace.IronframeCockpitClient:FindFirstChild("IronframeCockpit")
        local torso=interior and interior.CockpitRoot.CFrame
        for _,case in ipairs(brass:GetChildren()) do
            for _,part in ipairs(case:GetChildren()) do
                if not (part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch) then caseSeenFlags=false end
                if torso then
                    local p=torso:PointToObjectSpace(part.Position)
                    if p.X>-4.6 and p.X<4.6 and p.Y>1.3 and p.Y<6.35 and p.Z>-5 and p.Z<3.3 then protected+=1 end
                end
            end
            if not firstPort then
                local wall=case:FindFirstChild("BrassWall")
                firstPort=(wall.Position-model.Weapon_right_arm_EjectionPort.EjectionPort.WorldPosition).Magnitude
                firstMuzzle=(wall.Position-model.Weapon_right_arm_Emitter.Position).Magnitude
                caseDims=wall.Size
            end
        end
        local rep=control:Invoke("effects")
        peakEffects=math.max(peakEffects,rep.active)
    until control:Invoke("stats").ammo==0 or os.clock()>deadline
    control:Invoke("fire",false)
    task.wait(0.2)
    local during=control:Invoke("effects")
    local hpAfter,hitsAfter=drone:GetAttribute("Durability"),drone:GetAttribute("Hits")
    assert(during.casings.spawned-fxBefore.casings.spawned==24,"one casing per authorized shot failed: "..(during.casings.spawned-fxBefore.casings.spawned))
    assert(during.shots-fxBefore.shots==24 and peakCases<=10 and protected==0 and caseSeenFlags)
    assert(firstPort<1.2 and firstMuzzle>5,"brass did not originate at the receiver port")
    task.wait(3.6)
    local after=control:Invoke("effects")
    assert(after.casings.active==0 and after.active==0 and after.audio.active==0,"transient leak")
    -- The empty magazine reloads on the next trigger pull (or T), exactly as for MG-9; it is intentionally not refilled here.
    return {shots=24,casings=24,peakCases=peakCases,peakEffects=peakEffects,peakInstances=peakInstances,protectedArtifacts=protected,
        firstPort=firstPort,firstMuzzle=firstMuzzle,caseSize=tostring(caseDims),
        targetDamage=(hpBefore-hpAfter),targetHits=hitsAfter-hitsBefore,
        meanFrameMs=sum/frames*1000,worstFrameMs=worst*1000,
        effectsStepEmaMs=during.stepMs,effectsWorstMs=during.worstMs,audio=during.audio,after={casings=after.casings,audioActive=after.audio.active,instances=after.instances}}
end)
control:Invoke("fire",false)
assert(ok,result)
return result
