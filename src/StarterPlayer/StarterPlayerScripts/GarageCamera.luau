-- Smooth orbit/zoom inspection camera for the garage.
--   Right-drag: orbit (360° yaw)   Wheel / pinch: zoom   Middle-drag: raise/lower focus
--   Arrow keys: orbit/tilt         +/- : zoom             R: reset to front three-quarter view
-- The mech faces -Z, so yaw ~158° puts the camera in front and to the mech's right.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GarageCamera = {}

local DEFAULT = { yaw = math.rad(158), pitch = math.rad(12), zoom = 38, focusY = 8.4 }
local MIN_ZOOM, MAX_ZOOM = 12, 72
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
local function beginDrag()
    lastCursor = UserInputService:GetMouseLocation()
end
local function cursorDelta()
    local now = UserInputService:GetMouseLocation()
    local delta = if lastCursor then now - lastCursor else Vector2.zero
    lastCursor = now
    return delta
end

function GarageCamera.Reset()
    target = table.clone(DEFAULT)
    -- Take the short way round so reset never spins the view.
    current.yaw = target.yaw + ((current.yaw - target.yaw + math.pi) % (2 * math.pi) - math.pi)
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
        position = Vector3.new(position.X, math.max(position.Y, 0.8), position.Z) -- stay above the floor

        camera.CameraType = Enum.CameraType.Scriptable
        camera.FieldOfView = 50
        local cf = CFrame.lookAt(position, look)
        -- Slide the framing right so the mech clears the left-hand stats panel on wide screens.
        local shift = if camera.ViewportSize.X > 900 then current.zoom * 0.1 else 0
        camera.CFrame = cf * CFrame.new(-shift, 0, 0)
    end)
end

return GarageCamera
