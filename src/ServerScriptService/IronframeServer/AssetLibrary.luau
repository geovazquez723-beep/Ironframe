-- Runtime library for accepted AI-generated models.
--
-- Persistence strategy: geometry and textures live in Roblox as cloud model assets; Git tracks only their
-- stable ids (IronframeShared/AssetRegistry, generated from the factory manifest). At server start the
-- templates are loaded once with InsertService:LoadAsset and cached in ServerStorage/IronframeAssetCache,
-- which is NOT mapped by Rojo, so syncing never overwrites them. No unsaved staging place is required.
--
-- Failure policy: if an asset cannot be loaded (permissions, rate limit, deleted) it is skipped and
-- reported - nothing is substituted. Minimum fix for permission errors: make sure the asset owner is the
-- same user/group that owns this experience (or grant the experience access to the asset).

local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage:WaitForChild("IronframeShared"):WaitForChild("AssetRegistry"))

local AssetLibrary = {}

local cache = ServerStorage:FindFirstChild("IronframeAssetCache")
if not cache then
    cache = Instance.new("Folder")
    cache.Name = "IronframeAssetCache"
    cache.Parent = ServerStorage
end

local placed = {} -- id -> instance count placed
local failures = {} -- id -> error message

local function prepare(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            d.Anchored = true
            d.CanCollide = false
            d.CanTouch = false
            d.CanQuery = false -- decorative: never blocks camera or mech raycasts
            d.Massless = true
        elseif d:IsA("Script") or d:IsA("LocalScript") then
            d:Destroy() -- generated models carry no code; never run anything from a loaded asset
        end
    end
end

local function loadOne(entry)
    local existing = cache:FindFirstChild(entry.id)
    if existing then
        return true
    end
    local ok, result = pcall(InsertService.LoadAsset, InsertService, entry.modelAssetId)
    if not ok then
        failures[entry.id] = tostring(result)
        return false
    end
    local model = result:FindFirstChildWhichIsA("Model")
    if not model then
        failures[entry.id] = "asset contains no Model"
        result:Destroy()
        return false
    end
    prepare(model)
    model.Name = entry.id
    model:SetAttribute("AssetId", entry.id)
    model:SetAttribute("ModelAssetId", entry.modelAssetId)
    model.Parent = cache
    result:Destroy()
    return true
end

-- Loads every registry asset in parallel. Returns loadedCount, failedCount.
function AssetLibrary.Load()
    local pending, loaded = #Registry.list, 0
    for _, entry in ipairs(Registry.list) do
        task.spawn(function()
            if loadOne(entry) then
                loaded += 1
            end
            pending -= 1
        end)
    end
    local deadline = os.clock() + 60
    while pending > 0 and os.clock() < deadline do
        task.wait(0.1)
    end
    local failed = 0
    for id, message in pairs(failures) do
        failed += 1
        warn(string.format("[IF-ASSET] %s failed to load: %s", id, message))
    end
    if failed > 0 then
        warn("[IF-ASSET] Skipped assets are not substituted. If the error mentions permission/access, make the asset owner match the experience owner.")
    end
    print(string.format("[IF-ASSET] Loaded %d/%d AI assets from cloud ids", loaded, #Registry.list))
    return loaded, failed
end

-- The cached, anchored template model for `id` (nil if it failed to load). Callers must Clone it.
function AssetLibrary.Template(id)
    return cache:FindFirstChild(id)
end

function AssetLibrary.Has(id)
    return cache:FindFirstChild(id) ~= nil
end

-- Places a clone of asset `id`.
--   cf        world CFrame for the model pivot (rotation is honoured)
--   options   scale (uniform, default 1), parent, name, grounded (rest the lowest point on cf.Y)
-- Returns the model, or nil if the asset is unavailable. Geometry, textures and multipart structure are
-- preserved exactly; only scale/position/anchoring change.
function AssetLibrary.Place(id, cf, options)
    options = options or {}
    local template = cache:FindFirstChild(id)
    if not template then
        return nil
    end
    local model = template:Clone()
    model.Name = options.name or id
    if options.scale and options.scale ~= 1 then
        model:ScaleTo(options.scale)
    end
    model:PivotTo(cf)
    if options.grounded then
        local boxCF, size = model:GetBoundingBox()
        local bottom = boxCF.Position.Y - size.Y / 2
        model:PivotTo(model:GetPivot() + Vector3.new(0, cf.Position.Y - bottom, 0))
    end
    model.Parent = options.parent or workspace
    placed[id] = (placed[id] or 0) + 1
    return model
end

function AssetLibrary.Stats()
    return { placed = placed, failures = failures }
end

return AssetLibrary
