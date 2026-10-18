-- Compact engineering feedback (M11A): what did this build do on its last sortie? One small table per sortie, built from counters the
-- runtime already keeps (weapon hits, applied damage, the energy ledger, the damage model, the MECH TRIAL events). No analytics layer:
-- the table lives on the session and is shown in the garage as "LAST SORTIE".
--
--   Begin(session)               at deploy        snapshot the counters
--   Tick(session)                every frame      peak thermal load (cheap: one number)
--   NoteTrialStart / NoteRookDown                 MECH TRIAL started; ROOK-01 disabled (time to defeat)
--   Finish(session, outcome)     docking / eject  freeze the report into session.lastSortie

local SortieReport = {}

local Damage = require(game:GetService("ReplicatedStorage"):WaitForChild("IronframeShared"):WaitForChild("MechDamage"))
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("IronframeShared"):WaitForChild("CombatConfig"))

local function round(n: number): number
    return math.floor(n + 0.5)
end

function SortieReport.Begin(session)
    local power, weapons = session.power, session.weapons
    session.sortie = {
        config = session.compiled and session.compiled.label or "?", startedAt = os.clock(),
        dealt0 = weapons and weapons.dealt or 0, received0 = session.received or 0,
        spent0 = power and power.energy.ledger.consumed or 0, peakThermal = 0, limited = 0,
        trialAt = nil, rookSeconds = nil, rookReason = nil, trials = 0,
    }
end

function SortieReport.Tick(session, dt: number)
    local s, power = session.sortie, session.power
    if s and power then
        s.peakThermal = math.max(s.peakThermal, power.energy.thermal)
        if power.weaponLimitedUntil and power.clock < power.weaponLimitedUntil then
            s.limited += dt -- seconds the weapons were held back by the capacitor / profile reserve
        end
    end
end

function SortieReport.NoteTrialStart(session)
    local s = session and session.sortie
    if s then
        s.trialAt, s.rookSeconds, s.rookReason = os.clock(), nil, nil
        s.trials += 1
    end
end

function SortieReport.NoteRookDown(session, reason: string)
    local s = session and session.sortie
    if s and s.trialAt and not s.rookSeconds then
        s.rookSeconds, s.rookReason = os.clock() - s.trialAt, reason
    end
end

-- Freezes and returns the report (also stored as session.lastSortie).
function SortieReport.Finish(session, outcome: string)
    local s = session.sortie
    if not s then
        return nil
    end
    local weapons, power, state = session.weapons, session.power, session.damage
    local disabled = {}
    if state then
        for _, region in ipairs(Damage.Regions) do
            if state.health[region] <= 0 then
                table.insert(disabled, Config.mech.names[region])
            end
        end
    end
    local report = {
        config = s.config, outcome = outcome, seconds = round(os.clock() - s.startedAt),
        dealt = round((weapons and weapons.dealt or 0) - s.dealt0), received = round((session.received or 0) - s.received0),
        spent = round((power and power.energy.ledger.consumed or 0) - s.spent0), peakThermal = round(s.peakThermal), limitedSeconds = round(s.limited * 10) / 10,
        disabled = disabled, trials = s.trials,
        rook = if s.rookSeconds then string.format("DEFEATED IN %ds (%s)", round(s.rookSeconds), s.rookReason or "") elseif s.trials > 0 then "NOT DEFEATED" else "NOT ENGAGED",
    }
    session.lastSortie = report
    session.sortie = nil
    return report
end

return SortieReport
