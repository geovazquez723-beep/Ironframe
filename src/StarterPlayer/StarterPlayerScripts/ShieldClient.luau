-- Procedural forward hex barrier. Cosmetic only; state/integrity and hits are replicated by the server.
local RunService = game:GetService("RunService")
local ShieldClient = {}
function ShieldClient.Start(animator)
    local entries = {}
    local root = Instance.new("Folder")
    root.Name, root.Parent = "IronframeShieldEffects", workspace
    local function make(model)
        local folder = Instance.new("Model")
        folder.Name, folder.Parent = "PulseShield_" .. model.Name, root
        local entry = { folder = folder, pieces = {}, state = "", changed = os.clock(), impact = model:GetAttribute("ShieldImpactSerial") or 0, hitAt = -100 }
        local function piece(name, size, cf, alpha, edge)
            local part = Instance.new("Part")
            part.Name, part.Size, part.CFrame = name, size, cf
            part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
            part.CastShadow, part.Transparency = false, 1
            part.Material = if edge then Enum.Material.Neon else Enum.Material.Glass
            part.Parent = folder
            table.insert(entry.pieces, { part = part, size = size, cf = cf, alpha = alpha, edge = edge })
            return part
        end
        local points = { Vector3.new(-8,8,0), Vector3.new(8,8,0), Vector3.new(11,0,0), Vector3.new(8,-8,0), Vector3.new(-8,-8,0), Vector3.new(-11,0,0) }
        for i, a in ipairs(points) do
            local b = points[i % 6 + 1]
            piece("EmitterEdge", Vector3.new(0.14,0.14,(b-a).Magnitude), CFrame.lookAt((a+b)/2,b), 0.16, true)
        end
        for row = -1,1 do
            local width = if row == 0 then 21.5 else 16
            for col = -1,1 do
                piece("FieldCell", Vector3.new(width/3-0.1,4.9,0.12), CFrame.new(col*width/3,row*5,0), 0.83, false)
            end
            piece("ScanRail", Vector3.new(width,0.045,0.045), CFrame.new(0,row*5,0.08), 0.65, true)
        end
        for i = 1,12 do
            local a, b = (i-1)*math.pi/6, i*math.pi/6
            local v1, v2 = Vector3.new(math.cos(a),math.sin(a),0), Vector3.new(math.cos(b),math.sin(b),0)
            piece("PulseRing", Vector3.new(0.08,0.08,(v2-v1).Magnitude), CFrame.lookAt((v1+v2)/2,v2), 0.4, true)
        end
        entry.flash = piece("ImpactCore", Vector3.one * 0.35, CFrame.identity, 0.1, true)
        entry.flash.Shape = Enum.PartType.Ball
        local light = Instance.new("PointLight")
        light.Range, light.Brightness, light.Parent = 16, 0, entry.flash
        entry.light = light
        return entry
    end
    RunService:BindToRenderStep("IronframePulseShield", Enum.RenderPriority.Camera.Value, function()
        local mechs = workspace:FindFirstChild("IronframeMechs")
        if not mechs then return end
        for model, entry in pairs(entries) do
            if not model.Parent then entry.folder:Destroy(); entries[model] = nil end
        end
        local t = os.clock()
        for _, model in ipairs(mechs:GetChildren()) do
            local state = model:GetAttribute("ShieldState") or "READY"
            local visible = state == "CHARGING" or state == "PERFECT_GUARD" or state == "ACTIVE" or state == "RECOVERY"
            local entry = entries[model]
            if visible and not entry then entry = make(model); entries[model] = entry end
            if not entry then continue end
            if not visible then entry.folder:Destroy(); entries[model] = nil; continue end
            if state ~= entry.state then entry.state, entry.changed = state, t end
            local impact = model:GetAttribute("ShieldImpactSerial") or 0
            if impact ~= entry.impact then entry.impact, entry.hitAt = impact, t end
            local cf = animator.ChassisCF(model)
            if not cf then continue end
            local phase = t - entry.changed
            local charge = if state == "CHARGING" then math.clamp(phase / math.max(model:GetAttribute("ShieldChargeTime") or 0.15,0.01), 0.05, 1) else 1
            local dissolve = if state == "RECOVERY" then math.clamp(phase / math.max(model:GetAttribute("ShieldRecoveryTime") or 0.25,0.01), 0, 1) else 0
            local perfect = state == "PERFECT_GUARD"
            local hit = math.max(0, 1 - (t-entry.hitAt)/0.24)
            if (model:GetAttribute("ShieldLastPrevented") or 0) == 0 then hit = 0 end
            local color = if perfect then Color3.fromRGB(205,248,255) else Color3.fromRGB(38,183,255)
            if hit > 0 and model:GetAttribute("ShieldLastTiming") == "PERFECT" then color = Color3.fromRGB(255,214,120) end
            local base = cf * CFrame.new(0,10,-13)
            for _, item in ipairs(entry.pieces) do
                local scale = (0.25 + 0.75*charge) * (1 + 0.15*dissolve)
                if item.part.Name == "PulseRing" then
                    scale = 1 + 12 * math.clamp(phase/0.3,0,1)
                    item.part.Transparency = math.clamp(phase/0.3,0,1)
                elseif item.part == entry.flash then
                    scale = 1 + 7 * hit
                    item.part.Transparency = 1-hit*0.9
                else
                    item.part.Transparency = math.clamp(item.alpha + (1-charge)*0.5 + dissolve*(1-item.alpha) - (if perfect then 0.08 else 0) - hit*0.2, 0, 1)
                end
                local at = item.cf
                item.part.Size = if item.part.Name == "PulseRing" then Vector3.new(item.size.X,item.size.Y,item.size.Z*scale) else item.size * scale
                item.part.CFrame = base * CFrame.new(at.Position * scale) * at.Rotation
                item.part.Color = color
            end
            entry.light.Color, entry.light.Brightness = color, hit*3 + (if perfect then 0.8 else 0)
        end
    end)
end
return ShieldClient
