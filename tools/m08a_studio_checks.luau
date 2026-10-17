-- Run on the SERVER during Play after the proving ground exists. Temporary controllers use real M07 collision queries.
local Server = game.ServerScriptService.IronframeServer
local Shared = game.ReplicatedStorage.IronframeShared
local Compiler, Loadouts = require(Shared.LoadoutCompiler), require(Shared.Loadouts)
local Locomotion, Systems = require(Server.Locomotion), require(Server.EnergySystems)
local Shield = require(Shared.PulseShield)
local results = {}
-- M09: the default profile (BALANCED) now reserves capacitor charge from sprint; M08A drain assertions use MOBILITY (no sprint reserve).
local function withController(callback, empty, profile)
    local model = Instance.new("Model")
    model.Name, model.Parent = "M08AIntegrationCheck", workspace.IronframeMechs
    model:SetAttribute("Deployment", "ACTIVE")
    model:SetAttribute("State", "OPERATIONAL")
    local p = Systems.Create(model, Compiler.Compile(Loadouts.presets.BALANCED).energy, profile)
    if empty then p.energy = require(Shared.Energy).New(p.config,0) end
    local c = Locomotion.Create(model,"IF42_BASTION",Vector3.new(0,0,90),math.pi)
    c.energySystems = p
    Locomotion.SetLocked(c,false)
    local ok, result = pcall(callback,p,c,model)
    Locomotion.Destroy(c); model:Destroy()
    assert(ok,result)
    return result
end
local function step(c,frames,throttle,sprint)
    local peak = 0
    for i=1,frames do
        Locomotion.SetInput(c,throttle,0,sprint)
        Locomotion.Step(c,1/60)
        peak=math.max(peak,math.abs(c.state.speed))
        if i%60==0 then task.wait() end
    end
    return peak
end
results.sprint = withController(function(p,c)
    local peak=step(c,180,1,true)
    local low=p.energy.charge
    assert(peak>18 and low<5,"sprint did not spend reserves for greater speed")
    step(c,120,0,false); step(c,180,0,false)
    assert(p.energy.charge>100 and c.state.speed==0,"idle recovery failed")
    return {peakSpeed=peak,lowCharge=low,recoveredCharge=p.energy.charge}
end,nil,"MOBILITY")
results.sprintBalanced = withController(function(p,c)
    local peak=step(c,180,1,true)
    assert(peak>16 and p.energy.charge>=47,"balanced sprint breached its 30% capacitor reserve")
    return {peakSpeed=peak,charge=p.energy.charge}
end)
local function sprintReserve(shield)
    return withController(function(p,c)
        if shield then assert(Systems.Activate(p,true)) end
        step(c,96,1,true)
        return p.energy.charge
    end,nil,"MOBILITY")
end
results.combined = {sprint=sprintReserve(false),sprintShield=sprintReserve(true)}
assert(results.combined.sprintShield<results.combined.sprint-20,"shield/sprint did not compete")
results.weapons = withController(function(p,c)
    assert(Systems.RequestTest(p,"WEAPON_LOAD",math.pi,Locomotion.Position(c)))
    step(c,90,0,false)
    local idleWeapon = {demand=p.energy.demand,served=p.energy.delivered.weapons,charge=p.energy.charge}
    assert(math.abs(idleWeapon.served-100)<1e-6 and idleWeapon.charge<160,"idle weapon simulation was not funded")
    assert(not Systems.RequestTest(p,{damage=1000000},0,Locomotion.Position(c)),"client damage accepted as test pattern")
    return idleWeapon
end)
results.empty = withController(function(p,c)
    assert(Systems.RequestTest(p,"WEAPON_LOAD",math.pi,Locomotion.Position(c)))
    step(c,90,1,true)
    assert(c.state.speed>5 and p.sprintFraction==0 and p.energy.deficit>0,"starvation immobilized drive or gave free sprint")
    assert(not Systems.Activate(p,true) and p.shield.reason=="CAPACITOR LOW","empty shield activation succeeded")
    return {speed=c.state.speed,deficit=p.energy.deficit,shield=p.shield.reason}
end,true,"WEAPONS")
results.thermal = withController(function(p,c,model)
    p.energy.thermal=100
    step(c,60,1,false)
    assert(p.energy.output<60 and p.energy.efficiency<0.6 and c.state.speed>0)
    assert(model:GetAttribute("State")=="OPERATIONAL","thermal load caused physical defeat")
    return {output=p.energy.output,efficiency=p.energy.efficiency,thermal=p.energy.thermal,speed=c.state.speed}
end,true)
results.sustain = withController(function(p,c)
    p.energy = require(Shared.Energy).New(p.config,26)
    assert(Systems.Activate(p,true))
    step(c,18,1,true)
    assert(not Shield.Protects(p.shield) and p.shield.reason=="SUSTAIN ENERGY LOW","unfunded shield stayed active")
    return {state=p.shield.state,reason=p.shield.reason,charge=p.energy.charge}
end,nil,"MOBILITY") -- MOBILITY serves sprint ahead of shield sustain; BALANCED banks surplus instead (see M09 doc)
results.defense = {}
for _,spec in ipairs({{"perfect",12,"laser",-1,58.8},{"ordinary",30,"laser",-1,48},{"plasma",30,"plasma",-1,30},{"rear",12,"missile",1,0}}) do
    results.defense[spec[1]] = withController(function(p,c)
        assert(Systems.Activate(p,true))
        step(c,spec[2],0,false)
        -- yaw pi faces +Z, so a front source has positive Z.
        local r=Systems.ResolveImpact(p,{damage=60,category=spec[3],fromX=0,fromZ=-spec[4]},math.pi)
        assert(math.abs(r.prevented-spec[5])<1e-6,"unexpected defense result")
        assert(not Systems.Activate(p,true),"cooldown bypass")
        Systems.Cancel(p)
        assert(not Shield.Protects(p.shield) and p.pending==nil and p.weaponUntil==0,"cancel preserved defense/actions")
        return r
    end)
end
return results
