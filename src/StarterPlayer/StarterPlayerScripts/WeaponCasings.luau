-- Client-only brass physics, integrated with bounded raycasts. Anchored cosmetics cannot push pilots/chassis or enter hit queries.
local Players = game:GetService("Players")
local Shared = game.ReplicatedStorage.IronframeShared
local Config = require(Shared.WeaponPresentation).casing
local Cockpit = require(Shared.CockpitConfig)
local Motion = require(Shared.WeaponMotion)
local Casings = {}
Casings.__index = Casings
function Casings.New(root, animator, audio)
    local folder = Instance.new("Folder")
    folder.Name,folder.Parent="Brass",root
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    return setmetatable({folder=folder,root=root,animator=animator,audio=audio,entries={},random=Random.new(),params=params,filterAt=-100,
        parts={},frames={},stats={spawned=0,peak=0,recycled=0,culled=0,bounces=0,cockpitSuppressed=0,missingPorts=0}},Casings)
end
function Casings:Protected(position)
    local folder=workspace:FindFirstChild("IronframeMechs")
    local model=folder and folder:FindFirstChild(tostring(Players.LocalPlayer.UserId))
    local torso=model and self.animator.TorsoCF(model)
    if not torso then return false end
    local p=torso:PointToObjectSpace(position)
    local lo,hi=Cockpit.HIDE_MIN,Cockpit.HIDE_MAX
    local margin=0.4 -- includes the casing radius/length; protect the enclosure in both camera modes
    return p.X>lo.X-margin and p.X<hi.X+margin and p.Y>lo.Y-margin and p.Y<hi.Y+margin and p.Z>lo.Z-margin and p.Z<hi.Z+margin
end
function Casings:Remove(index)
    self.entries[index].model:Destroy()
    table.remove(self.entries,index)
end
function Casings:Emit(model,socket)
    local camera=workspace.CurrentCamera
    local carrier=model:FindFirstChild("Weapon_"..socket.."_EjectionPort")
    local port=carrier and carrier:FindFirstChild("EjectionPort")
    if not port then self.stats.missingPorts+=1;return end
    local cf=port.WorldCFrame
    if (camera.CFrame.Position-cf.Position).Magnitude>Config.distance then self.stats.culled+=1;return end
    if self:Protected(cf.Position) then self.stats.cockpitSuppressed+=1;return end
    if #self.entries>=Config.limit then self:Remove(1);self.stats.recycled+=1 end
    local brass=Instance.new("Model")
    brass.Name="SpentMG9Case"
    local pieces={}
    local function piece(name,length,diameter,x,color)
        local p=Instance.new("Part")
        p.Name,p.Shape,p.Size=name,Enum.PartType.Cylinder,Vector3.new(length,diameter,diameter)
        p.Material,p.Color=Enum.Material.Metal,color
        p.Anchored,p.CanCollide,p.CanQuery,p.CanTouch,p.CastShadow=true,false,false,false,false
        p:SetAttribute("CosmeticCasing",true)
        p.CFrame=cf*CFrame.new(x,0,0)
        p.Parent=brass
        table.insert(pieces,{part=p,offset=CFrame.new(x,0,0)})
    end
    piece("BrassWall",Config.length,Config.diameter,0,Color3.fromRGB(164,128,57))
    piece("RolledRim",0.035,Config.diameter*1.15,-Config.length/2,Color3.fromRGB(191,151,71))
    piece("DarkHollowMouth",0.012,Config.diameter*0.72,Config.length/2+0.006,Color3.fromRGB(25,23,18))
    brass.Parent=self.folder
    local r=self.random
    local base=self.animator.ChassisCF(model)
    local inherited=base and base.LookVector*(model:GetAttribute("DriveSpeed") or 0) or Vector3.zero
    local velocity=cf.LookVector*r:NextNumber(Config.speed*0.85,Config.speed*1.15)+Vector3.yAxis*Config.lift+cf.RightVector*r:NextNumber(-1,1)+inherited
    table.insert(self.entries,{model=brass,owner=model,socket=socket,pieces=pieces,position=cf.Position,rotation=cf.Rotation,
        velocity=velocity,spin=Vector3.new(r:NextNumber(10,22),r:NextNumber(-16,16),r:NextNumber(8,18)),born=os.clock(),bounces=0,settled=false})
    self.stats.spawned+=1;self.stats.peak=math.max(self.stats.peak,#self.entries)
end
function Casings:Step(dt)
    local now=os.clock()
    if now-self.filterAt>0.5 then
        local ignore={self.root}
        local mechs=workspace:FindFirstChild("IronframeMechs")
        if mechs then table.insert(ignore,mechs) end
        local cockpit=workspace:FindFirstChild("IronframeCockpitClient")
        if cockpit then table.insert(ignore,cockpit) end
        for _,player in ipairs(Players:GetPlayers()) do if player.Character then table.insert(ignore,player.Character) end end
        self.params.FilterDescendantsInstances=ignore;self.filterAt=now
    end
    table.clear(self.parts);table.clear(self.frames)
    local h=math.min(dt,0.05)
    for i=#self.entries,1,-1 do
        local e=self.entries[i]
        local age=now-e.born
        if age>=Config.lifetime or not e.owner.Parent or e.owner:GetAttribute("State")~="OPERATIONAL" or e.owner:GetAttribute("Deployment")~="ACTIVE" or e.owner:GetAttribute("WeaponSocket")~=e.socket then
            self:Remove(i);continue
        end
        if not e.settled then
            local nextVelocity=e.velocity-Vector3.yAxis*(workspace.Gravity*Config.gravityScale*h)
            local delta=(e.velocity+nextVelocity)*0.5*h
            local hit=delta.Magnitude>1e-5 and workspace:Raycast(e.position,delta,self.params) or nil
            if hit then
                e.position=hit.Position+hit.Normal*0.11
                local x,y,z=Motion.Bounce(nextVelocity.X,nextVelocity.Y,nextVelocity.Z,hit.Normal.X,hit.Normal.Y,hit.Normal.Z,Config.restitution,Config.friction)
                e.velocity=Vector3.new(x,y,z);e.spin*=0.55;e.bounces+=1;self.stats.bounces+=1
                if e.bounces==1 and self.audio then self.audio:Play("casing",e.position,e.owner,e.socket) end
                if e.bounces>=Config.maxBounces or e.velocity.Magnitude<2 then e.settled=true end
            else e.position+=delta;e.velocity=nextVelocity end
            e.rotation*=CFrame.Angles(e.spin.X*h,e.spin.Y*h,e.spin.Z*h)
        end
        if self:Protected(e.position) then self.stats.cockpitSuppressed+=1;self:Remove(i);continue end
        local fade=math.clamp((age-(Config.lifetime-Config.fadeTime))/Config.fadeTime,0,1)
        local cf=CFrame.new(e.position)*e.rotation
        for _,piece in ipairs(e.pieces) do
            piece.part.Transparency=fade
            table.insert(self.parts,piece.part);table.insert(self.frames,cf*piece.offset)
        end
    end
    if #self.parts>0 then workspace:BulkMoveTo(self.parts,self.frames,Enum.BulkMoveMode.FireCFrameChanged) end
end
function Casings:Clear()
    for i=#self.entries,1,-1 do self:Remove(i) end
end
function Casings:Report()
    local result=table.clone(self.stats)
    result.active=#self.entries;result.limit=Config.limit
    return result
end
return Casings
