-- Cosmetic bay machinery; structural query state is owned by BayControl on the server.
local RunService = game:GetService("RunService")
local BayClient = {}
function BayClient.Start()
    local parts = setmetatable({}, { __mode = "k" })
    local hangar = workspace:WaitForChild("IronframeHangar")
    local function bind(p)
        if not p:IsA("BasePart") or parts[p] then return end
        local tag = p:GetAttribute("BayDoor")
        if tag or p:GetAttribute("CraneHook") then
            local bay = p.Parent
            parts[p] = { cf = p.CFrame, tag = tag, bay = bay, hook = p:GetAttribute("CraneHook") }
        end
    end
    local function watch(p)
        if not p:IsA("BasePart") then return end
        -- Attributes can replicate after DescendantAdded; wait for their actual arrival.
        p:GetAttributeChangedSignal("BayDoor"):Connect(function() bind(p) end)
        p:GetAttributeChangedSignal("CraneHook"):Connect(function() bind(p) end)
        bind(p)
    end
    for _, p in ipairs(hangar:GetDescendants()) do watch(p) end
    hangar.DescendantAdded:Connect(watch)
    RunService.RenderStepped:Connect(function()
        for p, entry in pairs(parts) do
            if not p.Parent then parts[p] = nil; continue end
            local open = entry.bay:GetAttribute("DoorsOpen") == true
            local elapsed = workspace:GetServerTimeNow() - (entry.bay:GetAttribute("DoorsOpenAt") or 0)
            local u = math.clamp(elapsed / 3.2, 0, 1)
            u = u * u * (3 - 2 * u)
            local amount = if open then u else 1 - u
            if entry.hook then
                p.CFrame = entry.cf + Vector3.new(0, 17 * amount, 0)
            elseif entry.tag == "SEAM" then
                p.LocalTransparencyModifier = amount
            else
                p.CFrame = entry.cf + Vector3.new((if entry.tag == "L" then -1 else 1) * 22 * amount, 0, 0)
            end
        end
    end)
end
return BayClient
