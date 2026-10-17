-- SERVER during Play. Tests the production controller/raycast against the production target registry.
local Server, Shared = game.ServerScriptService.IronframeServer, game.ReplicatedStorage.IronframeShared
local Weapons, Systems, Targets = require(Server.Weapons),require(Server.EnergySystems),require(Server.CombatTargets)
local Compiler, Loadouts = require(Shared.LoadoutCompiler),require(Shared.Loadouts)
local Locomotion = require(Server.Locomotion)
local testRange = Instance.new("Folder")
testRange.Name,testRange.Parent="M08BTestTargets",workspace
Targets.Build(testRange,Vector3.new(1000,0,0))
local target = testRange:FindFirstChild("RangeDrone2",true)
assert(target,"range targets missing")
local model = Instance.new("Model")
model.Name,model.Parent="M08BIntegrationCheck",workspace.IronframeMechs
model:SetAttribute("Deployment","ACTIVE");model:SetAttribute("State","OPERATIONAL")
local c=Locomotion.Create(model,"IF42_BASTION",Vector3.new(target.Position.X,0,target.Position.Z-65),math.pi)
local session={mech=model,controller=c,machineState="OPERATIONAL",deployment="ACTIVE",loadout=Loadouts.presets.BALANCED}
session.power=Systems.Create(model,Compiler.Compile(session.loadout).energy)
Weapons.Create(session)
local n=0
local effects={FireAllClients=function(_,_,_,_,origin,endpoint,normal,damage) n+=1;assert(damage>=0) end}
local out={}
local ok,err=pcall(function()
    local now=os.clock()
    Targets.Step(now+100) -- repair between test runs
    local initial=target:GetAttribute("Durability")
    Weapons.Intent(session,1,true,target.Position,false)
    Weapons.Step(session,effects)
    assert(n==1 and target:GetAttribute("Durability")==initial-25,"laser raycast did not damage authorized target")
    assert(session.power.energy.charge==136,"laser payment wrong")
    for i=1,100 do Weapons.Step(session,effects) end
    assert(n==1,"cadence bypass")
    out.laser={shots=n,damage=initial-target:GetAttribute("Durability"),charge=session.power.energy.charge}
    session.weapons.lastPacket=-100
    Weapons.Intent(session,2,true,target.Position,false)
    Weapons.Step(session,effects)
    assert(n==2 and session.weapons.slots.right_arm.ammo==59,"MG did not fire")
    assert(math.abs(target:GetAttribute("Durability")-(initial-30.2))<1e-6)
    out.ballistic={ammo=59,damage=5.2}
    local before=session.power.energy.charge
    -- Client-provided indices, vectors, NaN and excessive aim cannot change authorization or cause damage.
    for _,index in ipairs({0,7,0/0,math.huge,"1",{}}) do
        session.weapons.lastPacket=-100;Weapons.Intent(session,index,true,target.Position,false)
    end
    assert(session.weapons.selected==2)
    session.weapons.lastPacket=-100;Weapons.Intent(session,2,true,Vector3.new(0/0,1,2),false)
    session.weapons.lastPacket=-100;Weapons.Intent(session,2,true,Vector3.new(1e9,1,2),false)
    assert(session.weapons.aim==target.Position)
    session.weapons.lastPacket=-100;Weapons.Intent(session,1,true,Vector3.new(0,10,-100),false)
    session.weapons.slots.left_arm.nextShot=0;Weapons.Step(session,effects)
    assert(n==2 and session.power.energy.charge==before,"implausible aim spent energy")
    -- Mount-to-muzzle and muzzle-to-target occlusion are server raycasts, not client hit claims.
    local wall=Instance.new("Part")
    wall.Anchored=true;wall.Size=Vector3.new(35,35,2);wall.Position=Vector3.new(target.Position.X,15,target.Position.Z-35);wall.Parent=workspace
    session.weapons.lastPacket=-100;Weapons.Intent(session,1,true,target.Position,false)
    local hp=target:GetAttribute("Durability")
    Weapons.Step(session,effects)
    assert(target:GetAttribute("Durability")==hp,"shot passed through cover")
    wall:Destroy()
    local fake=Instance.new("Part");fake:SetAttribute("Targetable",true);fake.Parent=workspace
    assert(Targets.Hit(fake,"laser",100,now)==0,"tag spoof authorized damage");fake:Destroy()
    local avatar=game.Players:GetPlayers()[1].Character
    local human=avatar and avatar:FindFirstChildOfClass("Humanoid")
    if human then assert(Targets.Hit(avatar.PrimaryPart,"laser",100,now)==0 and human.Health==human.MaxHealth) end
    out.security="cadence, malformed intent, aim cone, LOS, tag spoof and pilot immunity passed"
    for _,state in ipairs({"STOWED","DEPLOYING","DOCKING","EJECTED"}) do
        session.deployment=state;session.weapons.slots.left_arm.nextShot=0
        session.weapons.lastPacket=-100;Weapons.Intent(session,1,true,target.Position,false)
        before=session.power.energy.charge;local shots=n;Weapons.Step(session,effects)
        assert(n==shots and session.power.energy.charge==before,"disabled state fired: "..state)
    end
    session.deployment="ACTIVE";session.machineState="PILOT_EVACUATED"
    Weapons.Cancel(session);assert(not session.weapons.held and model:GetAttribute("WeaponState")=="SAFE")
    out.disablement="garage, startup, docking, ejection, cancellation passed"
    Targets.Step(now+200);assert(target:GetAttribute("Durability")==600,"target reset failed")
    out.targetReset=true
end)
Locomotion.Destroy(c);model:Destroy();testRange:Destroy()
assert(ok,err)
return out
