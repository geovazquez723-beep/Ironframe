-- CLIENT unit checks for heavy-weapon presentation bounds (HMG-20). Cosmetic owners only; no firing or damage.
local scripts=game.Players.LocalPlayer.PlayerScripts
local Casings=require(scripts.WeaponCasings)
local Audio=require(scripts.WeaponAudio)
local root=Instance.new("Folder");root.Name="M08DBudgetCheck";root.Parent=workspace
local owner=Instance.new("Model");owner.Name="M08DCosmeticOwner";owner.Parent=workspace
owner:SetAttribute("State","OPERATIONAL");owner:SetAttribute("Deployment","ACTIVE");owner:SetAttribute("WeaponSocket","right_arm")
local carrier=Instance.new("Part");carrier.Name="Weapon_right_arm_EjectionPort";carrier.Anchored=true
carrier.CanCollide,carrier.CanQuery,carrier.CanTouch=false,false,false
carrier.CFrame=workspace.CurrentCamera.CFrame*CFrame.new(0,0,-20);carrier.Parent=owner
local port=Instance.new("Attachment");port.Name="EjectionPort";port.Parent=carrier
local animator={TorsoCF=function() return nil end,ChassisCF=function() return CFrame.identity end}
local audio=Audio.New(root)
local casings=Casings.New(root,animator,audio)
local ok,result=pcall(function()
    for i=1,60 do casings:Emit(owner,"right_arm","W_HMG_MAULER") end
    local r=casings:Report()
    assert(r.active==10 and r.recycled==50 and r.heavy==60,"heavy casing cap failed: "..r.active)
    for _,m in ipairs(root.Brass:GetChildren()) do
        assert(m.Name=="SpentHMG20Case" and m.BrassWall.Size.X>=1 and m.BrassWall.Size.Y>=0.4,"wrong shell")
    end
    -- Mixed fire: MG-9 casings are independent of the heavy cap and the shared 28 cap still holds.
    for i=1,40 do casings:Emit(owner,"right_arm") end
    r=casings:Report()
    assert(r.active<=28,"shared cap exceeded: "..r.active)
    local spawned=r.spawned
    carrier.CFrame=CFrame.new(workspace.CurrentCamera.CFrame.Position+Vector3.new(0,0,500))
    casings:Emit(owner,"right_arm","W_HMG_MAULER")
    assert(casings:Report().spawned==spawned and casings:Report().culled>=1,"heavy distance budget failed")
    for i=1,50 do audio:Play("mauler",workspace.CurrentCamera.CFrame.Position,owner,"right_arm") end
    local a=audio:Report()
    assert(a.active==8 and a.stolen==42 and a.maulerConfigured,"mauler audio pool exceeded budget "..a.active)
    owner:SetAttribute("WeaponSocket","left_arm")
    casings:Step(1/60);audio:Step()
    assert(casings:Report().active==0 and audio:Report().active==0,"weapon swap did not clear heavy transients")
    owner:SetAttribute("WeaponSocket","right_arm")
    carrier.CFrame=workspace.CurrentCamera.CFrame*CFrame.new(0,0,-20)
    casings:Emit(owner,"right_arm","W_HMG_MAULER");audio:Play("mauler",carrier.Position,owner,"right_arm")
    owner:SetAttribute("Deployment","DOCKING");casings:Step(1/60);audio:Step()
    assert(casings:Report().active==0 and audio:Report().active==0,"recall did not clear heavy transients")
    return {casings=casings:Report(),audio=audio:Report(),swapAndRecall="PASS"}
end)
casings:Clear();audio:Clear();root:Destroy();owner:Destroy()
assert(ok,result)
return result
