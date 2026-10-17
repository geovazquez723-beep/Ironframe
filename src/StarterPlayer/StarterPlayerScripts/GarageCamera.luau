-- Smooth orbit/zoom inspection camera for the garage.
--   Right-drag: orbit (360° yaw)   Wheel / pinch: zoom   Middle-drag: raise/lower focus
--   Arrow keys: orbit/tilt         +/- : zoom             R: reset to front three-quarter view
-- The mech faces -Z, so yaw ~158° puts the camera in front and to the mech's right.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GarageCamera = {}

local DEFAULT = { yaw = math.rad(158), pitch = math.rad(12), zoom = 34, focusY = 8.4 }
local MIN_ZOOM, MAX_ZOOM = 10, 72
local MAX_CAMERA_HEIGHT = 37
local MIN_PITCH, MAX_PITCH = math.rad(-10), math.rad(72)
local SMOOTH = 14 -- higher = snappier

local target = table.clone(DEFAULT)
local current = table.clone(DEFAULT)
local focusPosition = Vector3.new(0, 0, 0)
local hasFocus = false
local dragging, panning = false, false
local pinchBase

local function clampTarget()
    target.pitch = math.clamp(target.pitch, MIN_PITCH, MAX_PITCH)
    target.zoom = math.clamp(target.zoom, MIN_ZOOM, MAX_ZOOM)
    target.focusY = math.clamp(target.focusY, 2, 15)
end

-- Drag deltas come from the absolute cursor position rather than Input.Delta/GetMouseDelta:
-- that works for every pointer source (real mouse, trackpad, synthetic input) and never
-- depends on mouse-lock state.
local lastCursor
local occlusionParams = RaycastParams.new()
occlusionParams.FilterType = Enum.RaycastFilterType.Exclude
occlusionParams.IgnoreWater = true
local function beginDrag()
    lastCursor = UserInputService:GetMouseLocation()
end
local function cursorDelta()
    local now = UserInputService:GetMouseLocation()
    local delta = if lastCursor then now - lastCursor else Vector2.zero
    lastCursor = now
    return delta
end

-- Mech clearance (M05): the AI armor and weapons are larger and more irregular than the old blockout, and the
-- camera can orbit at MIN_ZOOM through the pauldrons. Every visible mech part is tracked and the camera is pushed
-- straight back along its own ray until it is CAMERA_PAD studs clear of all of them. Pure client-side framing.
local CAMERA_PAD = 1.0
local mechParts = {}
local function trackMechs(folder)
    local function add(descendant)
        if descendant:IsA("BasePart") and descendant.Transparency < 1 then
            mechParts[descendant] = true
        end
    end
    for _, descendant in ipairs(folder:GetDescendants()) do
        add(descendant)
    end
    folder.DescendantAdded:Connect(add)
    folder.DescendantRemoving:Connect(function(descendant)
        mechParts[descendant] = nil
    end)
end
task.spawn(function()
    trackMechs(workspace:WaitForChild("IronframeMechs"))
end)

-- Distance from `point` to the nearest mech part surface (0 when inside); stops early once under the pad.
local function mechClearance(point: Vector3): number
    local best = math.huge
    for part in pairs(mechParts) do
        local l = part.CFrame:PointToObjectSpace(point)
        local h = part.Size / 2
        local dx, dy, dz = math.max(math.abs(l.X) - h.X, 0), math.max(math.abs(l.Y) - h.Y, 0), math.max(math.abs(l.Z) - h.Z, 0)
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < best then
            best = d
            if best < CAMERA_PAD then
                return best
            end
        end
    end
    return best
end

function GarageCamera.Reset()
    target = table.clone(DEFAULT)
    -- Take the short way round so reset never spins the view.
    current.yaw = target.yaw + ((current.yaw - target.yaw + math.pi) % (2 * math.pi) - math.pi)
end

-- Named inspection views (keys 1-8). yaw 180 = straight in front, 90/270 = sides, 0 = rear.
local VIEWS = {
    [Enum.KeyCode.One] = { yaw = 158, pitch = 12, zoom = 34, focusY = 8.4 }, -- front three-quarter (default)
    [Enum.KeyCode.Two] = { yaw = 90, pitch = 6, zoom = 31, focusY = 8.4 }, -- side profile (looks toward the west storage area)
    [Enum.KeyCode.Three] = { yaw = 12, pitch = 14, zoom = 27, focusY = 9 }, -- rear reactor / exhaust
    [Enum.KeyCode.Four] = { yaw = 150, pitch = 8, zoom = 16, focusY = 12 }, -- chest / cockpit / shoulder detail
    [Enum.KeyCode.Five] = { yaw = 125, pitch = 5, zoom = 17, focusY = 4 }, -- leg and hydraulic detail
    [Enum.KeyCode.Six] = { yaw = 158, pitch = 26, zoom = 66, focusY = 14 }, -- full hangar overview
    [Enum.KeyCode.Seven] = { yaw = 250, pitch = 10, zoom = 50, focusY = 9 }, -- east maintenance area (consoles, transformers)
    [Enum.KeyCode.Eight] = { yaw = 200, pitch = 34, zoom = 48, focusY = 24 }, -- overhead crane and structure
}

-- degrees in, smooth transition out
function GarageCamera.SetView(yawDeg, pitchDeg, zoom, focusY)
    target.yaw = current.yaw + ((math.rad(yawDeg) - current.yaw + math.pi) % (2 * math.pi) - math.pi)
    target.pitch, target.zoom, target.focusY = math.rad(pitchDeg), zoom, focusY
    clampTarget()
end

function GarageCamera.Start(getFocus)
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            dragging = true
            beginDrag()
        elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
            panning = true
            beginDrag()
        elseif input.KeyCode == Enum.KeyCode.R then
            GarageCamera.Reset()
        elseif VIEWS[input.KeyCode] then
            local v = VIEWS[input.KeyCode]
            GarageCamera.SetView(v.yaw, v.pitch, v.zoom, v.focusY)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            dragging = false
        elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
            panning = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input, processed)
        if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
            target.zoom *= 0.9 ^ input.Position.Z
        elseif input.UserInputType == Enum.UserInputType.Touch and not processed and not pinchBase then
            target.yaw -= input.Delta.X * 0.008
            target.pitch += input.Delta.Y * 0.006
        end
    end)
    UserInputService.TouchPinch:Connect(function(_, scale, _, state)
        if state == Enum.UserInputState.Begin then pinchBase = target.zoom end
        if pinchBase then target.zoom = pinchBase / math.max(scale, 0.1) end
        if state == Enum.UserInputState.End then pinchBase = nil end
    end)

    RunService:BindToRenderStep("IronframeGarageCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
        local focus = getFocus()
        if focus then
            focusPosition = focus
            hasFocus = true
        end
        local camera = workspace.CurrentCamera
        if not camera or not hasFocus then return end
        local ignore = { workspace:FindFirstChild("IronframeMechs") }
        local character = game:GetService("Players").LocalPlayer.Character
        if character then table.insert(ignore, character) end
        occlusionParams.FilterDescendantsInstances = ignore

        if dragging or panning then
            local delta = cursorDelta()
            if dragging then
                target.yaw -= delta.X * 0.0065
                target.pitch += delta.Y * 0.0045
            else
                target.focusY += delta.Y * 0.03
            end
        end
        local key = UserInputService.IsKeyDown
        local turn = (key(UserInputService, Enum.KeyCode.Left) and 1 or 0) - (key(UserInputService, Enum.KeyCode.Right) and 1 or 0)
        local tilt = (key(UserInputService, Enum.KeyCode.Up) and 1 or 0) - (key(UserInputService, Enum.KeyCode.Down) and 1 or 0)
        local zoomKey = (key(UserInputService, Enum.KeyCode.Minus) and 1 or 0) - (key(UserInputService, Enum.KeyCode.Equals) and 1 or 0)
        target.yaw += turn * dt * 1.6
        target.pitch += tilt * dt * 0.9
        target.zoom *= 1 + zoomKey * dt * 1.2
        clampTarget()

        local alpha = 1 - math.exp(-SMOOTH * dt)
        current.yaw += (target.yaw - current.yaw) * alpha
        current.pitch += (target.pitch - current.pitch) * alpha
        current.zoom += (target.zoom - current.zoom) * alpha
        current.focusY += (target.focusY - current.focusY) * alpha

        local look = focusPosition + Vector3.new(0, current.focusY, 0)
        local offset = Vector3.new(
            math.sin(current.yaw) * math.cos(current.pitch),
            math.sin(current.pitch),
            math.cos(current.yaw) * math.cos(current.pitch)
        ) * current.zoom
        local position = look + offset
        -- Stay above the floor and below the hangar roof trusses (bottom of purlins is y = 38).
        position = Vector3.new(position.X, math.clamp(position.Y, 0.8, MAX_CAMERA_HEIGHT), position.Z)
        -- Slide the framing right so the mech clears the left-hand stats panel on wide screens. Applied to both
        -- ends of the camera ray so the occlusion test below sees the final camera position.
        local shift = if camera.ViewportSize.X > 900 then current.zoom * 0.1 else 0
        local right = CFrame.lookAt(position, look).RightVector * -shift
        look += right
        position += right
        -- Pull the camera in when hangar structure (walls, columns, ceiling: CanQuery parts) is in the way.
        -- Decorative props are CanQuery=false and never obstruct.
        local toCamera = position - look
        local hit = workspace:Raycast(look, toCamera, occlusionParams)
        if hit then
            local allowed = math.max((hit.Position - look).Magnitude - 1.2, MIN_ZOOM * 0.6)
            position = look + toCamera.Unit * allowed
        end

        -- Keep the lens outside the mech's own geometry (only matters when zoomed in close).
        local arm = position - look
        local distance = arm.Magnitude
        if distance < 26 and mechClearance(position) < CAMERA_PAD then
            local direction = arm.Unit
            for _ = 1, 60 do
                distance += 0.5
                position = look + direction * distance
                if mechClearance(position) >= CAMERA_PAD then
                    break
                end
            end
        end

        camera.CameraType = Enum.CameraType.Scriptable
        camera.FieldOfView = 50
        camera.CFrame = CFrame.lookAt(position, look)
    end)
end

return GarageCamera
