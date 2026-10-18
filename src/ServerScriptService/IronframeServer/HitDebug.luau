-- Studio-only diagnostic overlay for hit geometry (M11B).
--
-- Shows what the server will actually hit, next to what is drawn:
--   * every registered hit body of the district's machines (tank meshes, the engine-deck region, ROOK / Bastion compound volumes), coloured by
--     the logical component it belongs to;
--   * every registered impact (point + surface normal, coloured by weapon class) for a few seconds;
--   * the path of every weapon ray (muzzle -> endpoint).
--
-- Authority: the overlay is created by the SERVER, only inside Studio (RunService:IsStudio()), and only through the server-only audit
-- bindable (`hitdebug`). It is off by default, not reachable from a client, and creates no gameplay state. Disabling it removes every instance.

local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local HitDebug = {}

local COMPONENT_COLOR = {
    HULL = Color3.fromRGB(255, 70, 70), ENGINE = Color3.fromRGB(255, 170, 40), TURRET = Color3.fromRGB(70, 200, 255),
    TRACK_L = Color3.fromRGB(255, 240, 70), TRACK_R = Color3.fromRGB(255, 240, 70),
    CORE = Color3.fromRGB(255, 70, 70), ARM_L = Color3.fromRGB(70, 255, 150), ARM_R = Color3.fromRGB(70, 255, 150),
    LEG_L = Color3.fromRGB(255, 240, 70), LEG_R = Color3.fromRGB(255, 240, 70), REACTOR = Color3.fromRGB(190, 110, 255),
}
local CLASS_COLOR = { MG = Color3.fromRGB(255, 255, 255), LASER = Color3.fromRGB(80, 220, 255), HEAVY = Color3.fromRGB(255, 80, 200) }
local MAX_MARKERS, MAX_PATHS = 48, 24

local folder: Folder? = nil
local markers: { Instance } = {}
local paths: { Instance } = {}
local observing = false
local district: any = nil

local tracked: { { chassis: () -> CFrame, boxes: { any }, parts: { BasePart }, frames: { CFrame } } } = {}
local connection: RBXScriptConnection? = nil
local lastTrack = 0

-- Draws fitted compound volumes (plain tables in a machine's chassis frame) as translucent parts that follow the machine at 10 Hz.
-- `boxes` = MechHit.Boxes(volumes); `chassis` returns the machine's current chassis CFrame.
function HitDebug.Track(chassis: () -> CFrame, boxes: { any })
    if not folder then
        return
    end
    local entry = { chassis = chassis, boxes = boxes, parts = table.create(#boxes), frames = table.create(#boxes) }
    for i, box in ipairs(boxes) do
        local p = Instance.new("Part")
        p.Name = "DebugVolume_" .. box.region
        p.Size, p.Color, p.Transparency, p.Material = box.size, COMPONENT_COLOR[box.region] or Color3.new(1, 1, 1), 0.6, Enum.Material.SmoothPlastic
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.CFrame = chassis() * box.cf
        p.Parent = folder
        entry.parts[i] = p
    end
    table.insert(tracked, entry)
    if not connection then
        connection = RunService.Heartbeat:Connect(function()
            local now = os.clock()
            if now - lastTrack < 0.1 then
                return
            end
            lastTrack = now
            for _, t in ipairs(tracked) do
                local cf = t.chassis()
                for i, box in ipairs(t.boxes) do
                    t.frames[i] = cf * box.cf
                end
                workspace:BulkMoveTo(t.parts, t.frames, Enum.BulkMoveMode.FireCFrameChanged)
            end
        end)
    end
end

function HitDebug.Enabled(): boolean
    return folder ~= nil
end

local function adorn(adornee: BasePart, color: Color3, size: Vector3?, offset: CFrame?)
    if adornee:IsA("MeshPart") then
        local h = Instance.new("Highlight")
        h.Adornee, h.FillColor, h.OutlineColor = adornee, color, color
        h.FillTransparency, h.OutlineTransparency, h.DepthMode = 0.45, 0, Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = folder
    else
        local a = Instance.new("BoxHandleAdornment")
        a.Adornee, a.Color3, a.Transparency, a.ZIndex, a.AlwaysOnTop = adornee, color, 0.55, 1, true
        a.Size = size or adornee.Size
        if offset then
            a.CFrame = offset
        end
        a.Parent = folder
    end
end

local function mark(position: Vector3, normal: Vector3, color: Color3, size: number)
    if not folder then
        return
    end
    local p = Instance.new("Part")
    p.Name = "DebugImpact"
    p.Shape, p.Size, p.Color, p.Material = Enum.PartType.Ball, Vector3.one * size, color, Enum.Material.Neon
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
    p.CFrame = CFrame.new(position)
    p.Parent = folder
    local line = Instance.new("Part")
    line.Name = "DebugNormal"
    line.Size, line.Color, line.Material = Vector3.new(0.06, 0.06, 3), color, Enum.Material.Neon
    line.Anchored, line.CanCollide, line.CanQuery, line.CanTouch, line.CastShadow = true, false, false, false, false
    line.CFrame = CFrame.lookAt(position + normal * 1.5, position + normal * 3)
    line.Parent = folder
    table.insert(markers, p)
    table.insert(markers, line)
    while #markers > MAX_MARKERS * 2 do
        table.remove(markers, 1):Destroy()
    end
    Debris:AddItem(p, 10)
    Debris:AddItem(line, 10)
end

-- Called from Weapons.Step / TankCombat for every ray or shell segment that ended (hit or not).
function HitDebug.Path(origin: Vector3, endpoint: Vector3, hit: boolean)
    if not folder then
        return
    end
    local length = (endpoint - origin).Magnitude
    if length < 0.1 then
        return
    end
    local p = Instance.new("Part")
    p.Name = "DebugPath"
    p.Size, p.Color, p.Material = Vector3.new(0.05, 0.05, length), if hit then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(120, 120, 120), Enum.Material.Neon
    p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
    p.CFrame = CFrame.lookAt((origin + endpoint) / 2, endpoint)
    p.Parent = folder
    table.insert(paths, p)
    while #paths > MAX_PATHS do
        table.remove(paths, 1):Destroy()
    end
    Debris:AddItem(p, 4)
end

-- `extra(folder)` lets machines whose hit geometry is not a part (analytic compound volumes) add their own adornments.
function HitDebug.Set(on: boolean, d: any, Destructibles: any, extra: ((Folder) -> ())?): boolean
    if on then
        if not RunService:IsStudio() then
            return false -- never outside Studio
        end
        HitDebug.Set(false, d, Destructibles)
        folder = Instance.new("Folder")
        folder.Name = "IronframeHitDebug"
        folder.Parent = workspace
        district = d
        for _, rec in ipairs(Destructibles.Registered(d)) do
            adorn(rec.part, COMPONENT_COLOR[rec.comp] or Color3.fromRGB(255, 255, 255), nil, nil)
        end
        -- The engine deck is a REGION of the hull mesh (TankHit); draw it as a box on each tank root.
        local TankHit = require(game.ReplicatedStorage.IronframeShared.TankHit)
        for _, tank in ipairs(d.vehicles) do
            if tank.build and tank.build.precise then
                local e = TankHit.engine
                local zMax, yMax = 14, 9.2
                adorn(tank.build.root, COMPONENT_COLOR.ENGINE, Vector3.new(18, yMax - e.minY, zMax - e.minZ), CFrame.new(0, (e.minY + yMax) / 2, (e.minZ + zMax) / 2))
            end
        end
        if extra then
            extra(folder)
        end
        if not observing then
            observing = true
            Destructibles.AddHitObserver(function(_, obj, comp, class, position, normal, dealt)
                if folder then
                    mark(position, normal, CLASS_COLOR[class] or Color3.new(1, 1, 1), if dealt > 0 then 0.55 else 0.3)
                end
            end)
        end
        return true
    end
    if connection then
        connection:Disconnect()
        connection = nil
    end
    tracked = {}
    if folder then
        folder:Destroy()
    end
    folder, markers, paths = nil, {}, {}
    return true
end

function HitDebug.ColorOf(component: string): Color3
    return COMPONENT_COLOR[component] or Color3.fromRGB(255, 255, 255)
end

function HitDebug.Mark(position: Vector3, normal: Vector3, color: Color3?, size: number?)
    mark(position, normal, color or Color3.new(1, 1, 1), size or 0.4)
end

function HitDebug.Folder(): Folder?
    return folder
end

return HitDebug
