-- Shared mount frame; server uses the authoritative chassis, clients use their animated joint pose.
local RigSpec = require(script.Parent.RigSpec)
local Geometry = {}
function Geometry.Mount(world, socket, aim)
    local spec = RigSpec.Sockets[socket]
    local mount = world[spec.joint] * RigSpec.SocketLocalCF(socket)
    if aim and (aim - mount.Position).Magnitude > 1 then
        mount = CFrame.lookAt(mount.Position, aim, mount.UpVector)
    end
    return mount
end
return Geometry
