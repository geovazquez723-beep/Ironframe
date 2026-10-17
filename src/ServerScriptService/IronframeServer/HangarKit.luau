-- Small part-construction helpers shared by the hangar architecture and dressing builders.
-- Architecture (walls, floor, ceiling, columns, beams) is CanQuery=true so the garage camera can collide with
-- it; decoration is CanQuery=false and CanCollide=false so it can never block camera, mech or avatar.

local Kit = {}

Kit.COLOR = {
    concrete = Color3.fromRGB(64, 66, 68),
    concreteDark = Color3.fromRGB(46, 48, 51),
    steel = Color3.fromRGB(40, 44, 50),
    gunmetal = Color3.fromRGB(56, 62, 68),
    lightSteel = Color3.fromRGB(104, 110, 116),
    olive = Color3.fromRGB(70, 78, 56),
    oliveDark = Color3.fromRGB(46, 52, 38),
    hazardYellow = Color3.fromRGB(198, 152, 32),
    black = Color3.fromRGB(22, 23, 25),
    amber = Color3.fromRGB(255, 168, 58),
    warm = Color3.fromRGB(255, 200, 140),
    cool = Color3.fromRGB(150, 196, 255),
    red = Color3.fromRGB(220, 58, 40),
    green = Color3.fromRGB(70, 210, 120),
}

-- opts: collide (false), query (false), shadow (true), transparency, name suffix none.
function Kit.part(parent, name, size, cf, color, material, opts)
    opts = opts or {}
    local p = Instance.new("Part")
    p.Name = name
    p.Size = size
    p.CFrame = cf
    p.Anchored = true
    p.CanCollide = opts.collide or false
    p.CanQuery = opts.query or false
    p.CanTouch = false
    p.CastShadow = opts.shadow ~= false
    p.Material = material or Enum.Material.Metal
    p.Color = color or Kit.COLOR.steel
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    if opts.transparency then p.Transparency = opts.transparency end
    p.Parent = parent
    return p
end

-- Cylinder along `axis` ("X", "Y" or "Z"); `cf` is the cylinder centre/orientation.
function Kit.cyl(parent, name, axis, length, diameter, cf, color, material, opts)
    local p = Kit.part(parent, name, Vector3.new(length, diameter, diameter), cf, color, material, opts)
    p.Shape = Enum.PartType.Cylinder
    if axis == "Y" then
        p.CFrame = cf * CFrame.Angles(0, 0, math.pi / 2)
    elseif axis == "Z" then
        p.CFrame = cf * CFrame.Angles(0, math.pi / 2, 0)
    end
    return p
end

function Kit.glow(parent, name, size, cf, color, opts)
    opts = opts or {}
    opts.shadow = false
    return Kit.part(parent, name, size, cf, color, Enum.Material.Neon, opts)
end

-- I-beam along local X of cf: web + two flanges.
function Kit.ibeam(parent, name, length, height, flange, cf, color, opts)
    Kit.part(parent, name .. "_Web", Vector3.new(length, height, 0.5), cf, color, Enum.Material.Metal, opts)
    Kit.part(parent, name .. "_FlangeTop", Vector3.new(length, 0.55, flange), cf * CFrame.new(0, height / 2, 0), color, Enum.Material.Metal, opts)
    Kit.part(parent, name .. "_FlangeBottom", Vector3.new(length, 0.55, flange), cf * CFrame.new(0, -height / 2, 0), color, Enum.Material.Metal, opts)
end

-- Yellow/black hazard stripes drawn on one face with a single hard-stop UIGradient (no per-stripe parts).
function Kit.hazard(parent, name, size, cf, face, bands)
    local p = Kit.part(parent, name, size, cf, Kit.COLOR.black, Enum.Material.SmoothPlastic, { shadow = false })
    local gui = Instance.new("SurfaceGui")
    gui.Face = face or Enum.NormalId.Top
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = 12
    gui.LightInfluence = 1
    gui.Parent = p
    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.new(1, 1, 1)
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local points = {}
    bands = math.min(bands or 5, 5) -- ColorSequence allows 20 keypoints = 5 bands of 4
    local eps = 0.0001
    for i = 0, bands * 2 - 1 do
        local c = if i % 2 == 0 then Kit.COLOR.hazardYellow else Kit.COLOR.black
        local t0, t1 = i / (bands * 2), (i + 1) / (bands * 2)
        table.insert(points, ColorSequenceKeypoint.new(math.clamp(t0 + (i == 0 and 0 or eps), 0, 1), c))
        table.insert(points, ColorSequenceKeypoint.new(math.clamp(t1 - (i == bands * 2 - 1 and 0 or eps), 0, 1), c))
    end
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new(points)
    gradient.Rotation = 45
    gradient.Parent = frame
    return p
end

-- Painted metal sign with text on one face.
function Kit.sign(parent, name, text, size, cf, face, bg, fg, textSize)
    local p = Kit.part(parent, name, size, cf, bg or Kit.COLOR.steel, Enum.Material.SmoothPlastic, { shadow = false })
    local gui = Instance.new("SurfaceGui")
    gui.Face = face or Enum.NormalId.Front
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = 24
    gui.LightInfluence = 0.6
    gui.Parent = p
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = fg or Kit.COLOR.warm
    label.Font = Enum.Font.GothamBold
    label.TextScaled = true
    label.Parent = gui
    return p
end

function Kit.light(parent, className, color, range, brightness, extra)
    local l = Instance.new(className)
    l.Color = color
    l.Range = range
    l.Brightness = brightness
    l.Shadows = false
    for k, v in pairs(extra or {}) do
        l[k] = v
    end
    l.Parent = parent
    return l
end

return Kit
