-- Presentation consumes only server-confirmed shots. It never predicts payment, ammunition or hits.
local Shared=game.ReplicatedStorage.IronframeShared
local Components=require(Shared.ComponentRegistry)
local Config=require(Shared.WeaponPresentation)
local Casings=require(script.Parent.WeaponCasings)
local Audio=require(script.Parent.WeaponAudio)
local Effects={}
Effects.__index=Effects
local function part(name,size,color,parent)
    local p=Instance.new("Part")
    p.Name,p.Size,p.Color,p.Material=name,size,color,Enum.Material.Neon
    p.Anchored,p.CanCollide,p.CanTouch,p.CanQuery,p.CastShadow=true,false,false,false,false
    p.Parent=parent
    return p
end
function Effects.New(root,animator)
    local self=setmetatable({root=root,entries={},random=Random.new(),stats={shots=0,culled=0,peak=0,stepMs=0,worstMs=0}},Effects)
    self.audio=Audio.New(root)
    self.casings=Casings.New(root,animator,self.audio)
    return self
end
function Effects:Remove(index)
    self.entries[index].folder:Destroy()
    table.remove(self.entries,index)
end
function Effects:Emit(model,socket,id,origin,endpoint,normal,damage)
    local spec=Components[id] and Components[id].combat
    if not spec or not model.Parent or model:GetAttribute("Deployment")~="ACTIVE" or model:GetAttribute("State")~="OPERATIONAL" then return end
    if (workspace.CurrentCamera.CFrame.Position-origin).Magnitude>Config.effectDistance then self.stats.culled+=1;return end
    if #self.entries>=Config.effectLimit then self:Remove(1) end
    self.stats.shots+=1
    local folder=Instance.new("Folder")
    folder.Name,folder.Parent=spec.effect,self.root
    local laser=spec.category=="laser"
    local color=if laser then Color3.fromRGB(72,208,255) else Color3.fromRGB(255,160,58)
    local muzzle=model:FindFirstChild("Weapon_"..socket.."_Emitter")
    local start=muzzle and muzzle.Position or origin
    local cf=CFrame.lookAt(start,endpoint)
    local beam=part(if laser then "LaserCore" else "Tracer",Vector3.one*0.045,if laser then Color3.fromRGB(228,252,255) else Color3.fromRGB(255,212,120),folder)
    -- Initialize all geometry before the first render, avoiding a one-frame flash at the world origin.
    beam.CFrame=CFrame.lookAt((start+endpoint)/2,endpoint)
    beam.Size=Vector3.new(0.045,0.045,math.max((endpoint-start).Magnitude,0.01))
    local halo=laser and part("BeamHalo",Vector3.one*0.16,color,folder) or nil
    if halo then halo.CFrame=beam.CFrame;halo.Size=Vector3.new(0.16,0.16,beam.Size.Z);halo.Transparency=0.7 end
    local variation=self.random:NextNumber(0.8,1.18)
    local flash=part("MuzzleFlash",if laser then Vector3.one*0.45 else Vector3.new(0.25,0.25,0.65)*variation,color,folder)
    flash.Shape,flash.CFrame=Enum.PartType.Ball,cf
    local light=Instance.new("PointLight")
    light.Color,light.Range,light.Brightness,light.Parent=color,if laser then 8 else 5,if laser then 1.4 else 0.6,flash
    local impact=part("ContactFlash",Vector3.one*(if damage>0 then 0.65 else 0.3),if damage>0 then Color3.fromRGB(226,247,255) else color,folder)
    impact.Shape,impact.CFrame=Enum.PartType.Ball,CFrame.lookAt(endpoint,endpoint+normal)
    local sparks=Instance.new("ParticleEmitter")
    sparks.Name,sparks.Texture="ResidualDischarge","rbxasset://textures/particles/sparkles_main.dds"
    sparks.Color,sparks.Lifetime,sparks.Speed=ColorSequence.new(color),NumberRange.new(0.09,if laser then 0.28 else 0.16),NumberRange.new(3,if laser then 10 else 14)
    sparks.Rate,sparks.SpreadAngle,sparks.LightEmission=0,Vector2.new(70,70),0.8
    sparks.EmissionDirection=Enum.NormalId.Front
    sparks.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,0.13),NumberSequenceKeypoint.new(1,0)})
    sparks.Parent=impact;sparks:Emit(if laser then 8 else 4)
    local portCarrier=model:FindFirstChild("Weapon_"..socket.."_EjectionPort")
    local port=portCarrier and portCarrier:FindFirstChild("EjectionPort")
    local portFlash
    if not laser then
        local attachment=Instance.new("Attachment")
        attachment.Parent=flash
        local smoke=Instance.new("ParticleEmitter")
        smoke.Name,smoke.Texture="DirectionalSmoke","rbxasset://textures/particles/smoke_main.dds"
        smoke.Color,smoke.LightEmission=ColorSequence.new(Color3.fromRGB(105,110,107)),0
        smoke.EmissionDirection,smoke.SpreadAngle=Enum.NormalId.Front,Vector2.new(12,12)
        smoke.Rate,smoke.Speed,smoke.Drag=0,NumberRange.new(4,7),5
        smoke.Lifetime=NumberRange.new(0.16,0.32)
        smoke.Acceleration=Vector3.new(0,3,0)
        smoke.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,0.15),NumberSequenceKeypoint.new(1,0.7)})
        smoke.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,0.7),NumberSequenceKeypoint.new(1,1)})
        smoke.Parent=attachment;smoke:Emit(2)
        if port then
            portFlash=part("PortFlash",Vector3.one*0.12,Color3.fromRGB(219,130,53),folder)
            portFlash.Position=port.WorldPosition
            self.audio:Play("receiver",port.WorldPosition,model,socket)
        end
        self.casings:Emit(model,socket)
    end
    self.audio:Play(if laser then "laser" else "machine",start,model,socket)
    model:SetAttribute("WeaponVisualSocket",socket)
    model:SetAttribute("WeaponVisualShotAt",workspace:GetServerTimeNow())
    table.insert(self.entries,{folder=folder,owner=model,socket=socket,muzzle=muzzle,origin=origin,endpoint=endpoint,beam=beam,halo=halo,
        flash=flash,impact=impact,port=port,portFlash=portFlash,laser=laser,variation=variation,born=os.clock(),confirmed=damage>0})
    self.stats.peak=math.max(self.stats.peak,#self.entries)
end
function Effects:Step(dt)
    local started,now=os.clock(),os.clock()
    for i=#self.entries,1,-1 do
        local e=self.entries[i]
        local age=now-e.born
        if age>Config.effectLifetime or not e.owner.Parent or e.owner:GetAttribute("Deployment")~="ACTIVE" or e.owner:GetAttribute("State")~="OPERATIONAL" or e.owner:GetAttribute("WeaponSocket")~=e.socket then
            self:Remove(i);continue
        end
        local origin=e.muzzle and e.muzzle.Parent and e.muzzle.Position or e.origin
        local length=(e.endpoint-origin).Magnitude
        local cf=CFrame.lookAt((origin+e.endpoint)/2,e.endpoint)
        if e.laser then
            e.beam.Size,e.beam.CFrame=Vector3.new(0.045,0.045,math.max(length,0.01)),cf
            e.beam.Transparency=math.clamp((age-0.025)/0.11,0,1)
            e.halo.Size,e.halo.CFrame=Vector3.new(0.16,0.16,math.max(length,0.01)),cf
            e.halo.Transparency=math.clamp(0.7+age/0.14*0.3,0,1)
            local charge=math.min(1,age/0.018)
            e.flash.Size=Vector3.one*(0.3+0.35*charge)*math.max(0.12,1-age/0.12)
        else
            -- A short luminous tracer segment, cosmetic only: authoritative damage already resolved immediately.
            local center=origin:Lerp(e.endpoint,math.clamp(age/0.035,0,1))
            local tracerLength=math.min(12,length)
            e.beam.Size,e.beam.CFrame=Vector3.new(0.055,0.055,math.max(tracerLength,0.01)),CFrame.lookAt(center,e.endpoint+(e.endpoint-origin).Unit)
            e.beam.Transparency=math.clamp(age/0.055,0,1)
            if e.portFlash then e.portFlash.Position=e.port.WorldPosition;e.portFlash.Transparency=math.clamp(age/0.04,0,1) end
        end
        e.flash.CFrame=CFrame.lookAt(origin,e.endpoint)
        e.flash.Transparency=math.clamp(age/(if e.laser then 0.12 else 0.045),0,1)
        e.flash.PointLight.Brightness=math.max(0,(if e.laser then 1.4 else 0.6)*(1-age/0.09))
        e.impact.Transparency=math.clamp(age/(if e.laser then 0.22 else 0.12),0,1)
        e.impact.Size=Vector3.one*((if e.confirmed then 0.65 else 0.3)+age*(if e.laser then 2 else 1))
    end
    self.casings:Step(dt)
    self.audio:Step()
    local elapsed=(os.clock()-started)*1000
    self.stats.stepMs+=(elapsed-self.stats.stepMs)*0.05
    self.stats.worstMs=math.max(self.stats.worstMs,elapsed)
end
function Effects:Clear()
    for i=#self.entries,1,-1 do self:Remove(i) end
    self.casings:Clear();self.audio:Clear()
end
function Effects:Report()
    local result=table.clone(self.stats)
    result.active=#self.entries;result.casings=self.casings:Report();result.audio=self.audio:Report()
    result.instances=#self.root:GetDescendants()
    return result
end
return Effects
