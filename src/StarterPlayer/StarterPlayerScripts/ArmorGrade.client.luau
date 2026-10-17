-- Client-side colour grading for AI-generated armor meshes.
--
-- The generator bakes pale mint textures into its MeshParts. MeshPart.Color does not tint a TextureID and scripts
-- cannot create SurfaceAppearance maps, so the server stamps each armor MeshPart with a `TintColor` attribute and this
-- script multiplies that tint into a client-side EditableImage copy of the texture (EditableImages do not replicate,
-- which is why this lives on the client). Parts stay hidden for the few frames the grade takes, never pale.
--
-- Lifetime: one graded image per (texture, tint), shared by every live part that needs it and destroyed with its last
-- user. (Observed in Studio: re-using an image whose previous users were all destroyed renders black, so a graded image
-- is never kept across zero users.)
--
-- Failure policy: if EditableImage is unavailable the part is shown ungraded and a warning is logged; geometry,
-- rig placement and gameplay are unaffected.

local AssetService = game:GetService("AssetService")

local mechs = workspace:WaitForChild("IronframeMechs")

local entries = {} -- key -> { image = EditableImage?, users = number, waiting = { thread }?, failed = boolean? }
local warned = false

local function tintKey(texture: string, tint: Color3): string
    return string.format("%s|%d,%d,%d", texture, math.floor(tint.R * 255 + 0.5), math.floor(tint.G * 255 + 0.5), math.floor(tint.B * 255 + 0.5))
end

-- Returns the graded image for the key (creating it if no live part has one) and registers one more user.
local function acquire(key: string, texture: string, tint: Color3)
    local entry = entries[key]
    if entry then
        entry.users += 1
        if entry.waiting then
            table.insert(entry.waiting, coroutine.running())
            coroutine.yield()
        end
        return entry.image
    end
    entry = { users = 1, waiting = {} }
    entries[key] = entry
    local ok, result = pcall(function()
        local image = AssetService:CreateEditableImageAsync(Content.fromUri(texture))
        image:DrawRectangle(Vector2.zero, image.Size, tint, 0, Enum.ImageCombineType.Multiply)
        return image
    end)
    if ok then
        entry.image = result
    elseif not warned then
        warned = true
        warn("[IF-GRADE] EditableImage grading unavailable, armor shown ungraded: " .. tostring(result))
    end
    local waiting = entry.waiting
    entry.waiting = nil
    for _, thread in ipairs(waiting) do
        task.spawn(thread)
    end
    return entry.image
end

local function release(key: string)
    local entry = entries[key]
    if not entry then
        return
    end
    entry.users -= 1
    if entry.users <= 0 then
        entries[key] = nil
        if entry.image then
            entry.image:Destroy()
        end
    end
end

local function grade(part: MeshPart)
    local tint = part:GetAttribute("TintColor")
    local texture = part.TextureID
    if typeof(tint) ~= "Color3" or texture == "" or part:GetAttribute("GradeKey") then
        return
    end
    local key = tintKey(texture, tint)
    part:SetAttribute("GradeKey", key)
    part.LocalTransparencyModifier = 1
    local image = acquire(key, texture, tint)
    part.Destroying:Connect(function()
        release(key)
    end)
    if part.Parent and image then
        part.TextureContent = Content.fromObject(image)
    end
    part.LocalTransparencyModifier = 0
end

-- DescendantAdded rather than ChildAdded: parts of a freshly replicated model can arrive after the model itself.
local function onDescendant(descendant: Instance)
    if descendant:IsA("MeshPart") and descendant:GetAttribute("TintColor") then
        task.spawn(grade, descendant)
    end
end

mechs.DescendantAdded:Connect(onDescendant)
for _, descendant in ipairs(mechs:GetDescendants()) do
    onDescendant(descendant)
end
