local InsertService = game:GetService("InsertService")
local root = workspace:FindFirstChild("IronframeGeneratedAssets") or Instance.new("Folder")
root.Name = "IronframeGeneratedAssets"; root.Parent = workspace
local batch = Instance.new("Folder"); batch.Name = "batch_001"; batch.Parent = root
local ASSETS = {
    { id = "HNG_001", name = "CraneHookAssembly", asset = 139132454061718, status = "NEEDS_REVIEW" },
    { id = "HNG_002", name = "HydraulicMaintenanceLift", asset = 99298219342682, status = "ACCEPTED" },
    { id = "HNG_003", name = "RoboticServiceArm", asset = 85087665760063, status = "ACCEPTED" },
    { id = "HNG_004", name = "DiagnosticConsole", asset = 126171599709219, status = "ACCEPTED" },
    { id = "HNG_005", name = "CableReel", asset = 104826683943789, status = "ACCEPTED" },
    { id = "HNG_006", name = "ToolCabinet", asset = 131010300372520, status = "ACCEPTED" },
    { id = "HNG_007", name = "OverheadFloodlight", asset = 107457433144343, status = "ACCEPTED" },
}
for index, a in ipairs(ASSETS) do
    local ok, loaded = pcall(InsertService.LoadAsset, InsertService, a.asset)
    if ok then
        local model = loaded:GetChildren()[1]
        model.Name = a.id .. "_" .. a.name
        model:SetAttribute("AssetId", a.id); model:SetAttribute("Status", a.status)
        model.Parent = batch
        model:PivotTo(CFrame.new(((index - 1) % 4) * 40 - 60, 10, 80 + math.floor((index - 1) / 4) * 40))
        loaded:Destroy()
    else
        warn("load failed", a.id, loaded)
    end
end
