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
local function new()
    local cfg = Config.Build(Chassis.IF42_BASTION,C.CORE_220,C.CAP_STANDARD,C.RAD_STANDARD,C.SHIELD_PULSE)
    local e = E.New(cfg)
    local w = W.New({left_arm="W_LASER_RIFLE",right_arm="W_MACHINE_GUN",left_torso="W_LASER_RIFLE",left_shoulder="W_MISSILE_POD"},C)
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
local function scenario(socket,propulsion,sprint,shield)
    local w,e,cfg=new();local sh=Shield.New(cfg.shield)
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
print(string.format("\n%d passed, %d failed",passed,failed))
assert(failed==0,"weapon regressions failed")
