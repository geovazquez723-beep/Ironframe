local W = require("../src/ReplicatedStorage/IronframeShared/WeaponState")
local T = require("../src/ReplicatedStorage/IronframeShared/TargetState")
local E = require("../src/ReplicatedStorage/IronframeShared/Energy")
local C = require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local Config = require("../src/ReplicatedStorage/IronframeShared/EnergyConfig")
local Chassis = require("../src/ReplicatedStorage/IronframeShared/ChassisRegistry")
local Shield = require("../src/ReplicatedStorage/IronframeShared/PulseShield")
local passed, failed = 0,0
local function test(name,fn)
    local ok,err = pcall(fn)
    if ok then passed+=1;print("  ok   "..name) else failed+=1;print("  FAIL "..name..": "..tostring(err)) end
end
local function new(mounts)
    local cfg = Config.Build(Chassis.IF42_BASTION,C.CORE_220,C.CAP_STANDARD,C.RAD_STANDARD,C.SHIELD_PULSE)
    local e = E.New(cfg)
    local w = W.New(mounts or {left_arm="W_LASER_RIFLE",right_arm="W_MACHINE_GUN",left_torso="W_LASER_RIFLE",left_shoulder="W_MISSILE_POD"},C)
    return w,e,cfg
end
local function pay(e)
    return function(cost,heat)
        if E.Consume(e,cost,false,0) ~= cost then return false end
        e.thermal = math.clamp(e.thermal+heat,0,e.config.thermalMaximum)
        return true
    end
end
local function near(a,b) assert(math.abs(a-b)<1e-5,tostring(a).." vs "..tostring(b)) end
test("only installed compatible implemented hardpoints fire",function()
    local w,e=new()
    for _,socket in ipairs({"left_torso","left_shoulder","right_shoulder","missing"}) do assert(not W.Fire(w,socket,0,true,true,pay(e))) end
    near(e.charge,160)
    assert(W.Fire(w,"left_arm",0,true,true,pay(e)))
end)
test("one laser pulse atomically spends cost and adds defined heat",function()
    local w,e=new();assert(W.Fire(w,"left_arm",0,true,true,pay(e)))
    near(e.charge,136);near(e.ledger.consumed,24);near(e.thermal,6)
end)
test("spam cannot bypass cadence or debit rejected shots",function()
    local w,e=new();assert(W.Fire(w,"right_arm",0,true,true,pay(e)))
    for i=1,1000 do assert(not W.Fire(w,"right_arm",0.099,true,true,pay(e))) end
    near(e.charge,159.4);assert(w.slots.right_arm.ammo==59)
    assert(W.Fire(w,"right_arm",0.1,true,true,pay(e)))
end)
test("invalid aim and garage/ejection/recovery consume no resources",function()
    local w,e=new()
    assert(not W.Fire(w,"left_arm",0,true,false,pay(e)))
    for i=1,5 do assert(not W.Fire(w,"left_arm",i,false,true,pay(e))) end
    near(e.charge,160);near(e.thermal,0);assert(w.shots==0)
end)
test("unfunded pulses do not consume partial energy heat or ammo",function()
    local w,e=new(); e.charge=23
    assert(not W.Fire(w,"left_arm",0,true,true,pay(e)))
    near(e.charge,23);near(e.thermal,0);near(e.ledger.consumed,0)
    assert(w.reason=="ENERGY LOW")
end)
test("magazine depletion triggers reload and cannot fire early",function()
    local w,e=new()
    for i=1,60 do
        E.Advance(e,0.1,true)
        assert(W.Fire(w,"right_arm",i*0.11,true,true,pay(e)))
    end
    assert(w.slots.right_arm.ammo==0)
    assert(not W.Fire(w,"right_arm",7,true,true,pay(e)))
    assert(w.reason=="RELOADING")
    W.Advance(w,9.99);assert(w.slots.right_arm.ammo==0)
    W.Advance(w,10);assert(w.slots.right_arm.ammo==60)
    assert(W.Fire(w,"right_arm",10,true,true,pay(e)))
end)
test("manual reload cannot restart timer and maintains independent magazines",function()
    local w,e=new();assert(W.Fire(w,"right_arm",0,true,true,pay(e)))
    assert(W.Reload(w,"right_arm",0,true));assert(not W.Reload(w,"right_arm",1,true))
    assert(not W.Reload(w,"left_arm",1,true));W.Advance(w,3)
    assert(w.slots.right_arm.ammo==60)
    assert(not W.Reload(w,"right_arm",4,false))
end)
test("laser and ballistic armor resolve distinct server parameters",function()
    local t=T.New("PLATE")
    near(T.Hit(t,"laser",25,0),25);near(T.Hit(t,"ballistic",8,1),5.2)
    local a=T.New("ABLATIVE")
    near(T.Hit(a,"laser",25,0),16.25);near(T.Hit(a,"ballistic",8,1),8)
    near(T.Hit(a,"plasma",100,2),0)
end)
test("target overkill is clamped and destroyed targets repair after eight seconds",function()
    local t=T.New("STANDARD");near(T.Hit(t,"laser",1000,1),600)
    near(T.Hit(t,"laser",25,2),0);assert(not T.Step(t,8.99));assert(T.Step(t,9))
    assert(t.health==600 and t.hits==0 and t.damage==0 and t.resets==1)
end)
test("damaged targets repair after fifteen seconds idle",function()
    local t=T.New("STANDARD");T.Hit(t,"ballistic",8,1)
    assert(not T.Step(t,15.99));assert(T.Step(t,16))
end)
local function scenario(socket,propulsion,sprint,shield,mounts)
    local w,e,cfg=new(mounts);local sh=Shield.New(cfg.shield)
    local target=T.New("STANDARD")
    for i=0,1199 do
        local now=i/60
        if shield and i%240==0 then Shield.Activate(sh,cfg.shield,function(cost) return E.Spend(e,cost) end,true) end
        Shield.Advance(sh,cfg.shield,1/60,true)
        E.Request(e,"idle",cfg.movement.idle)
        E.Request(e,"propulsion",propulsion)
        E.Request(e,"sprint",sprint)
        if Shield.Protects(sh) then E.Request(e,"shield",cfg.shield.activeDrain) end
        E.Advance(e,1/60,true);W.Advance(w,now)
        if W.Fire(w,socket,now,true,true,pay(e)) then T.Hit(target,w.slots[socket].spec.category,w.slots[socket].spec.damage,now) end
        assert(e.charge>=0 and e.tokens>=0)
    end
    near(e.ledger.initial+e.ledger.generated,e.charge+e.ledger.consumed+e.ledger.loss+e.ledger.wasted)
    return w.shots,e
end
test("sprint and shield constrain laser while MG remains cheaper and more available",function()
    local idle=scenario("left_arm",0,0,false)
    local sprint=scenario("left_arm",48,90,false)
    local guarded=scenario("left_arm",48,90,true)
    local mg=scenario("right_arm",48,90,true)
    print(string.format("  20s shots idle=%d sprint=%d sprint+shield=%d MG=%d",idle,sprint,guarded,mg))
    assert(idle>sprint and sprint>guarded and mg>guarded*4)
end)
test("sustained laser thermal load reduces reactor efficiency",function()
    local _,e=scenario("left_arm",0,0,false)
    assert(e.thermal>40 and e.output<80 and e.efficiency<0.9)
end)
test("exhaustion never grants free pulses and retains basic drive",function()
    local w,e,cfg=new();e.charge=0;e.tokens=0
    assert(not W.Fire(w,"left_arm",0,true,true,pay(e)))
    E.Request(e,"idle",cfg.movement.idle);E.Request(e,"propulsion",40);E.Advance(e,1/60,true)
    local base=E.Performance(e,40,90);assert(base>=0.65)
    assert(not W.Fire(w,"left_arm",1,true,true,pay(e)))
end)

local HEAVY={left_arm="W_LASER_RIFLE",right_arm="W_HMG_MAULER",left_shoulder="W_MACHINE_GUN",right_shoulder="W_LASER_RIFLE"}
test("m08d: HMG-20 definition is server data and leaves MG-9/LR-12 untouched",function()
    local h,m,l=C.W_HMG_MAULER.combat,C.W_MACHINE_GUN.combat,C.W_LASER_RIFLE.combat
    near(h.interval,1/3);assert(h.damage==25 and h.energy==2.5 and h.magazine==24 and h.reload==3.8 and h.ammoPerShot==1 and h.category=="ballistic")
    assert(h.damage/m.damage>=3 and h.damage/m.damage<=4,"3-4x MG-9 per-hit damage")
    assert(h.energy>m.energy and h.energy<l.energy,"per-shot energy between MG-9 and LR-12")
    assert(h.energy/h.interval<l.energy/l.interval and h.energy/h.interval>m.energy/m.interval)
    assert(m.damage==8 and m.energy==0.6 and m.interval==0.1 and m.magazine==60 and m.reload==3 and m.heat==0.12)
    assert(l.damage==25 and l.energy==24 and l.interval==0.25 and l.heat==6)
    assert(h.hardpoints.left_arm and h.hardpoints.right_arm and not h.hardpoints.left_shoulder and not h.hardpoints.right_torso)
end)
test("m08d: Mauler cadence is 3 rounds/s with exact payment, ammo and 3.8s reload",function()
    local w,e=new(HEAVY);assert(W.Fire(w,"right_arm",0,true,true,pay(e)))
    near(e.charge,157.5);near(e.thermal,0.9);assert(w.slots.right_arm.ammo==23)
    for i=1,500 do assert(not W.Fire(w,"right_arm",0.33,true,true,pay(e))) end
    near(e.charge,157.5);assert(w.reason=="COOLDOWN")
    assert(W.Fire(w,"right_arm",1/3,true,true,pay(e)))
    local t=1/3
    for i=3,24 do t+=1/3;E.Advance(e,1/3,true);assert(W.Fire(w,"right_arm",t,true,true,pay(e)),"shot "..i) end
    assert(w.slots.right_arm.ammo==0 and not W.Fire(w,"right_arm",t+1/3,true,true,pay(e)) and w.reason=="RELOADING")
    local started=t+1/3
    W.Advance(w,started+3.79);assert(w.slots.right_arm.ammo==0)
    W.Advance(w,started+3.8);assert(w.slots.right_arm.ammo==24)
end)
test("m08d: unfunded Mauler shots spend nothing and weapon swaps keep independent magazines",function()
    local w,e=new(HEAVY);e.charge=2.4
    assert(not W.Fire(w,"right_arm",0,true,true,pay(e)));near(e.charge,2.4);near(e.thermal,0);assert(w.slots.right_arm.ammo==24)
    e.charge=160;assert(W.Fire(w,"right_arm",1,true,true,pay(e)));assert(W.Fire(w,"left_shoulder",1,true,true,pay(e)))
    assert(W.Fire(w,"left_arm",1,true,true,pay(e)))
    assert(w.slots.right_arm.ammo==23 and w.slots.left_shoulder.ammo==59)
    near(e.charge,160-2.5-0.6-24)
end)
test("m08d: Mauler is a different tradeoff, not a strictly better MG-9",function()
    local ih=scenario("right_arm",0,0,false,HEAVY);local im=scenario("right_arm",0,0,false)
    local sh=scenario("right_arm",48,90,false,HEAVY);local sm=scenario("right_arm",48,90,false)
    local gh=scenario("right_arm",48,90,true,HEAVY);local gm=scenario("right_arm",48,90,true)
    local lh=scenario("left_arm",48,90,true,HEAVY)
    print(string.format("  20s shots idle MG=%d HMG=%d | sprint MG=%d HMG=%d | sprint+shield MG=%d HMG=%d LR=%d",im,ih,sm,sh,gm,gh,lh))
    local dh,dm=ih*25,im*8
    print(string.format("  20s idle damage MG=%d HMG=%d",dm,dh))
    assert(ih<im/2.5,"far fewer rounds") assert(dh<dm*1.15,"not strictly higher sustained damage than MG-9")
    assert(gh>lh,"Mauler remains more available than the laser while sprinting under shield")
    assert(sh>=1 and gh>=1)
end)
test("m08d: Mauler is arms-only (size 3) and AUTOCANNON fits mass/power without touching other presets",function()
    local L=require("../src/ReplicatedStorage/IronframeShared/Loadouts")
    local hard=Chassis.IF42_BASTION.hardpoints
    local function fits(socket,id)
        local c,h=C[id],hard[socket]
        return c.size<=h.size and table.find(h.families,c.family)~=nil
    end
    assert(fits("left_arm","W_HMG_MAULER") and fits("right_arm","W_HMG_MAULER"))
    for _,socket in ipairs({"left_shoulder","right_shoulder","left_torso","right_torso"}) do assert(not fits(socket,"W_HMG_MAULER"),socket) end
    local a=L.presets.AUTOCANNON;assert(a.chassisId=="IF42_BASTION" and a.mounts.right_arm=="W_HMG_MAULER")
    local mass,power=Chassis.IF42_BASTION.dryMass+C[a.systems.reactor].mass+C[a.systems.cooling].mass+C[a.systems.armor].mass,0
    for socket,id in pairs(a.mounts) do assert(fits(socket,id),socket);mass+=C[id].mass;power+=C[id].powerDraw end
    assert(mass<=Chassis.IF42_BASTION.massLimit,"mass "..mass);assert(power<=C[a.systems.reactor].powerOutput)
    assert(L.presets.BALANCED.mounts.right_arm=="W_MACHINE_GUN" and L.presets.BALANCED.mounts.left_arm=="W_LASER_RIFLE")
    for _,id in ipairs({"BALANCED","ENERGY","MISSILE"}) do assert(table.find(L.order,id)) end
end)
test("m08d: phase lock holds 3.0 shots/s at 60 Hz without bursts, MG-9 cadence unchanged",function()
    local function rate(socket,mounts,seconds)
        local w,e=new(mounts);local n=0
        for i=0,seconds*60-1 do
            E.Advance(e,1/60,true);W.Advance(w,i/60);e.charge=160;e.tokens=e.config.burstLimit
            if W.Fire(w,socket,i/60,true,true,pay(e)) then n+=1 end
            if w.slots[socket].ammo==0 then w.slots[socket].ammo=w.slots[socket].spec.magazine;w.slots[socket].reloadAt=nil end
        end
        return n/seconds
    end
    local heavy=rate("right_arm",HEAVY,10);local mg=rate("right_arm",nil,10)
    print(string.format("  60 Hz held-trigger rates: HMG=%.3f/s MG=%.3f/s",heavy,mg))
    assert(heavy>=2.95 and heavy<=3.05,heavy)
    assert(mg>=9.5 and mg<=10,"MG-9 cadence must be unchanged: "..mg)
    -- A long stall must not bank shots: after a 5 s pause exactly one shot is allowed, then the 1/3 s spacing resumes.
    local w,e=new(HEAVY);assert(W.Fire(w,"right_arm",0,true,true,pay(e)))
    assert(W.Fire(w,"right_arm",5,true,true,pay(e)) and not W.Fire(w,"right_arm",5.1,true,true,pay(e)))
    assert(W.Fire(w,"right_arm",5+1/3+1e-9,true,true,pay(e)))
end)
print(string.format("\n%d passed, %d failed",passed,failed))
assert(failed==0,"weapon regressions failed")
