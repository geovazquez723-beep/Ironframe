-- Hangar bay machinery state (M07): doors and the overhead crane hook.
-- The server owns only the STATE: attributes on the bay model plus CanQuery on the structural door leaves (so the drive
-- probe sees an open or closed door). The sliding itself is cosmetic and runs locally on each client (BayClient), so opening
-- the doors costs no per-frame replication of the ~40 door parts.

local BayControl = {}

BayControl.DOOR_TIME = 3.2

local tokens = setmetatable({}, { __mode = "k" })

local function leaves(bay: Model)
    local out = {}
    for _, d in ipairs(bay:GetDescendants()) do
        if d:IsA("BasePart") and d.Name == "DoorLeafL" or d:IsA("BasePart") and d.Name == "DoorLeafR" then
            table.insert(out, d)
        end
    end
    return out
end

function BayControl.SetDoors(bay: Model?, open: boolean)
    if not bay or not bay.Parent then
        return
    end
    tokens[bay] = (tokens[bay] or 0) + 1
    local token = tokens[bay]
    bay:SetAttribute("DoorsOpenAt", workspace:GetServerTimeNow())
    bay:SetAttribute("DoorsOpen", open)
    if open then
        for _, leaf in ipairs(leaves(bay)) do
            leaf.CanQuery = false -- the leaves are sliding clear of the opening; never let a stale leaf block the mech
        end
    else
        task.delay(BayControl.DOOR_TIME, function()
            if tokens[bay] == token and bay.Parent then
                for _, leaf in ipairs(leaves(bay)) do
                    leaf.CanQuery = true
                end
            end
        end)
    end
end

function BayControl.AreDoorsOpen(bay: Model?): boolean
    return bay ~= nil and bay:GetAttribute("DoorsOpen") == true
end

return BayControl
