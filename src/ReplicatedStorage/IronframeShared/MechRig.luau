-- Kinematic solver/applier for the rig described in RigSpec. All parts stay ANCHORED; we only
-- compute CFrames. There are no physics constraints, so no unstable ragdoll is possible.
-- Runs on the server (rest pose) and on clients (cosmetic showroom animation).

local RigSpec = require(script.Parent.RigSpec)

local Geometry = require(script.Parent.WeaponGeometry)
local MechRig = {}

local function axisRotation(axis: string?, angle: number): CFrame
    if axis == "X" then
        return CFrame.Angles(angle, 0, 0)
    elseif axis == "Y" then
        return CFrame.Angles(0, angle, 0)
    elseif axis == "Z" then
        return CFrame.Angles(0, 0, angle)
    end
    return CFrame.identity
end

-- angles: absolute radians per joint name (missing => rest angle).
function MechRig.Solve(rootCF: CFrame, angles: { [string]: number }?): { [string]: CFrame }
    local world: { [string]: CFrame } = {}
    for _, joint in ipairs(RigSpec.Joints) do
        local parentCF = if joint.parent then world[joint.parent] else rootCF
        local angle = if angles and angles[joint.name] ~= nil then angles[joint.name] else joint.rest
        world[joint.name] = parentCF * CFrame.new(joint.offset) * axisRotation(joint.axis, angle)
    end
    return world
end

export type Rig = {
    model: Model,
    parts: { { part: BasePart, joint: string, socket: string?, localCF: CFrame } },
    linkParts: { { part: BasePart, link: any, role: string, end_: string, offset: number } },
}

-- Collect rigged parts from a model built by MechFactory (reads Joint/LocalCF/Link* attributes).
function MechRig.Bind(model: Model): Rig
    local rig: Rig = { model = model, parts = {}, linkParts = {} }
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local linkId = descendant:GetAttribute("LinkId")
            local jointName = descendant:GetAttribute("Joint")
            if linkId then
                table.insert(rig.linkParts, {
                    part = descendant,
                    link = RigSpec.LinksById[linkId],
                    role = descendant:GetAttribute("LinkRole"),
                    end_ = descendant:GetAttribute("LinkEnd"), -- "A" (housing side) or "B" (rod side)
                    offset = descendant:GetAttribute("LinkOffset"), -- distance from that end along the link
                })
            elseif jointName then
                table.insert(rig.parts, {
                    part = descendant,
                    joint = jointName,
                    socket = string.match(descendant.Name, "^Weapon_(%a+_%a+)_"),
                    localCF = descendant:GetAttribute("LocalCF") or CFrame.identity,
                })
            end
        end
    end
    return rig
end

-- Returns the solved world frame of every joint (the cockpit camera reads Torso from it).
function MechRig.Apply(rig: Rig, rootCF: CFrame, angles: { [string]: number }?): { [string]: CFrame }
    local world = MechRig.Solve(rootCF, angles)
    local count = #rig.parts + #rig.linkParts
    local partList: { BasePart } = table.create(count)
    local cframes: { CFrame } = table.create(count)

    for _, entry in ipairs(rig.parts) do
        table.insert(partList, entry.part)
        local cf = world[entry.joint] * entry.localCF
        if entry.socket and rig.model:GetAttribute("WeaponSocket") == entry.socket and rig.model:GetAttribute("Deployment") == "ACTIVE" then
            local aim = rig.model:GetAttribute("WeaponAim")
            if aim then
                local localMount = RigSpec.SocketLocalCF(entry.socket)
                local shotAt = rig.model:GetAttribute("WeaponShotAt") or -100
                local recoil = math.max(0, 1 - (workspace:GetServerTimeNow() - shotAt) / 0.1) * 0.16
                cf = Geometry.Mount(world, entry.socket, aim) * CFrame.new(0,0,recoil) * localMount:Inverse() * entry.localCF
            end
        end
        table.insert(cframes, cf)
    end
    for _, entry in ipairs(rig.linkParts) do
        local link = entry.link
        local a = world[link.jointA]:PointToWorldSpace(link.pointA)
        local b = world[link.jointB]:PointToWorldSpace(link.pointB)
        local delta = b - a
        local distance = delta.Magnitude
        local unit = if distance > 1e-4 then delta / distance else Vector3.new(0, 1, 0)
        local center = if entry.end_ == "A" then a + unit * entry.offset else b - unit * entry.offset
        table.insert(partList, entry.part)
        -- Cylinder axis is local X; rotate it onto the look direction.
        table.insert(cframes, CFrame.lookAt(center, center + unit) * CFrame.Angles(0, math.pi / 2, 0))
    end

    if rig.model:IsDescendantOf(workspace) then
        workspace:BulkMoveTo(partList, cframes, Enum.BulkMoveMode.FireCFrameChanged)
    else
        for index, part in ipairs(partList) do
            part.CFrame = cframes[index]
        end
    end
    return world
end

return MechRig
