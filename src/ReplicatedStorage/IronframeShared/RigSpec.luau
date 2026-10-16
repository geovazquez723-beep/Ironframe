-- IRONFRAME MECHANICAL RIG CONTRACT (M02)
--
-- This module is DATA ONLY. Everything that builds, animates or tests a mech reads it,
-- so a future Blender/MeshPart chassis only needs to honour these names and frames.
--
-- Conventions
--   * Mech faces -Z (front), +X is the mech's right-hand side, +Y is up.
--   * "L" suffix / "left_*" sockets live on -X, "R" / "right_*" on +X.
--   * Joint offsets are expressed in the PARENT joint frame at zero pose.
--   * Every joint rotates about ONE local axis:
--       X  pitch  (+) swings the distal end of a hanging limb toward the FRONT (-Z)
--       Y  yaw    (+) turns the front toward the mech's LEFT (-X)
--       Z  roll   (+) lifts the +X (right) side
--   * `rest` is the neutral stance angle (radians); `limit` is the max |delta| from rest
--     that the showroom/animation layer may apply.
--   * A part belongs to exactly one joint and stores its frame as the attribute `LocalCF`
--     (relative to that joint). Hydraulic links are the only parts positioned by two joints.
--
-- Hierarchy
--   Root ─ Hip ─┬─ Torso ─┬─ Head
--               │         ├─ ShoulderL ─ ElbowL      (left_arm weapon rides ElbowL)
--               │         ├─ ShoulderR ─ ElbowR      (right_arm weapon rides ElbowR)
--               │         └─ shoulder / torso weapon sockets (ride Torso, so they turn with it)
--               ├─ ThighL ─ KneeL ─ AnkleL
--               └─ ThighR ─ KneeR ─ AnkleR

local RigSpec = {}

local function deg(value: number): number
    return math.rad(value)
end

export type Joint = {
    name: string,
    parent: string?,
    offset: Vector3,
    axis: string?,
    rest: number,
    limit: number,
}

local joints: { Joint } = {
    { name = "Root", parent = nil, offset = Vector3.zero, axis = nil, rest = 0, limit = 0 },
    { name = "Hip", parent = "Root", offset = Vector3.new(0, 7.7, 0), axis = "Z", rest = 0, limit = deg(4) },
    { name = "Torso", parent = "Hip", offset = Vector3.new(0, 1.3, 0), axis = "Y", rest = 0, limit = deg(60) },
    { name = "Head", parent = "Torso", offset = Vector3.new(0, 5.3, -0.4), axis = "Y", rest = 0, limit = deg(70) },
}

for _, side in ipairs({ { "L", -1 }, { "R", 1 } }) do
    local tag: string, s: number = side[1], side[2]
    table.insert(joints, { name = "Shoulder" .. tag, parent = "Torso", offset = Vector3.new(s * 4.6, 3.6, 0.1), axis = "X", rest = deg(6), limit = deg(70) })
    table.insert(joints, { name = "Elbow" .. tag, parent = "Shoulder" .. tag, offset = Vector3.new(0, -3.7, 0), axis = "X", rest = deg(50), limit = deg(60) })
end
for _, side in ipairs({ { "L", -1 }, { "R", 1 } }) do
    local tag: string, s: number = side[1], side[2]
    -- Digitigrade stance: thigh forward, shin back, foot flat (25 - 50 + 25 = 0).
    table.insert(joints, { name = "Thigh" .. tag, parent = "Hip", offset = Vector3.new(s * 2.5, -0.5, 0), axis = "X", rest = deg(25), limit = deg(35) })
    table.insert(joints, { name = "Knee" .. tag, parent = "Thigh" .. tag, offset = Vector3.new(0, -3.6, 0), axis = "X", rest = deg(-50), limit = deg(45) })
    table.insert(joints, { name = "Ankle" .. tag, parent = "Knee" .. tag, offset = Vector3.new(0, -3.6, 0), axis = "X", rest = deg(25), limit = deg(30) })
end

local jointsByName: { [string]: Joint } = {}
for _, joint in ipairs(joints) do
    jointsByName[joint.name] = joint
end

-- Weapon sockets. `position` is in the owning joint frame; the weapon module's own frame
-- (barrel along -Z) is placed there, with the arm's rest pitch cancelled so arm guns aim forward.
local sockets: { [string]: { joint: string, position: Vector3 } } = {
    left_arm = { joint = "ElbowL", position = Vector3.new(0, -3.4, -0.3) },
    right_arm = { joint = "ElbowR", position = Vector3.new(0, -3.4, -0.3) },
    left_shoulder = { joint = "Torso", position = Vector3.new(-5.1, 7.4, 1.0) },
    right_shoulder = { joint = "Torso", position = Vector3.new(5.1, 7.4, 1.0) },
    left_torso = { joint = "Torso", position = Vector3.new(-2.9, 1.9, -2.9) },
    right_torso = { joint = "Torso", position = Vector3.new(2.9, 1.9, -2.9) },
}

-- Hydraulic links: housing is anchored at A, rod at B. Each point is in its joint's frame.
local links: { { id: string, jointA: string, pointA: Vector3, jointB: string, pointB: Vector3 } } = {}
for _, side in ipairs({ { "L", -1 }, { "R", 1 } }) do
    local tag: string, s: number = side[1], side[2]
    table.insert(links, { id = "HipPiston" .. tag, jointA = "Hip", pointA = Vector3.new(s * 2.2, 0.5, 1.8), jointB = "Thigh" .. tag, pointB = Vector3.new(0, -1.3, 1.5) })
    table.insert(links, { id = "KneePiston" .. tag, jointA = "Thigh" .. tag, pointA = Vector3.new(0, -0.7, 1.55), jointB = "Knee" .. tag, pointB = Vector3.new(0, -2.0, 1.6) })
    table.insert(links, { id = "WaistPiston" .. tag, jointA = "Hip", pointA = Vector3.new(s * 2.2, 0.6, -1.6), jointB = "Torso", pointB = Vector3.new(s * 2.6, 2.6, -2.1) })
    table.insert(links, { id = "ShoulderPiston" .. tag, jointA = "Torso", pointA = Vector3.new(s * 3.6, 4.4, 1.3), jointB = "Shoulder" .. tag, pointB = Vector3.new(s * 0.2, -1.8, 1.55) })
    table.insert(links, { id = "ElbowPiston" .. tag, jointA = "Shoulder" .. tag, pointA = Vector3.new(0, -2.5, 1.45), jointB = "Elbow" .. tag, pointB = Vector3.new(0, -1.3, 1.35) })
end

RigSpec.Joints = joints
RigSpec.JointsByName = jointsByName
RigSpec.Sockets = sockets
RigSpec.SocketOrder = { "left_arm", "right_arm", "left_shoulder", "right_shoulder", "left_torso", "right_torso" }
RigSpec.Links = links
RigSpec.LinksById = {} :: { [string]: any }
for _, link in ipairs(links) do
    RigSpec.LinksById[link.id] = link
end

-- Local CFrame of a socket in its joint frame, with accumulated X-axis rest pitch cancelled
-- so the weapon points straight ahead (-Z) at rest.
function RigSpec.SocketLocalCF(socketName: string): CFrame
    local socket = sockets[socketName]
    assert(socket, "Unknown socket " .. tostring(socketName))
    local compensation = 0
    local name: string? = socket.joint
    while name do
        local joint = jointsByName[name]
        if joint.axis == "X" then
            compensation += joint.rest
        end
        name = joint.parent
    end
    return CFrame.new(socket.position) * CFrame.Angles(-compensation, 0, 0)
end

-- Clamp a requested pose (absolute radians per joint) into each joint's allowed range.
function RigSpec.ClampAngle(jointName: string, angle: number): number
    local joint = jointsByName[jointName]
    return math.clamp(angle, joint.rest - joint.limit, joint.rest + joint.limit)
end

return RigSpec
