-- Server-owned firing cadence, magazine, muzzle transform and raycast. Input is intent + world aim only.
local Shared = game.ReplicatedStorage.IronframeShared
local Components = require(Shared.ComponentRegistry)
local State = require(Shared.WeaponState)
local RigSpec = require(Shared.RigSpec)
local Rig = require(Shared.MechRig)
local Geometry = require(Shared.WeaponGeometry)
local Energy = require(Shared.Energy)
local Targets = require(script.Parent.CombatTargets)
local HitDebug = require(script.Parent.HitDebug)
local Destructibles = require(script.Parent.Destructibles)
local EnergySystems = require(script.Parent.EnergySystems)
local Weapons = {}
local function enabled(session)
    return session.machineState == "OPERATIONAL" and session.deployment == "ACTIVE" and session.controller ~= nil
        and session.mech ~= nil and session.mech.Parent ~= nil and session.mech:GetAttribute("State") == "OPERATIONAL"
end
function Weapons.Create(session)
    local s = State.New(session.loadout.mounts, Components)
    s.selected, s.held, s.lastInput, s.lastPacket, s.publishAt = 1,false,-100,-100,-100
    s.lastHit, s.lastDamage = "NONE",0
    session.weapons = s
end
local function finite(n) return n == n and math.abs(n) < 1e6 end
function Weapons.Intent(session, index, held, aim, reload)
    local s = session.weapons
    if not s then return end
    local now = os.clock()
    if held == false then s.held = false end -- release is always honored, even under packet limiting
    if now - s.lastPacket < 0.05 then return end
    s.lastPacket = now
    if not enabled(session) then s.held = false; return end
    if type(index) ~= "number" or index % 1 ~= 0 or not RigSpec.SocketOrder[index] then return end
    if type(held) ~= "boolean" or typeof(aim) ~= "Vector3" or not finite(aim.X) or not finite(aim.Y) or not finite(aim.Z) then return end
    s.selected, s.held, s.aim, s.lastInput = index,held,aim,now
    if reload == true then State.Reload(s,RigSpec.SocketOrder[index],now,true) end
end
function Weapons.Cancel(session)
    if session.weapons then session.weapons.held = false; session.weapons.reason = "SAFE" end
    if session.mech then session.mech:SetAttribute("WeaponAim",nil); session.mech:SetAttribute("WeaponState","SAFE") end
end
-- Surface normal at a ray hit on a mesh: a plane through the hit and four parallel probe rays 0.7 studs around it (only probes landing on the same
-- surface count). Falls back to the reported normal. Pure geometry; cheap (4 rays) and only evaluated for mesh hits.
local PROBE = 0.7
function Weapons.SurfaceNormal(result, origin, direction, params)
    local fallback = result.Normal
    local up = math.abs(direction.Y) > 0.95 and Vector3.new(1,0,0) or Vector3.new(0,1,0)
    local right = direction:Cross(up).Unit
    local top = right:Cross(direction).Unit
    local points = {}
    local distance = (result.Position-origin).Magnitude
    for i, offset in ipairs({right*PROBE, -right*PROBE, top*PROBE, -top*PROBE}) do
        local probe = workspace:Raycast(origin+offset,direction*(distance+3),params)
        if probe and math.abs((probe.Position-(origin+offset)).Magnitude-distance) < 1.6 then points[i] = probe.Position end
    end
    local a,b,c,d = points[1],points[2],points[3],points[4]
    if not (a and b and c and d) then return fallback end
    local n = (a-b):Cross(c-d)
    if n.Magnitude < 1e-4 then return fallback end
    n = n.Unit
    if n:Dot(-direction) < 0 then n = -n end
    if n:Dot(-direction) < 0.12 then return fallback end -- a grazing fit is unreliable
    return n
end
-- One hitscan shot: the world ray (the nearest queryable surface wins), then the damage path for whatever it struck. Shared by the live weapon step
-- and the server-only audit (`shoot`), so tests exercise the exact production path. `exclude` is the shooter's own model.
-- Returns { endpoint, normal?, damage, name, instance? }.
function Weapons.Strike(exclude, origin, direction, spec, weaponId, now)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude and {exclude} or {}
    local result = workspace:Raycast(origin,direction*spec.range,params)
    local endpoint = result and result.Position or origin + direction*spec.range
    -- A convex-decomposition mesh reports the normal of the convex piece it hit, which can lean well away from the visible surface in dishes and
    -- around rounded armour. Impact marks and sparks use a plane fitted to four neighbouring rays instead.
    local normal = result and result.Normal
    if result and result.Instance:IsA("MeshPart") then
        normal = Weapons.SurfaceNormal(result,origin,direction,params)
    end
    -- Fitted-volume machines (ROOK-01) have no parts to raycast: ask for the nearest analytic contact along the same ray. Cover (any nearer world
    -- surface) still wins, because the probe is limited to the world hit distance.
    local reach = result and result.Distance or spec.range
    local probe = Destructibles.Probe(origin,direction,reach)
    if probe and probe.t <= reach then
        local damage = Destructibles.HitVolume(probe,spec.category,spec.damage,{weapon=weaponId,origin=origin})
        HitDebug.Path(origin,probe.position,true)
        return {endpoint=probe.position,normal=probe.normal,damage=damage,name=probe.comp,comp=probe.comp}
    end
    local damage = result and Targets.Hit(result.Instance,spec.category,spec.damage,now,{weapon=weaponId,position=result.Position,normal=normal,origin=origin}) or 0
    HitDebug.Path(origin,endpoint,result ~= nil)
    return {endpoint=endpoint,normal=normal,damage=damage,name=result and result.Instance.Name or "",instance=result and result.Instance}
end
function Weapons.Step(session, effects)
    local s = session.weapons
    if not s or not session.mech then return end
    local now, model = os.clock(), session.mech
    local live = enabled(session)
    State.Advance(s,now)
    if not live or now - s.lastInput > 0.35 then s.held = false end
    local socket = RigSpec.SocketOrder[s.selected]
    local slot = s.slots[socket]
    -- M10B: a mount whose weapon assembly has failed is offline (BastionDamage keeps session.damageFx current).
    local disabled = slot ~= nil and session.damageFx ~= nil and session.damageFx.sockets[socket] == true
    model:SetAttribute("WeaponSocket",socket)
    model:SetAttribute("WeaponDisabled",disabled)
    local aimValid, origin, direction = false,nil,nil
    if live and slot and s.aim then
        local c = session.controller
        local root = CFrame.new(c.state.x,c.state.y,c.state.z) * CFrame.Angles(0,c.state.yaw,0) * CFrame.Angles(c.state.pitch,0,c.state.roll)
        local world = Rig.Solve(root)
        local mount = Geometry.Mount(world,socket,nil)
        local delta = s.aim - mount.Position
        aimValid = not disabled and delta.Magnitude > slot.spec.muzzle + 1 and delta.Magnitude < 2000
            and delta.Unit:Dot(root.LookVector) >= math.cos(math.rad(65))
        if aimValid then
            local aimed = Geometry.Mount(world,socket,s.aim)
            origin = (aimed * CFrame.new(0,0,-slot.spec.muzzle)).Position
            direction = aimed.LookVector
            model:SetAttribute("WeaponAim",s.aim)
            -- A separate mount-to-muzzle sweep prevents firing through cover next to the barrel.
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {model}
            if workspace:Raycast(mount.Position,origin-mount.Position,params) then aimValid = false end
        else model:SetAttribute("WeaponAim",nil) end
    end
    if disabled then s.held = false end
    if s.held then
        local fired = State.Fire(s,socket,now,live,aimValid,function(cost,heat)
            local e = session.power.energy
            if Energy.Consume(e,cost,false,0,"weapons") ~= cost then
                -- Distinguish a profile reserve from a genuinely empty capacitor for the cockpit.
                s.reserved = math.min(e.charge,e.tokens) + 1e-8 >= cost
                EnergySystems.NoteWeaponLimited(session.power)
                return false
            end
            e.thermal = math.clamp(e.thermal + heat,0,session.power.config.thermalMaximum)
            return true
        end)
        if fired then
            local spec = slot.spec
            local strike = Weapons.Strike(model,origin,direction,spec,slot.id,now)
            if strike.damage > 0 then s.hits += 1; s.lastHit = strike.name; s.lastDamage = strike.damage; s.dealt = (s.dealt or 0) + strike.damage end
            local shotAt = workspace:GetServerTimeNow()
            model:SetAttribute("WeaponShotAt",shotAt)
            effects:FireAllClients(model,socket,slot.id,origin,strike.endpoint,strike.normal or -direction,strike.damage)
        end
        if s.reason == "ENERGY LOW" and s.reserved then s.reason = "RESERVED" end
    else s.reason = if not live then "SAFE" elseif not slot then "UNAVAILABLE" elseif slot.reloadAt then "RELOADING" elseif now < slot.nextShot then "COOLDOWN" else "READY" end
    if disabled then s.reason = "DISABLED" end
    if now-s.publishAt < 0.1 then return end
    s.publishAt = now
    local spec = slot and slot.spec
    local values = {
        WeaponSelected=s.selected, WeaponName=slot and Components[slot.id].name or "UNIMPLEMENTED HARDPOINT",
        WeaponState=s.reason, WeaponMode=spec and spec.mode or "SAFE", WeaponAmmo=slot and slot.ammo or -1,
        WeaponMagazine=spec and spec.magazine or 0, WeaponPower=spec and spec.energy/spec.interval or 0,
        WeaponCost=spec and spec.energy or 0, WeaponHeat=spec and spec.heat/spec.interval or 0,
        WeaponCooldown=slot and math.max(0,slot.nextShot-now) or 0, WeaponReload=slot and slot.reloadAt and math.max(0,slot.reloadAt-now) or 0,
        WeaponAvailable=spec and Energy.Available(session.power.energy,"weapons") >= spec.energy or false,
        WeaponShots=s.shots, WeaponHits=s.hits, WeaponLastTarget=s.lastHit, WeaponLastDamage=s.lastDamage,
    }
    for key,value in pairs(values) do if model:GetAttribute(key) ~= value then model:SetAttribute(key,value) end end
    for key, v in pairs(s.slots) do model:SetAttribute("Ammo_"..key,v.ammo) end
end
return Weapons
