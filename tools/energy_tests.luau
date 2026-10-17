local Energy = require("../src/ReplicatedStorage/IronframeShared/Energy")
local Shield = require("../src/ReplicatedStorage/IronframeShared/PulseShield")
local Config = require("../src/ReplicatedStorage/IronframeShared/EnergyConfig")
local Components = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local Drive = require("../src/ReplicatedStorage/IronframeShared/MechDrive")
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed += 1; print("  ok   " .. name) else failed += 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function near(a,b,tol) assert(math.abs(a-b)<(tol or 1e-6),tostring(a).." vs "..tostring(b)) end
local function config()
    return Config.Build(Chassis.IF42_BASTION,Components.CORE_220,Components.CAP_STANDARD,Components.RAD_STANDARD,Components.SHIELD_PULSE)
end
local function advance(s, seconds, requests, online, hz)
    hz = hz or 120
    for _ = 1, math.floor(seconds*hz+0.5) do
        for _,r in ipairs(requests or {}) do Energy.Request(s,r[1],r[2]) end
        Energy.Advance(s,1/hz,online ~= false)
    end
end
local function shieldAdvance(s,c,seconds,enabled)
    local remaining = seconds
    while remaining > 1e-8 do local dt=math.min(remaining,1/120); Shield.Advance(s,c,dt,enabled ~= false); remaining-=dt end
end
local function activated(at, category, direction, charge)
    local c=config(); local e=Energy.New(c,charge); local s=Shield.New(c.shield)
    assert(Shield.Activate(s,c.shield,function(cost) return Energy.Spend(e,cost) end,true))
    shieldAdvance(s,c.shield,at)
    local result=Shield.Resolve(s,c.shield,{damage=60,category=category or "laser",fromX=0,fromZ=direction or -1},0,function(cost) return Energy.Consume(e,cost,true) end)
    return result,e,s
end

test("conservation includes reactor production, capacitor, consumption, conversion loss and unused supply",function()
    local c=config(); c.output=100; c.thermalPerEnergy=0; c.thermalPerDischarge=0
    local s=Energy.New(c,0)
    advance(s,1,{{"idle",20}})
    near(s.charge,45); near(s.ledger.consumed,20); near(s.ledger.loss,5); near(s.ledger.wasted,30)
    near(s.ledger.initial+s.ledger.generated,s.charge+s.ledger.consumed+s.ledger.loss+s.ledger.wasted)
end)
test("continuous and discrete requests debit one capacitor without double spending",function()
    local c=config(); local s=Energy.New(c)
    assert(Energy.Spend(s,25)); advance(s,1,{{"weapons",100}},false)
    near(s.charge,35); near(s.ledger.consumed,125)
    near(s.ledger.initial+s.ledger.generated,s.charge+s.ledger.consumed+s.ledger.loss+s.ledger.wasted)
end)
test("configured continuous discharge limit is enforced",function()
    local c=config(); c.maxDischargeRate=10
    local s=Energy.New(c); advance(s,1,{{"burst",100}},false)
    near(s.charge,150); near(s.served,10); near(s.deficit,90)
end)
test("burst token bucket prevents repeated activation costs exceeding the discharge budget",function()
    local s=Energy.New(config()); assert(Energy.Spend(s,25)); assert(Energy.Spend(s,25))
    assert(not Energy.Spend(s,25)); near(s.charge,110)
    advance(s,0.25,{},false); assert(Energy.Spend(s,25))
end)
test("negative, nonfinite, malformed and excessive costs cannot mint energy",function()
    local s=Energy.New(config()); local original=s.charge
    for _,bad in ipairs({-25,0/0,math.huge,"25",{}}) do assert(not Energy.Spend(s,bad)); assert(not Energy.Request(s,"bad",bad)) end
    assert(not Energy.Spend(s,1000)); near(s.charge,original)
end)
test("regeneration reflects available reactor surplus and stops at capacity",function()
    local idle=Energy.New(config(),20); local walk=Energy.New(config(),20); local sprint=Energy.New(config(),160)
    advance(idle,1,{{"idle",8}}); advance(walk,1,{{"idle",8},{"propulsion",34}})
    advance(sprint,1,{{"idle",8},{"propulsion",40},{"sprint",100}})
    assert(idle.charge>walk.charge and walk.charge>20 and sprint.charge<160)
    advance(idle,20,{}); near(idle.charge,idle.config.capacity)
end)
test("hitches are bounded and dt partitioning preserves the energy ledger",function()
    local a,b=Energy.New(config(),0),Energy.New(config(),0)
    advance(a,4,{{"idle",8}},true,30); advance(b,4,{{"idle",8}},true,144)
    near(a.charge,b.charge,0.01); near(a.thermal,b.thermal,0.05)
    local s=Energy.New(config(),0); Energy.Advance(s,100,true); assert(s.charge<=12)
    assert(not Energy.Advance(s,0/0,true))
end)
test("thermal strain reduces output and charging efficiency without physical damage",function()
    local s=Energy.New(config(),0); s.thermal=100; advance(s,0.1,{{"idle",8}})
    assert(s.output<50 and s.efficiency<0.5 and s.thermal<100)
    assert(s.integrity==nil and s.pilotSafe==nil)
    advance(s,30,{{"idle",8}}); assert(s.thermal<40 and s.output>70)
end)
test("high sustained demand increases thermal load but remains clamped",function()
    local s=Energy.New(config()); advance(s,12,{{"drive",45},{"weapons",100},{"sprint",100}})
    assert(s.thermal>40 and s.thermal<=100 and s.charge>=0)
end)
test("idle and walking take priority; simulated weapons compete with sprint",function()
    local s=Energy.New(config(),0)
    Energy.Request(s,"sprint",100); Energy.Request(s,"weapons",100); Energy.Request(s,"propulsion",34); Energy.Request(s,"idle",8)
    Energy.Advance(s,0.1,true)
    near(s.delivered.idle,8); near(s.delivered.propulsion,34); near(s.delivered.weapons,38); near(s.delivered.sprint,0)
end)
test("acceleration, braking, reverse and turning create propulsion demand",function()
    local c=config(); local d=Drive.New(0,0,0)
    local idle=Energy.MovementDemand(c,d,0,0,false); near(idle,0)
    local reverse=Energy.MovementDemand(c,d,-1,0,false); assert(reverse>0)
    local turn=Energy.MovementDemand(c,d,0,1,false); assert(turn>0)
    d.speed,d.accel=10,7
    local accelerating=Energy.MovementDemand(c,d,1,0,false); d.accel=0
    local coasting=Energy.MovementDemand(c,d,0,0,false); assert(accelerating>coasting and coasting>0)
end)
test("empty capacitor retains basic movement and idle energy recovers",function()
    local c=config(); local s=Energy.New(c,0); local d=Drive.New(0,0,0)
    for _=1,600 do
        local p,b=Energy.MovementDemand(c,d,1,0,true)
        Energy.Request(s,"idle",8); Energy.Request(s,"propulsion",p); Energy.Request(s,"sprint",b); Energy.Advance(s,1/60,true)
        local base,boost=Energy.Performance(s,p,b)
        Drive.Advance(d,{throttle=1,steer=0,speedScale=base*(1+boost*0.6),accelScale=base},1/60,Chassis.IF42_BASTION.locomotion)
    end
    assert(d.speed>10 and s.charge>=0 and d.z< -50)
    advance(s,2,{{"idle",8}}); assert(s.charge>40)
end)
test("stored reserves grant temporary sprint beyond ordinary walk speed",function()
    local c=config(); local s=Energy.New(c); local d=Drive.New(0,0,0); local peak=0
    for _=1,300 do
        local p,b=Energy.MovementDemand(c,d,1,0,true)
        Energy.Request(s,"idle",8); Energy.Request(s,"propulsion",p); Energy.Request(s,"sprint",b); Energy.Advance(s,1/60,true)
        local base,boost=Energy.Performance(s,p,b)
        Drive.Advance(d,{throttle=1,steer=0,speedScale=base*(1+boost*0.6),accelScale=base*(1+boost*0.35)},1/60,Chassis.IF42_BASTION.locomotion)
        peak=math.max(peak,d.speed)
    end
    assert(peak>18 and s.charge<10,"peak="..peak.." charge="..s.charge)
end)
test("generator follows charging, perfect, active, recovery, cooldown and ready windows",function()
    local c=config().shield; local s=Shield.New(c)
    assert(Shield.Activate(s,c,function() return true end,true)); assert(s.state=="CHARGING")
    shieldAdvance(s,c,0.15); assert(s.state=="PERFECT_GUARD")
    shieldAdvance(s,c,0.25); assert(s.state=="ACTIVE")
    shieldAdvance(s,c,0.5); assert(s.state=="RECOVERY")
    shieldAdvance(s,c,0.25); assert(s.state=="COOLDOWN")
    shieldAdvance(s,c,4); assert(s.state=="READY")
end)
test("cooldown, deployment lock and insufficient capacitor reject cleanly without consuming",function()
    local c=config(); local s=Shield.New(c.shield); local e=Energy.New(c,24)
    local function spend(cost) return Energy.Spend(e,cost) end
    assert(not Shield.Activate(s,c.shield,spend,true)); near(e.charge,24)
    assert(not Shield.Activate(s,c.shield,spend,false)); near(e.charge,24)
    e=Energy.New(c); assert(Shield.Activate(s,c.shield,spend,true)); local after=e.charge
    assert(not Shield.Activate(s,c.shield,spend,true)); near(e.charge,after)
    Shield.Cancel(s,c.shield); shieldAdvance(s,c.shield,0.5)
    assert(not Shield.Activate(s,c.shield,spend,true)); assert(Shield.Cooldown(s)>4)
end)
test("perfect timing prevents more damage at lower cost than ordinary guard",function()
    local perfect=activated(0.2); local normal=activated(0.5); local early=activated(0.1); local late=activated(1)
    assert(perfect.timing=="PERFECT" and normal.timing=="GUARD")
    assert(perfect.prevented>normal.prevented and perfect.energy<normal.energy)
    assert(early.prevented==0 and late.prevented==0 and perfect.penetrating>0)
end)
test("directional defense rejects rear attacks and follows chassis heading",function()
    local rear=activated(0.2,"laser",1); assert(rear.prevented==0 and rear.timing=="OFF_AXIS")
    local c=config().shield; local s=Shield.New(c); s.state="ACTIVE"
    local r=Shield.Resolve(s,c,{damage=60,category="laser",fromX=-1,fromZ=0},math.pi/2,function(cost)return cost end)
    assert(r.prevented>0)
end)
test("laser, ballistic, plasma and missile defenses differ meaningfully",function()
    local laser=activated(0.5,"laser"); local ballistic=activated(0.5,"ballistic"); local plasma=activated(0.5,"plasma"); local missile=activated(0.5,"missile")
    assert(laser.prevented>ballistic.prevented and ballistic.prevented>plasma.prevented and plasma.prevented>missile.prevented)
end)
test("shield damage and energy exhaustion cap mitigation and force recovery",function()
    local c=config(); local e=Energy.New(c,26); local s=Shield.New(c.shield)
    assert(Shield.Activate(s,c.shield,function(cost)return Energy.Spend(e,cost)end,true)); shieldAdvance(s,c.shield,0.2)
    local r=Shield.Resolve(s,c.shield,{damage=600,category="laser",fromX=0,fromZ=-1},0,function(cost)return Energy.Consume(e,cost,true)end)
    assert(r.prevented<20 and r.penetrating>580 and e.charge==0 and s.state=="RECOVERY")
end)
test("canceling on return/ejection cannot reset cooldown or preserve protection",function()
    local c=config().shield; local s=Shield.New(c)
    Shield.Activate(s,c,function()return true end,true); shieldAdvance(s,c,0.2)
    local untilTime=s.cooldownUntil; Shield.Advance(s,c,0.01,false)
    assert(not Shield.Protects(s) and s.cooldownUntil==untilTime)
    shieldAdvance(s,c,6,false); assert(s.state=="READY")
end)
test("invalid attack categories and nonfinite damage are rejected",function()
    local c=config().shield; local s=Shield.New(c)
    for _,cat in ipairs({"unknown","laser"}) do
        local r=Shield.Resolve(s,c,{damage=if cat=="laser" then 0/0 else 60,category=cat,fromX=0,fromZ=-1},0,function(cost)return cost end)
        assert(r==nil)
    end
end)
test("installed components configure output, capacity and cooling independently",function()
    local c=Config.Build(Chassis.IF42_BASTION,Components.CORE_300,Components.CAP_HIGH_DENSITY,Components.RAD_ADVANCED,Components.SHIELD_PULSE)
    assert(c.output==120 and c.capacity==240 and c.cooling>config().cooling)
end)
test("generator quality improves mitigation without granting immunity",function()
    local function defend(quality)
        local c=table.clone(config().shield); c.quality=quality
        local s=Shield.New(c); s.state="ACTIVE"
        return Shield.Resolve(s,c,{damage=60,category="laser",fromX=0,fromZ=-1},0,function(cost)return cost end)
    end
    local low,high=defend(0.65),defend(1.25)
    assert(high.prevented>low.prevented and high.penetrating>0)
end)
test("continuous requests expire every frame and duplicate categories share one allocation",function()
    local s=Energy.New(config(),0)
    Energy.Request(s,"idle",10); Energy.Request(s,"idle",15); Energy.Advance(s,0.1,true)
    near(s.delivered.idle,25); local consumed=s.ledger.consumed
    Energy.Advance(s,0.1,true); near(s.demand,0); near(s.ledger.consumed,consumed)
end)
test("invalid shield activation costs cannot debit or grant energy",function()
    for _,cost in ipairs({-25,0,0/0,math.huge}) do
        local c=table.clone(config().shield); c.activationCost=cost
        local s=Shield.New(c); local e=Energy.New(config())
        assert(not Shield.Activate(s,c,function(amount)return Energy.Spend(e,amount)end,true))
        near(e.charge,160); assert(s.state=="READY")
    end
end)
test("damage resolution respects exact charging and perfect-window boundaries",function()
    assert(activated(0.149).prevented==0)
    assert(activated(0.15).timing=="PERFECT")
    assert(activated(0.4).timing=="GUARD")
end)
test("sprint gait alternates grounded legs and stays within mechanical reach",function()
    local Gait=require("../src/ReplicatedStorage/IronframeShared/MechGait")
    local p=Chassis.IF42_BASTION.gait; local s=Gait.New(); local last=nil; local steps=0
    for i=1,1200 do
        local speed=25.6*math.min(1,i/240)
        local _,events=Gait.Update(s,1/120,speed,0,p)
        assert(s.legs.L.state=="stance" or s.legs.R.state=="stance")
        for _,leg in pairs(s.legs) do assert(math.abs(leg.f)<=p.reach+1e-6) end
        for _,event in ipairs(events) do assert(event.leg~=last); last=event.leg; steps+=1 end
    end
    assert(steps>20 and s.slip<0.5,"sprint gait slipped "..s.slip)
end)
print(string.format("\n%d passed, %d failed",passed,failed))
if failed>0 then error("energy/shield tests failed") end
