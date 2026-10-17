-- Pure normalized recoil envelope and collision response; no changes to gameplay pose/hit resolution.
local Motion = {}
function Motion.Recoil(age, spec)
    if age < 0 or age >= spec.recoverTime then return 0 end
    if age < spec.kickTime then return age / spec.kickTime end
    local t = (age - spec.kickTime) / (spec.recoverTime - spec.kickTime)
    return (1 - t) * (1 - t)
end
function Motion.Bounce(x,y,z,nx,ny,nz,restitution,friction)
    local dot=x*nx+y*ny+z*nz
    -- Split normal/tangent velocity: modest restitution, strong metallic-floor friction.
    return (x-dot*nx)*friction-dot*nx*restitution,
        (y-dot*ny)*friction-dot*ny*restitution,
        (z-dot*nz)*friction-dot*nz*restitution
end
return Motion
