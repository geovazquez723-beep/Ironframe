local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Shared = game.ReplicatedStorage.IronframeShared
local Components, RigSpec, Telemetry = require(Shared.ComponentRegistry),require(Shared.RigSpec),require(Shared.Telemetry)
local Client = {}
function Client.Start(remotes, cameraMode)
    local player = Players.LocalPlayer
    local held, selected, elapsed, reload, override = false,1,0,false,nil
    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Parent = "IronframeWeaponUI",false,32,player.PlayerGui
    local text = Instance.new("TextLabel")
    text.Name, text.Size, text.Position = "WeaponFeedback",UDim2.fromOffset(660,58),UDim2.new(0.5,-330,1,-244)
    text.AnchorPoint, text.Position = Vector2.new(0.5,0),UDim2.new(0.5,0,1,-244)
    local scale = Instance.new("UIScale")
    scale.Parent = text
    text.BackgroundColor3, text.BackgroundTransparency = Color3.fromRGB(12,22,28),0.2
    text.TextColor3, text.TextSize, text.Font, text.Parent = Color3.fromRGB(255,201,110),15,Enum.Font.Code,gui
    local root = Instance.new("Folder")
    root.Name, root.Parent = "IronframeWeaponEffects",workspace
    local effects = {}
    local function part(name, size, color, parent)
        local p = Instance.new("Part")
        p.Name, p.Size, p.Color, p.Material = name,size,color,Enum.Material.Neon
        p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = true,false,false,false,false
        p.Parent = parent
        return p
    end
    remotes.WeaponEffects.OnClientEvent:Connect(function(model,socket,id,origin,endpoint,normal,damage)
        local spec = Components[id] and Components[id].combat
        if not spec or (workspace.CurrentCamera.CFrame.Position-origin).Magnitude > 650 then return end
        -- Bound concurrent effects even with many pilots. All objects are local, nonphysical and expire.
        if #effects >= 48 then effects[1].folder:Destroy(); table.remove(effects,1) end
        local folder = Instance.new("Folder")
        folder.Name, folder.Parent = spec.effect,root
        local laser = spec.category == "laser"
        local color = if laser then Color3.fromRGB(75,222,255) else Color3.fromRGB(255,177,65)
        local muzzle = model:FindFirstChild("Weapon_"..socket.."_Emitter")
        local beam = part("BeamCore",Vector3.one*0.1,color,folder)
        local halo = laser and part("BeamHalo",Vector3.one*0.2,color,folder) or nil
        local flash = part("MuzzleFlash",Vector3.one*(if laser then 0.65 else 0.9),color,folder)
        flash.Shape = Enum.PartType.Ball
        flash.Position = muzzle and muzzle.Position or origin
        local light = Instance.new("PointLight")
        light.Color,light.Range,light.Brightness,light.Parent = color,14,3,flash
        local impact = part("ImpactGlow",Vector3.one*0.5,color,folder)
        impact.Shape, impact.Position = Enum.PartType.Ball,endpoint
        local sparks = Instance.new("ParticleEmitter")
        sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        sparks.Color, sparks.Lifetime, sparks.Speed = ColorSequence.new(color),NumberRange.new(0.08,0.22),NumberRange.new(8,18)
        sparks.Rate, sparks.SpreadAngle, sparks.LightEmission = 0,Vector2.new(65,65),1
        sparks.Size = NumberSequence.new(0.18,0)
        sparks.Parent = impact
        impact.CFrame = CFrame.lookAt(endpoint,endpoint+normal)
        sparks:Emit(if laser then 9 else 4)
        local shell = not laser and part("Shell",Vector3.new(0.14,0.14,0.35),Color3.fromRGB(163,126,62),folder) or nil
        if shell then shell.Material = Enum.Material.Metal end
        local sound = Instance.new("Sound")
        sound.SoundId,sound.Volume,sound.PlaybackSpeed = spec.sound,if laser then 0.65 else 0.25,if laser then 0.55 else 1.8
        sound.RollOffMaxDistance,sound.Parent = 220,flash
        sound:Play()
        table.insert(effects,{folder=folder,muzzle=muzzle,origin=origin,endpoint=endpoint,beam=beam,halo=halo,flash=flash,impact=impact,shell=shell,
            born=os.clock(),duration=if laser then 0.16 else 0.075})
        Debris:AddItem(folder,0.5)
    end)
    RunService:BindToRenderStep("IronframeWeaponFX",Enum.RenderPriority.Camera.Value+2,function()
        local now = os.clock()
        for i=#effects,1,-1 do
            local e = effects[i]
            local age = now-e.born
            if age > 0.4 or not e.folder.Parent then e.folder:Destroy(); table.remove(effects,i); continue end
            local origin = e.muzzle and e.muzzle.Parent and e.muzzle.Position or e.origin
            local length = (e.endpoint-origin).Magnitude
            local cf = CFrame.lookAt((origin+e.endpoint)/2,e.endpoint)
            e.beam.Size,e.beam.CFrame = Vector3.new(0.075,0.075,math.max(length,0.01)),cf
            e.beam.Transparency = math.clamp(age/e.duration,0,1)
            if e.halo then
                e.halo.Size,e.halo.CFrame = Vector3.new(0.3,0.3,math.max(length,0.01)),cf
                e.halo.Transparency = math.clamp(0.65+age/e.duration*0.35,0,1)
            end
            e.flash.Position,e.flash.Transparency = origin,math.clamp(age/0.08,0,1)
            e.flash.PointLight.Brightness = math.max(0,3*(1-age/0.1))
            e.impact.Transparency = math.clamp(age/0.25,0,1)
            e.impact.Size = Vector3.one*(0.5+age*3)
            if e.shell then
                e.shell.CFrame = CFrame.new(e.origin+Vector3.new(age*7,1+age*3-age*age*30,0))*CFrame.Angles(age*15,0,age*20)
                e.shell.Transparency = math.clamp(age/0.4,0,1)
            end
        end
    end)
    UIS.InputBegan:Connect(function(input,processed)
        if processed then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then held = true end
        local index = ({[Enum.KeyCode.One]=1,[Enum.KeyCode.Two]=2,[Enum.KeyCode.Three]=3,[Enum.KeyCode.Four]=4,[Enum.KeyCode.Five]=5,[Enum.KeyCode.Six]=6})[input.KeyCode]
        if index then selected = index end
        if input.KeyCode == Enum.KeyCode.T then reload = true end -- R already recenters both cameras
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then held = false end
    end)
    UIS.WindowFocusReleased:Connect(function() held = false; override = nil end)
    local attributes = {selected="WeaponSelected",name="WeaponName",state="WeaponState",mode="WeaponMode",ammo="WeaponAmmo",magazine="WeaponMagazine",
        power="WeaponPower",cost="WeaponCost",heat="WeaponHeat",cooldown="WeaponCooldown",reload="WeaponReload",available="WeaponAvailable",
        shots="WeaponShots",hits="WeaponHits",lastTarget="WeaponLastTarget",lastDamage="WeaponLastDamage"}
    RunService.Heartbeat:Connect(function(dt)
        elapsed += dt; if elapsed < 0.1 then return end; elapsed = 0
        local folder = workspace:FindFirstChild("IronframeMechs")
        local model = folder and folder:FindFirstChild(tostring(player.UserId))
        local live = model and model:GetAttribute("Deployment") == "ACTIVE" and model:GetAttribute("State") == "OPERATIONAL" and not cameraMode.IsEvacuating()
        text.Visible = live == true and cameraMode.Current() ~= "COCKPIT"
        scale.Scale = math.min(1,workspace.CurrentCamera.ViewportSize.X / 680)
        if not live then held = false; override = nil end
        for key,attribute in pairs(attributes) do
            local value = model and model:GetAttribute(attribute)
            Telemetry.Publish("weapons."..key,value,if value ~= nil then "LIVE" else "STANDBY")
        end
        local ammo = {}
        for _,socket in ipairs(RigSpec.SocketOrder) do ammo[socket] = model and model:GetAttribute("Ammo_"..socket) end
        Telemetry.Publish("weapons.magazines",ammo)
        local state = Telemetry.Value("weapons.state","SAFE")
        local remaining = Telemetry.Value("weapons.reload",0)
        text.Text = string.format("[%d] %s | %s %s | AMMO %s | %.1fs\nLMB Fire  1-6 Hardpoint  T Reload | %.1f u/shot | MAX HEAT %.1f/s | HITS %d%s",
            Telemetry.Value("weapons.selected",selected),Telemetry.Value("weapons.name","--"),Telemetry.Value("weapons.mode","--"),state,
            if Telemetry.Value("weapons.magazine",0)>0 then tostring(Telemetry.Value("weapons.ammo",0)) else "CAP",
            if remaining>0 then remaining else Telemetry.Value("weapons.cooldown",0),Telemetry.Value("weapons.cost",0),Telemetry.Value("weapons.heat",0),Telemetry.Value("weapons.hits",0),
            if Telemetry.Value("weapons.available",false) then "" else " | ENERGY LOW")
        if live then
            local camera = workspace.CurrentCamera
            local pixel = if cameraMode.Current() == "COCKPIT" then camera.ViewportSize/2 else UIS:GetMouseLocation()-game:GetService("GuiService"):GetGuiInset()
            local ray = camera:ViewportPointToRay(pixel.X,pixel.Y)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {model,root,player.Character}
            local cockpit = workspace:FindFirstChild("IronframeCockpitClient")
            if cockpit then params:AddToFilter(cockpit) end
            local result = workspace:Raycast(ray.Origin,ray.Direction*700,params)
            local aim = override or (result and result.Position or ray.Origin+ray.Direction*700)
            remotes.WeaponIntent:FireServer(selected,held and not UIS:GetFocusedTextBox(),aim,reload)
        end
        reload = false
    end)
    local control = Instance.new("BindableFunction")
    control.Name = "IronframeWeaponControl"
    control.OnInvoke = function(command,a,b)
        if command == "select" then selected = a
        elseif command == "fire" then held = a == true; override = b
        elseif command == "reload" then reload = true
        elseif command == "stats" then return {selected=Telemetry.Value("weapons.selected"),state=Telemetry.Value("weapons.state"),shots=Telemetry.Value("weapons.shots"),hits=Telemetry.Value("weapons.hits"),ammo=Telemetry.Value("weapons.ammo")} end
        return nil
    end
    control.Parent = player.PlayerScripts
end
return Client
