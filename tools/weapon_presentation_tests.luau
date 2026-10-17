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
        local heavy=spec==Config.recoil.W_HMG_MAULER
        assert(spec.distance<(if heavy then 0.75 else 0.3) and spec.pitch<(if heavy then 0.02 else 0.01))
        assert((spec.torso or 0)<=0.005 and (spec.barrel or 0)<=spec.distance)
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
test("m08d: heavy recoil is stronger than MG-9 but recovers before the next 3 Hz shot",function()
    local h,m=Config.recoil.W_HMG_MAULER,Config.recoil.W_MACHINE_GUN
    assert(h.distance>m.distance*2 and h.pitch>m.pitch and h.recoverTime<=1/3-0.05)
    near(Motion.Recoil(h.recoverTime,h),0)
end)
test("m08d: heavy casing is larger, bounded and has its own port, cap and cockpit margin",function()
    local c,b=Config.casingProfiles.W_HMG_MAULER,Config.casing
    assert(c.length>b.length*2 and c.diameter>b.diameter*2 and c.lift>b.lift and c.speed>b.speed)
    assert(c.lifetime<=3.2 and c.typeLimit>=6 and c.typeLimit<b.limit and c.protect>0.4)
    assert(c.portSide>0.5 and Components.W_HMG_MAULER.combat.muzzle+c.portZ>4 and #c.boltSize==3)
    assert(Config.audio.maulerAssetId=="" or string.match(Config.audio.maulerAssetId,"^rbxassetid://%d+$"))
    assert(Config.audio.maulerDuration>=0.4 and Config.audio.maulerDuration<=0.8)
    assert(Config.audio.dischargeVoices+Config.audio.detailVoices<=12)
    assert(Config.audio.laserAssetId=="rbxassetid://123083870222487")
end)
test("m08d: heavy effect budgets stay cosmetic and short",function()
    local h=Config.heavy.W_HMG_MAULER
    assert(h.life<=0.75 and h.fragments<=8 and h.sparks<=20 and h.smoke<=8 and h.cockpitLight<1 and h.blastTime<0.15)
end)
print(string.format("\n%d passed, %d failed",passed,failed))
assert(failed==0,"presentation regressions failed")
