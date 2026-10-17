-- Server-owned firing cadence, magazine, muzzle transform and raycast. Input is intent + world aim only.
local Shared = game.ReplicatedStorage.IronframeShared
local Components = require(Shared.ComponentRegistry)
local State = require(Shared.WeaponState)
local RigSpec = require(Shared.RigSpec)
local Rig = require(Shared.MechRig)
local Geometry = require(Shared.WeaponGeometry)
local Energy = require(Shared.Energy)
local Targets = require(script.Parent.CombatTargets)
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
function Weapons.Step(session, effects)
    local s = session.weapons
    if not s or not session.mech then return end
    local now, model = os.clock(), session.mech
    local live = enabled(session)
    State.Advance(s,now)
    if not live or now - s.lastInput > 0.35 then s.held = false end
    local socket = RigSpec.SocketOrder[s.selected]
    local slot = s.slots[socket]
    model:SetAttribute("WeaponSocket",socket)
    local aimValid, origin, direction = false,nil,nil
    if live and slot and s.aim then
        local c = session.controller
        local root = CFrame.new(c.state.x,c.state.y,c.state.z) * CFrame.Angles(0,c.state.yaw,0) * CFrame.Angles(c.state.pitch,0,c.state.roll)
        local world = Rig.Solve(root)
        local mount = Geometry.Mount(world,socket,nil)
        local delta = s.aim - mount.Position
        aimValid = delta.Magnitude > slot.spec.muzzle + 1 and delta.Magnitude < 2000
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
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {model}
            local spec = slot.spec
            local result = workspace:Raycast(origin,direction*spec.range,params)
            local endpoint = result and result.Position or origin + direction*spec.range
            local damage = result and Targets.Hit(result.Instance,spec.category,spec.damage,now) or 0
            if damage > 0 then s.hits += 1; s.lastHit = result.Instance.Name; s.lastDamage = damage end
            local shotAt = workspace:GetServerTimeNow()
            model:SetAttribute("WeaponShotAt",shotAt)
            effects:FireAllClients(model,socket,slot.id,origin,endpoint,result and result.Normal or -direction,damage)
        end
        if s.reason == "ENERGY LOW" and s.reserved then s.reason = "RESERVED" end
    else s.reason = if not live then "SAFE" elseif not slot then "UNAVAILABLE" elseif slot.reloadAt then "RELOADING" elseif now < slot.nextShot then "COOLDOWN" else "READY" end
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
