local Config=require("../src/ReplicatedStorage/IronframeShared/WeaponPresentation")
local Motion=require("../src/ReplicatedStorage/IronframeShared/WeaponMotion")
local Components=require("../src/ReplicatedStorage/IronframeShared/ComponentRegistry")
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed+=1;print("  ok   "..name) else failed+=1;print("  FAIL "..name..": "..tostring(err)) end
end
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a).." vs "..tostring(b)) end
test("presentation keeps requested weapon balance",function()
    local l,m=Components.W_LASER_RIFLE.combat,Components.W_MACHINE_GUN.combat
    assert(l.energy==24 and l.interval==0.25 and l.damage==25 and l.heat==6 and l.range==450)
    assert(m.energy==0.6 and m.interval==0.1 and m.magazine==60 and m.reload==3 and m.damage==8 and m.heat==0.12 and m.range==350)
end)
test("casings have bounded lifetime, distance and count",function()
    local c=Config.casing
    assert(c.limit>=25 and c.limit<=30 and c.lifetime>=2 and c.lifetime<=3)
    assert(c.distance>0 and c.distance<Config.effectDistance and c.fadeTime<c.lifetime)
    assert(c.length<0.7 and c.diameter<0.25 and c.gravityScale==1)
end)
test("port is on receiver well behind the muzzle",function()
    local c=Config.casing
    assert(c.portSide>0.5 and math.abs(c.portZ)<1.5)
    assert(Components.W_MACHINE_GUN.combat.muzzle+Config.casing.portZ>4)
end)
test("recoil attacks briefly and recovers without drift or overextension",function()
    for _,spec in pairs(Config.recoil) do
        near(Motion.Recoil(-1,spec),0);near(Motion.Recoil(0,spec),0)
        near(Motion.Recoil(spec.kickTime,spec),1);near(Motion.Recoil(spec.recoverTime,spec),0)
        local previous=1
        for i=0,100 do
            local t=spec.kickTime+(spec.recoverTime-spec.kickTime)*i/100
            local v=Motion.Recoil(t,spec)
            assert(v>=0 and v<=previous+1e-9);previous=v
        end
        assert(spec.distance<0.3 and spec.pitch<0.01)
    end
end)
test("floor bounce reverses normal motion and damps slide",function()
    local c=Config.casing
    local x,y,z=Motion.Bounce(10,-20,5,0,1,0,c.restitution,c.friction)
    near(x,10*c.friction);near(y,20*c.restitution);near(z,5*c.friction)
    assert(x*x+y*y+z*z<10*10+20*20+5*5)
end)
test("oblique surface bounces never add kinetic energy",function()
    for i=0,90 do
        local a=math.rad(i)
        local nx,ny=math.cos(a),math.sin(a)
        local x,y,z=Motion.Bounce(-8,-17,4,nx,ny,0,Config.casing.restitution,Config.casing.friction)
        assert(x*x+y*y+z*z<=8*8+17*17+4*4)
        assert(x*nx+y*ny>=0)
    end
end)
test("voice budget is fixed and laser has no unrelated fallback",function()
    assert(Config.audio.dischargeVoices+Config.audio.detailVoices<=12)
    assert(Config.audio.laserDuration>=0.2 and Config.audio.laserDuration<=0.4)
    assert(Config.audio.pitchVariation>0 and Config.audio.pitchVariation<=0.04)
    assert(Config.audio.laserAssetId=="" or string.match(Config.audio.laserAssetId,"^rbxassetid://%d+$"))
    assert(Components.W_LASER_RIFLE.combat.sound==nil,"old UI beep remains in weapon definition")
end)
print(string.format("\n%d passed, %d failed",passed,failed))
assert(failed==0,"presentation regressions failed")
