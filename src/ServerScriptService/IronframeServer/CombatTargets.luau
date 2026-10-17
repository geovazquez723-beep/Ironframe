-- Membership in this private table, never a client tag, authorizes damage. No Humanoid damage path exists.
local State = require(game.ReplicatedStorage.IronframeShared.TargetState)
local Destructibles = require(script.Parent.Destructibles)
local Targets = {}
local entries = {}
-- M10A integration fix: the middle drone used to stand at x = 0, in the middle of the road that now leads to the testing district
-- (a 9-wide pedestal plus a 12-high body blocks a 14-wide Bastion). The three drones now flank the road (|x| > 30).
local DRONE_X = { -56, -36, 46 }
local function publish(part, entry)
    local s = entry.state
    part:SetAttribute("Durability", s.health)
    part:SetAttribute("Hits", s.hits)
    part:SetAttribute("Damage", s.damage)
    part:SetAttribute("Resets", s.resets)
    part.Color = if s.health <= 0 then Color3.fromRGB(48,52,53) else Color3.fromRGB(110,118,100)
    entry.label.Text = string.format("%s / %s\n%.0f / %.0f HP | HITS %d\nDAMAGE %.1f | %s", part.Name,s.armor,s.health,s.capacity,s.hits,s.damage,
        if s.health <= 0 then "REPAIR IN 8s" else "AUTO REPAIR: 15s IDLE")
end
function Targets.Build(parent, origin)
    for i, armor in ipairs({"STANDARD", "PLATE", "ABLATIVE"}) do
        local model = Instance.new("Model")
        model.Name, model.Parent = "MechanicalTarget" .. i, parent
        local part = Instance.new("Part")
        part.Name, part.Size = "RangeDrone" .. i, Vector3.new(7,9,4)
        part.Position = origin + Vector3.new(DRONE_X[i],12,205)
        part.Anchored, part.Material = true, Enum.Material.DiamondPlate
        part.Parent = model
        local pedestal = Instance.new("Part")
        pedestal.Name, pedestal.Size, pedestal.Position = "RepairPedestal", Vector3.new(9,7.5,7), part.Position - Vector3.new(0,8.25,0)
        pedestal.Anchored, pedestal.Color, pedestal.Material, pedestal.Parent = true,Color3.fromRGB(43,49,51),Enum.Material.Metal,model
        local eye = Instance.new("Part")
        eye.Name, eye.Size, eye.Position = "Optic", Vector3.new(4,0.6,0.2),part.Position + Vector3.new(0,2,-2.12)
        eye.Anchored, eye.CanCollide, eye.CanQuery = true,false,false
        eye.Material, eye.Color, eye.Parent = Enum.Material.Neon,Color3.fromRGB(255,175,63),model
        local gui = Instance.new("BillboardGui")
        gui.Name, gui.Size, gui.StudsOffset, gui.MaxDistance = "RangeReadout",UDim2.fromOffset(290,90),Vector3.new(0,8,0),250
        gui.Parent = part
        local label = Instance.new("TextLabel")
        label.Size, label.BackgroundColor3, label.BackgroundTransparency = UDim2.fromScale(1,1),Color3.fromRGB(12,22,28),0.15
        label.TextColor3, label.Font, label.TextSize, label.Parent = Color3.fromRGB(255,199,103),Enum.Font.Code,16,gui
        local entry = {state=State.New(armor), label=label}
        entries[part] = entry; publish(part,entry)
    end
end
-- `context` (optional) = { weapon = componentId, position, normal }: lets destructible-environment targets apply weapon identity.
function Targets.Hit(part, category, damage, now, context)
    local entry = entries[part]
    if not entry then return Destructibles.Hit(part, category, damage, now, context) end
    if not part:IsDescendantOf(workspace) then return 0 end
    local dealt = State.Hit(entry.state, category, damage, now)
    publish(part,entry)
    return dealt
end
function Targets.Step(now)
    for part, entry in pairs(entries) do
        if not part:IsDescendantOf(workspace) then entries[part] = nil
        elseif State.Step(entry.state,now) then publish(part,entry) end
    end
end
return Targets
