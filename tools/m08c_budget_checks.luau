-- CLIENT unit checks for presentation resource bounds, using temporary cosmetic owners (not damage/firing tests).
local scripts=game.Players.LocalPlayer.PlayerScripts
local Casings=require(scripts.WeaponCasings)
local Audio=require(scripts.WeaponAudio)
local root=Instance.new("Folder");root.Name="M08CBudgetCheck";root.Parent=workspace
local owner=Instance.new("Model");owner.Name="M08CCosmeticOwner";owner.Parent=workspace
owner:SetAttribute("State","OPERATIONAL");owner:SetAttribute("Deployment","ACTIVE");owner:SetAttribute("WeaponSocket","right_arm")
local carrier=Instance.new("Part");carrier.Name="Weapon_right_arm_EjectionPort";carrier.Anchored=true
carrier.CanCollide,carrier.CanQuery,carrier.CanTouch=false,false,false
carrier.CFrame=workspace.CurrentCamera.CFrame*CFrame.new(0,0,-20);carrier.Parent=owner
local port=Instance.new("Attachment");port.Name="EjectionPort";port.Parent=carrier
local animator={TorsoCF=function() return nil end,ChassisCF=function() return CFrame.identity end}
local audio=Audio.New(root)
local casings=Casings.New(root,animator,audio)
local ok,result=pcall(function()
    for i=1,60 do casings:Emit(owner,"right_arm") end
    assert(casings:Report().active==28 and casings:Report().recycled==32,"casing hard cap failed")
    local spawned=casings:Report().spawned
    carrier.CFrame=CFrame.new(workspace.CurrentCamera.CFrame.Position+Vector3.new(0,0,500))
    casings:Emit(owner,"right_arm")
    assert(casings:Report().spawned==spawned and casings:Report().culled==1,"casing distance budget failed")
    for i=1,50 do audio:Play("machine",workspace.CurrentCamera.CFrame.Position,owner,"right_arm") end
    assert(audio:Report().active==8 and audio:Report().stolen==42,"audio pool exceeded budget")
    owner:SetAttribute("WeaponSocket","left_arm")
    casings:Step(1/60);audio:Step()
    assert(casings:Report().active==0 and audio:Report().active==0,"weapon swap did not clear transients")
    owner:SetAttribute("WeaponSocket","right_arm")
    carrier.CFrame=workspace.CurrentCamera.CFrame*CFrame.new(0,0,-20)
    casings:Emit(owner,"right_arm");audio:Play("machine",carrier.Position,owner,"right_arm")
    owner:SetAttribute("Deployment","DOCKING");casings:Step(1/60);audio:Step()
    assert(casings:Report().active==0 and audio:Report().active==0,"recall did not clear transients")
    return {casings=casings:Report(),audio=audio:Report(),swapAndRecall="PASS"}
end)
casings:Clear();audio:Clear();root:Destroy();owner:Destroy()
assert(ok,result)
return result
