-- Run on the SERVER during Play. Production Locomotion + EnergySystems + Weapons with the AUTOCANNON preset
-- (laser left_arm=1, Mauler right_arm=2, MG-9 left_shoulder=3). Compares profiles under identical sprint+fire demand.
local Server, Shared = game.ServerScriptService.IronframeServer, game.ReplicatedStorage.IronframeShared
local Weapons, Systems, Targets = require(Server.Weapons), require(Server.EnergySystems), require(Server.CombatTargets)
local Compiler, Loadouts, Profiles = require(Shared.LoadoutCompiler), require(Shared.Loadouts), require(Shared.EnergyProfiles)
local Locomotion = require(Server.Locomotion)
local range = Instance.new("Folder")
range.Name, range.Parent = "M09TestTargets", workspace
Targets.Build(range, Vector3.new(1000, 0, 0))
local target = range:FindFirstChild("RangeDrone1", true)
local out = {}
local function rig(profile, held)
    local model = Instance.new("Model")
    model.Name, model.Parent = "M09Check", workspace.IronframeMechs
    model:SetAttribute("Deployment", "ACTIVE"); model:SetAttribute("State", "OPERATIONAL")
    local c = Locomotion.Create(model, "IF42_BASTION", Vector3.new(target.Position.X, 0, target.Position.Z - 70), math.pi)
    Locomotion.SetLocked(c, false)
    local session = { mech = model, controller = c, machineState = "OPERATIONAL", deployment = "ACTIVE", loadout = Loadouts.presets.AUTOCANNON }
    session.power = Systems.Create(model, Compiler.Compile(session.loadout).energy, profile)
    c.energySystems = session.power
    Weapons.Create(session)
    return session, model, c
end
local effects = { FireAllClients = function() end }
local function run(profile, seconds, sprint, sockets)
    local session, model, c = rig(profile)
    local sprintSum, n, shots0 = 0, 0, 0
    local t0 = os.clock()
    local socketIndex = 1
    local shots = { 0, 0, 0 }
    while os.clock() - t0 < seconds do
        -- rotate fire selection across the requested hardpoints each frame
        local want = sockets[(socketIndex % #sockets) + 1]; socketIndex += 1
        Locomotion.SetInput(c, 1, 0, sprint)
        Locomotion.Step(c, 1 / 60)
        session.weapons.lastPacket = -100
        Weapons.Intent(session, want, true, target.Position, false)
        Weapons.Step(session, effects)
        sprintSum += session.power.sprintFraction; n += 1
        task.wait()
    end
    local r = {
        sprint = sprintSum / math.max(n, 1), charge = session.power.energy.charge, thermal = session.power.energy.thermal,
        shots = session.weapons.shots, state = session.weapons.reason, limited = Systems.Limited(session.power),
        speed = c.state.speed, ledger = session.power.energy.ledger,
    }
    r.balance = r.ledger.initial + r.ledger.generated - (r.charge + r.ledger.consumed + r.ledger.loss + r.ledger.wasted)
    Locomotion.Destroy(c); model:Destroy()
    return r
end
local ok, err = pcall(function()
    Targets.Step(os.clock() + 100)
    for _, id in ipairs(Profiles.Order) do
        out[id] = run(id, 5, true, { 1, 2, 3 })
        assert(math.abs(out[id].balance) < 1e-3, "ledger " .. id)
    end
    out.lowDemand = {}
    for _, id in ipairs(Profiles.Order) do out.lowDemand[id] = run(id, 3, false, { 3 }) end
    -- switching: server authority, delay, cooldown, invalid ids
    local session, model, c = rig(nil)
    local p = session.power
    local r = {}
    r.invalid = { Systems.RequestProfile(p, "NOPE") }
    r.locked = { Systems.RequestProfile(p, "OVERDRIVE") }
    r.first = { Systems.RequestProfile(p, "WEAPONS") }
    r.dup = { Systems.RequestProfile(p, "MOBILITY") }
    local before = p.energy.charge; local thermal = p.energy.thermal
    for _ = 1, 20 do Locomotion.Step(c, 1 / 60); task.wait() end
    r.midActive = p.profile.active
    for _ = 1, 40 do Locomotion.Step(c, 1 / 60); task.wait() end
    r.afterActive = p.profile.active
    r.cooldown = { Systems.RequestProfile(p, "MOBILITY") }
    r.thermalKept = p.energy.thermal >= 0 and p.energy.charge <= before + 1
    -- eject during pending switch
    task.wait(2.1); r.again = { Systems.RequestProfile(p, "MOBILITY") }
    Systems.Cancel(p); r.afterCancel = { pending = p.profile.pending, active = p.profile.active }
    -- redeploy resets to default
    Systems.ResetProfile(p); r.reset = p.profile.active
    out.switching = r
    Locomotion.Destroy(c); model:Destroy()
end)
range:Destroy()
if not ok then return "FAIL: " .. tostring(err) end
local lines = {}
for _, id in ipairs(Profiles.Order) do
    local r = out[id]
    table.insert(lines, string.format("%s sprint=%.3f shots=%d charge=%.1f thermal=%.1f state=%s limited=%s bal=%.5f", id, r.sprint, r.shots, r.charge, r.thermal, r.state, r.limited, r.balance))
    local l = out.lowDemand[id]
    table.insert(lines, string.format("  low-demand MG: shots=%d charge=%.1f state=%s", l.shots, l.charge, l.state))
end
local s = out.switching
table.insert(lines, string.format("invalid=%s locked=%s first=%s dup=%s mid=%s after=%s cooldown=%s,%s again=%s,%s cancel=%s/%s reset=%s",
    tostring(s.invalid[1]), tostring(s.locked[2]), tostring(s.first[1]), tostring(s.dup[2]), s.midActive, s.afterActive,
    tostring(s.cooldown[1]), tostring(s.cooldown[2]), tostring(s.again[1]), tostring(s.again[2]), tostring(s.afterCancel.pending), s.afterCancel.active, s.reset))
return table.concat(lines, "\n")
