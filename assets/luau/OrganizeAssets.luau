-- Run inside the Studio staging place via the MCP execute_luau tool (Edit datamodel).
-- Finds raw generate_mesh results in Workspace (models named after their prompt text), files each into
-- Workspace/IronframeGeneratedAssets/<batch>/<ID>_<Name>, tags it, lays it out on a grid, and returns a JSON
-- report with ONLY values Studio exposes (bounding box, MeshPart sizes, mesh/texture asset ids, attributes).
--
-- Usage: set `MAP` (prompt prefix -> spec asset) and `BATCH`, then execute. Re-running is safe:
-- already organized models are re-measured, not duplicated.

local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")
local BATCH = "batch_001"
local MAP = {
    -- ["Heavy industrial cable reel"] = { id = "HNG_005", name = "CableReel", category = "hangar" },
}

local root = workspace:FindFirstChild("IronframeGeneratedAssets") or Instance.new("Folder")
root.Name = "IronframeGeneratedAssets"
root.Parent = workspace
local batchFolder = root:FindFirstChild(BATCH) or Instance.new("Folder")
batchFolder.Name = BATCH
batchFolder.Parent = root

local function measure(model)
    local _, size = model:GetBoundingBox()
    local report = {
        modelName = model.Name,
        path = model:GetFullName(),
        boundingBox = { size.X, size.Y, size.Z },
        meshPartCount = 0,
        otherPartCount = 0,
        parts = {},
        attributes = model:GetAttributes(),
        issues = {},
    }
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("MeshPart") then
            report.meshPartCount += 1
            table.insert(report.parts, {
                name = d.Name, size = { d.Size.X, d.Size.Y, d.Size.Z },
                meshId = d.MeshId, textureId = d.TextureID,
                hasSurfaceAppearance = d:FindFirstChildOfClass("SurfaceAppearance") ~= nil,
                anchored = d.Anchored,
            })
            -- Triangle count from the mesh asset itself (EditableMesh face count); nil if Studio refuses.
            local okTri, tri = pcall(function()
                return #AssetService:CreateEditableMeshAsync(Content.fromUri(d.MeshId)):GetFaces()
            end)
            if okTri then
                report.parts[#report.parts].triangles = tri
                report.triangles = (report.triangles or 0) + tri
            end
            d.Anchored = true -- generated parts arrive unanchored; staging keeps them still
            if d.MeshId == "" then table.insert(report.issues, d.Name .. ": empty MeshId") end
        elseif d:IsA("BasePart") then
            report.otherPartCount += 1
        end
    end
    if report.meshPartCount == 0 then table.insert(report.issues, "no MeshParts") end
    return report
end

local reports = {}
for _, child in ipairs(workspace:GetChildren()) do
    if child:IsA("Model") and child:GetAttribute("RBX_AI_GENERATED") and child.Name ~= "HydraulicActuator" then
        for prefix, spec in pairs(MAP) do
            if string.sub(child.Name, 1, #prefix) == prefix then
                child.Name = spec.id .. "_" .. spec.name
                child:SetAttribute("AssetId", spec.id)
                child:SetAttribute("Category", spec.category)
                child:SetAttribute("Batch", BATCH)
                child.Parent = batchFolder
            end
        end
    end
end
for index, model in ipairs(batchFolder:GetChildren()) do
    -- lay out in a row 40 studs apart, away from the origin, so screenshots do not overlap
    model:PivotTo(CFrame.new(((index - 1) % 4) * 40 - 60, 10, 80 + math.floor((index - 1) / 4) * 40))
    table.insert(reports, measure(model))
end
return HttpService:JSONEncode(reports)
