-- Run this chunk in the SERVER command bar / Studio MCP during Play, after Bay_1 exists.
-- Exercises Roblox's actual query engine; offline pure-math tests cannot detect sweep precision defects.
local Locomotion = require(game.ServerScriptService.IronframeServer.Locomotion)
local results = {}

local function withController(position, yaw, callback)
    local model = Instance.new("Model")
    model.Name = "M07ProbeTest"
    model.Parent = workspace.IronframeMechs
    local c = Locomotion.Create(model, "IF42_BASTION", position, yaw)
    Locomotion.SetLocked(c, false)
    local ok, result = pcall(callback, c)
    Locomotion.Destroy(c)
    model:Destroy()
    assert(ok, result)
    return result
end

local function advance(c, frames)
    local peak = c.state.y
    for i = 1, frames do
        Locomotion.SetInput(c, 1, 0)
        Locomotion.Step(c, 1 / 60)
        peak = math.max(peak, c.state.y)
        if i % 60 == 0 then task.wait() end
    end
    return { x = c.state.x, z = c.state.z, speed = c.state.speed, peakHeight = peak }
end

results.container = withController(Vector3.new(0, 0, 141), math.pi / 2, function(c)
    local out = advance(c, 720) -- hold full throttle against the face for 12 simulated seconds
    assert(out.x > -26 and out.x < -24 and out.speed == 0, "container sweep tunneled or never approached")
    return out
end)
results.marker = withController(Vector3.new(0, 0, 135), math.pi / 2, function(c)
    local out = advance(c, 720)
    assert(out.x > -17 and out.x < -15 and out.speed == 0, "thin marker sweep tunneled")
    return out
end)
results.hill = withController(Vector3.new(44, 0, 228), math.pi, function(c)
    local out = advance(c, 420)
    assert(out.peakHeight > 3.3, "did not climb the hill")
    assert(out.z < 315 and out.speed == 0, "passed through the far barrier")
    return out
end)
results.input = withController(Vector3.new(0, 0, 100), 0, function(c)
    Locomotion.SetInput(c, 1, 1)
    c.lastInput = os.clock() - 2
    Locomotion.Step(c, 0.2)
    assert(c.state.speed == 0 and c.state.yawRate == 0, "stale input moved the mech")
    Locomotion.SetInput(c, 0 / 0, math.huge)
    assert(c.input.throttle == 0 and c.input.steer == 0, "nonfinite input accepted")
    return "timeout and malformed input neutralized"
end)
return results
