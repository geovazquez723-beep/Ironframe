-- Pure authoritative state for one destructible unit (a wall module, a barrier, a tank component, a mech limb).
-- No Roblox types and no side effects, so the server uses it directly and offline tests cover it exhaustively.
--
--   INTACT ──health <= damagedAt*capacity──▶ DAMAGED ──health <= 0──▶ DESTROYED      (Reset returns to INTACT)
--
-- A unit never regenerates by itself. Reset is an explicit range operation.

-- Sibling require that works both in Roblox (script.Parent) and under the Luau CLI used by the offline tests.
local Config = if script then require((script :: any).Parent.DestructionConfig) else require("./DestructionConfig" :: any)

local Unit = {}

export type Unit = {
    material: string,
    capacity: number,
    health: number,
    stage: string,
    hits: number,
    damageTaken: number,
    resist: { [string]: number },
    damagedAt: number,
    resets: number,
}

-- spec: { material = "CONCRETE", hp = 420?, resist = { HEAVY = 2 }?, damagedAt = 0.5? }  (overrides are per object)
function Unit.New(spec: { material: string, hp: number?, resist: { [string]: number }?, damagedAt: number? }): Unit
    local material = assert(Config.materials[spec.material], "unknown destruction material " .. tostring(spec.material))
    local resist = table.clone(material.resist)
    if spec.resist then
        for class, value in pairs(spec.resist) do
            resist[class] = value
        end
    end
    local capacity = spec.hp or material.hp
    assert(capacity > 0, "destructible health must be positive")
    return {
        material = spec.material,
        capacity = capacity,
        health = capacity,
        stage = "INTACT",
        hits = 0,
        damageTaken = 0,
        resist = resist,
        damagedAt = spec.damagedAt or material.damagedAt,
        resets = 0,
    }
end

function Unit.StageFor(u: Unit): string
    if u.health <= 0 then
        return "DESTROYED"
    elseif u.health <= u.damagedAt * u.capacity then
        return "DAMAGED"
    end
    return "INTACT"
end

function Unit.Multiplier(u: Unit, weaponClass: string): number
    return u.resist[weaponClass] or 1
end

-- Applies `rawDamage` from a weapon of `weaponClass`. Returns (dealt, oldStage, newStage). A destroyed unit takes nothing.
-- `scale` is an extra factor used by splash (the resistance table still applies on top).
function Unit.Hit(u: Unit, weaponClass: string, rawDamage: number, scale: number?): (number, string, string)
    local old = u.stage
    if u.health <= 0 or rawDamage ~= rawDamage or rawDamage <= 0 then
        return 0, old, old
    end
    local dealt = math.min(u.health, rawDamage * (scale or 1) * Unit.Multiplier(u, weaponClass))
    if dealt <= 0 then
        return 0, old, old
    end
    u.health -= dealt
    if u.health < 1e-6 then
        u.health = 0
    end
    u.damageTaken += dealt
    u.hits += 1
    u.stage = Unit.StageFor(u)
    return dealt, old, u.stage
end

-- Forces the unit to the destroyed state (support loss). Returns the health removed.
function Unit.Destroy(u: Unit): number
    local removed = u.health
    u.health = 0
    u.damageTaken += removed
    u.stage = "DESTROYED"
    return removed
end

function Unit.Reset(u: Unit)
    u.health = u.capacity
    u.stage = "INTACT"
    u.hits = 0
    u.damageTaken = 0
    u.resets += 1
end

-- Fraction of health left, 0..1.
function Unit.Fraction(u: Unit): number
    return math.clamp(u.health / u.capacity, 0, 1)
end

-- Support graph -----------------------------------------------------------------------------------------------------------
-- nodes: { [id] = { destroyed: boolean, supports: { id }? } }. A node with supports collapses as soon as ANY listed support
-- is destroyed (cantilever rule: a beam losing one column drops, a panel losing the course beneath it drops). Returns the ids
-- that should now collapse, nearest-first order is the caller's job. Pure and cycle-safe: a node is reported once.
function Unit.Unsupported(nodes: { [any]: { destroyed: boolean, supports: { any }? } }): { any }
    local out = {}
    for id, node in pairs(nodes) do
        if not node.destroyed and node.supports then
            for _, support in ipairs(node.supports) do
                local other = nodes[support]
                if other and other.destroyed then
                    table.insert(out, id)
                    break
                end
            end
        end
    end
    return out
end

return Unit
