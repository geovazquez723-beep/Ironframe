local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Effects = require(script.Parent.WeaponEffects)
local Shared = game.ReplicatedStorage.IronframeShared
local RigSpec, Telemetry = require(Shared.RigSpec),require(Shared.Telemetry)
local Client = {}
function Client.Start(remotes, cameraMode, animator)
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
    local effects = Effects.New(root,animator)
    remotes.WeaponEffects.OnClientEvent:Connect(function(...)
        effects:Emit(...)
    end)
    RunService:BindToRenderStep("IronframeWeaponFX",Enum.RenderPriority.Camera.Value+2,function(dt)
        effects:Step(dt)
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
        elseif command == "effects" then return effects:Report()
        elseif command == "stats" then return {selected=Telemetry.Value("weapons.selected"),state=Telemetry.Value("weapons.state"),shots=Telemetry.Value("weapons.shots"),hits=Telemetry.Value("weapons.hits"),ammo=Telemetry.Value("weapons.ammo")} end
        return nil
    end
    control.Parent = player.PlayerScripts
end
return Client
