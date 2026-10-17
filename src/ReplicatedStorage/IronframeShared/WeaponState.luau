-- Pure firing rules. Only the server supplies definitions, clocks, aim validation and payment.
local Weapon = {}
function Weapon.New(mounts, components)
    local s = { slots = {}, shots = 0, hits = 0, reason = "SAFE" }
    for socket, id in pairs(mounts) do
        local component = components[id]
        local spec = component and component.combat
        if spec and spec.hardpoints[socket] then
            s.slots[socket] = { id = id, spec = spec, ammo = spec.magazine, nextShot = 0, reloadAt = nil }
        end
    end
    return s
end
function Weapon.Advance(s, now)
    for _, slot in pairs(s.slots) do
        if slot.reloadAt and now >= slot.reloadAt then
            slot.ammo, slot.reloadAt = slot.spec.magazine, nil
        end
    end
end
function Weapon.Reload(s, socket, now, enabled)
    local slot = s.slots[socket]
    if not enabled or not slot or slot.spec.magazine == 0 or slot.reloadAt or slot.ammo == slot.spec.magazine then return false end
    slot.reloadAt = now + slot.spec.reload
    return true
end
function Weapon.Fire(s, socket, now, enabled, validAim, pay)
    local slot = s.slots[socket]
    local reason
    if not enabled then reason = "SAFE"
    elseif not slot then reason = "UNAVAILABLE"
    elseif not validAim then reason = "AIM LIMIT"
    elseif slot.reloadAt then reason = "RELOADING"
    elseif now < slot.nextShot then reason = "COOLDOWN"
    elseif slot.spec.magazine > 0 and slot.ammo < slot.spec.ammoPerShot then
        Weapon.Reload(s, socket, now, enabled); reason = "RELOADING"
    end
    if reason then s.reason = reason; return false end
    -- An unfunded attempt is rate limited too. No ammo, heat or energy is spent on rejection.
    slot.nextShot = now + slot.spec.interval
    if not pay(slot.spec.energy, slot.spec.heat) then s.reason = "ENERGY LOW"; return false end
    slot.ammo -= slot.spec.ammoPerShot
    s.shots += 1
    s.reason = "FIRING"
    return true
end
return Weapon
