-- SERVER during Play. Production Weapons controller + Targets with the AUTOCANNON preset (HMG-20 on right_arm).
local Server, Shared = game.ServerScriptService.IronframeServer, game.ReplicatedStorage.IronframeShared
local Weapons, Systems, Targets = require(Server.Weapons),require(Server.EnergySystems),require(Server.CombatTargets)
local Compiler, Loadouts = require(Shared.LoadoutCompiler),require(Shared.Loadouts)
local Locomotion = require(Server.Locomotion)
local range = Instance.new("Folder")
range.Name,range.Parent="M08DTestTargets",workspace
Targets.Build(range,Vector3.new(1000,0,0))
local target = range:FindFirstChild("RangeDrone1",true) -- STANDARD armor, no ballistic mitigation
local plate = range:FindFirstChild("RangeDrone2",true) -- PLATE armor: ballistic x0.65
assert(target and plate)
local model = Instance.new("Model")
model.Name,model.Parent="M08DIntegrationCheck",workspace.IronframeMechs
model:SetAttribute("Deployment","ACTIVE");model:SetAttribute("State","OPERATIONAL")
local c=Locomotion.Create(model,"IF42_BASTION",Vector3.new(target.Position.X,0,target.Position.Z-70),math.pi)
local session={mech=model,controller=c,machineState="OPERATIONAL",deployment="ACTIVE",loadout=Loadouts.presets.AUTOCANNON}
session.power=Systems.Create(model,Compiler.Compile(session.loadout).energy)
Weapons.Create(session)
local shots,fired={},0
local effects={FireAllClients=function(_,_,socket,id,_,_,_,damage) fired+=1;table.insert(shots,{os.clock(),socket,id,damage}) end}
local out={}
local ok,err=pcall(function()
    Targets.Step(os.clock()+100)
    local hp0=target:GetAttribute("Durability")
    local energy=session.power.energy
    local c0=energy.charge
    Weapons.Intent(session,2,true,target.Position,false)
    Weapons.Step(session,effects)
    assert(fired==1 and shots[1][3]=="W_HMG_MAULER" and shots[1][4]==25,"Mauler did not fire for 25")
    assert(math.abs(target:GetAttribute("Durability")-(hp0-25))<1e-6,"server damage mismatch")
    assert(math.abs(c0-energy.charge-2.5)<1e-6 and session.weapons.slots.right_arm.ammo==23,"payment/ammo")
    for i=1,50 do Weapons.Step(session,effects) end
    assert(fired==1,"cadence bypass within the same frame window")
    -- Held fire for 3.0s: server cadence must be 3 shots/s (+/- one) and consume exactly 2.5/shot.
    local startShots,t0=fired,os.clock()
    repeat
        session.weapons.lastPacket=-100;Weapons.Intent(session,2,true,target.Position,false)
        Weapons.Step(session,effects);task.wait()
    until os.clock()-t0>=3
    local elapsed,count=os.clock()-t0,fired-startShots
    out.cadence={shots=count,seconds=elapsed,perSecond=count/elapsed}
    assert(count>=7 and count<=10,"3 Hz cadence expected, got "..count)
    -- Heavy plate-armor mitigation is resolved server-side (x0.65).
    session.weapons.lastPacket=-100;session.weapons.slots.right_arm.nextShot=0
    Weapons.Intent(session,2,true,plate.Position,false)
    local hp=plate:GetAttribute("Durability");Weapons.Step(session,effects)
    assert(math.abs(hp-plate:GetAttribute("Durability")-25*0.65)<1e-6,"plate mitigation")
    -- Drain the magazine: reload begins automatically and lasts exactly 3.8s.
    local slot=session.weapons.slots.right_arm
    repeat
        slot.nextShot=0;session.weapons.lastPacket=-100;Weapons.Intent(session,2,true,target.Position,false)
        Weapons.Step(session,effects);task.wait()
        energy.charge=160;energy.tokens=energy.config.burstLimit
    until slot.ammo==0 or slot.reloadAt
    slot.nextShot=0;session.weapons.lastPacket=-100;Weapons.Intent(session,2,true,target.Position,false)
    Weapons.Step(session,effects)
    assert(slot.reloadAt,"reload did not start")
    out.reloadSeconds=slot.reloadAt-os.clock()
    assert(math.abs(out.reloadSeconds-3.8)<0.3,out.reloadSeconds)
    local before=fired
    for i=1,30 do slot.nextShot=0;Weapons.Step(session,effects);task.wait() end
    assert(fired==before,"fired during reload")
    task.wait(out.reloadSeconds+0.2);Weapons.Step(session,effects)
    assert(slot.ammo>=23,"reload did not refill")
    -- Swaps: MG-9 (left_shoulder idx 3) and LR-12 (left_arm idx 1) keep independent state.
    session.weapons.lastPacket=-100;Weapons.Intent(session,3,true,target.Position,false)
    local mg0=session.weapons.slots.left_shoulder.ammo;Weapons.Step(session,effects)
    assert(session.weapons.slots.left_shoulder.ammo==mg0-1)
    session.weapons.lastPacket=-100;Weapons.Intent(session,1,true,target.Position,false)
    local cl=energy.charge;Weapons.Step(session,effects)
    assert(math.abs(cl-energy.charge-24)<1e-6)
    out.swap="MG-9 and LR-12 payment independent of Mauler magazine"
    -- Disablement: no fire while stowed/ejected.
    for _,state in ipairs({"STOWED","DEPLOYING","DOCKING","EJECTED"}) do
        session.deployment=state;slot.nextShot=0;session.weapons.lastPacket=-100
        Weapons.Intent(session,2,true,target.Position,false)
        local n,ch=fired,energy.charge;Weapons.Step(session,effects)
        assert(fired==n and energy.charge==ch,"fired while "..state)
    end
    session.deployment="ACTIVE"
    local avatar=game.Players:GetPlayers()[1].Character
    local human=avatar and avatar:FindFirstChildOfClass("Humanoid")
    if human then assert(Targets.Hit(avatar.PrimaryPart,"ballistic",100,os.clock())==0 and human.Health==human.MaxHealth) end
    out.pilotSafe=true
    out.totalShots=fired
end)
Locomotion.Destroy(c);model:Destroy();range:Destroy()
assert(ok,err)
return out
