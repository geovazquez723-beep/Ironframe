local Target = {}
function Target.New(armor)
    return { health = 600, capacity = 600, hits = 0, damage = 0, lastHit = nil, armor = armor, resets = 0 }
end
function Target.Hit(s, category, damage, now)
    if s.health <= 0 or (category ~= "laser" and category ~= "ballistic") then return 0 end
    local multiplier = if s.armor == "ABLATIVE" and category == "laser" then 0.65 elseif s.armor == "PLATE" and category == "ballistic" then 0.65 else 1
    local dealt = math.min(s.health, damage * multiplier)
    s.health -= dealt; s.damage += dealt; s.hits += 1; s.lastHit = now
    return dealt
end
function Target.Step(s, now)
    if s.lastHit and now - s.lastHit >= (if s.health <= 0 then 8 else 15) then
        s.health, s.hits, s.damage, s.lastHit = s.capacity, 0, 0, nil
        s.resets += 1
        return true
    end
    return false
end
return Target
