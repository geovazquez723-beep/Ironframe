-- Optical zoom state (M11C). Pure: the client camera controller owns one of these and asks it for the field of view and the look
-- sensitivity every frame. The magnification itself is smoothed in log space (equal visual speed zooming in and out); a reset is
-- immediate and total, so no camera path (garage, ejection, respawn, a new sortie) can inherit a stale field of view.
local Avionics = if script then require((script :: any).Parent.Avionics) else require("./Avionics" :: any)

local Zoom = {}

Zoom.RATE = 9 -- 1/s approach rate of log magnification

function Zoom.New()
    return { target = 1, current = 1 }
end

function Zoom.SetTarget(state: any, magnification: number)
    state.target = math.max(1, magnification)
end

function Zoom.Step(state: any, dt: number)
    local a = math.log(state.current)
    local b = math.log(state.target)
    if math.abs(a - b) < 1e-3 then
        state.current = state.target
        return
    end
    a += (b - a) * (1 - math.exp(-Zoom.RATE * math.max(dt, 0)))
    state.current = math.exp(a)
end

-- Immediate return to 1x.
function Zoom.Reset(state: any)
    state.target, state.current = 1, 1
end

function Zoom.Fov(state: any, baseFov: number): number
    return Avionics.Fov(baseFov, state.current)
end

-- Head-look sensitivity scale: aiming stays equally precise on screen at any magnification.
function Zoom.LookScale(state: any): number
    return 1 / state.current
end

function Zoom.IsZoomed(state: any): boolean
    return state.current > 1.02 or state.target > 1
end

return Zoom
