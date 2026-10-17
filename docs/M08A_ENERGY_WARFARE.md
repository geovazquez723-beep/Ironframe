# M08A — Energy Warfare & Pulse Shield

Built from clean M07 `b90cca4` on `feature/m08a-energy-warfare`. The existing server hull, collision sweeps, deployment rules, 14-joint rig, six sockets, ten hydraulic links, three loadouts, cockpit and cloud asset references are preserved. No weapons, combat health, AI or new meshes were introduced.

## Resource architecture

`EnergyConfig.Build` compiles chassis balance and installed reactor/capacitor/cooling/shield components into runtime configuration. The loadout compiler accepts capacitor and shield slots, supplies the chassis's integrated defaults for legacy presets, accounts for upgrade mass and rejects wrong-class or unknown components. Integrated default hardware is already included in chassis dry mass, preserving the existing preset masses.

`Energy` is a pure numeric ledger. Continuous requests are rates submitted for the next step; they expire after that step. Categories are prioritized independently of submission order: idle, basic propulsion, shield sustain, weapons, sprint. Each request draws from the same remaining reactor supply and then the same capacitor balance. Unused reactor output can charge the capacitor, with conversion loss and charging limits. A shared discharge token bucket constrains discrete bursts and continuous capacitor draw. Lifetime totals track generated energy, consumption, conversion loss, unused supply and stored charge, permitting conservation assertions.

The ledger clamps elapsed integration to 0.25 seconds and subdivides at 120 Hz. Locomotion advances its existing drive/collision model in bounded 60 Hz substeps, feeding measured speed/acceleration and authoritative input to the resource adapter. Energy fulfillment adjusts the existing forward-speed and acceleration targets; steering and braking retain their M07 behavior. Empty reserves reduce sprint assistance; a conservative basic-drive floor protects controllability. Starvation never teleports or locks the chassis.

Thermal load reduces effective output and recharge efficiency above 40%, and high strain slows cooling recovery. It never damages components, ejects the pilot or alters physical integrity. Resource state survives normal docking/redeployment; rebuilding or changing a stowed loadout assembles fresh hardware and resources. Reactor output is zero while stowed/starting/evacuated; there is no hidden hangar recharge source.

### Starting balance

| Parameter | Default |
|---|---:|
| Core 220 output | 80 units/sec |
| Core 300 upgrade output | 120 units/sec |
| Integrated capacitor / initial charge | 160 / 160 units |
| High-density capacitor upgrade | 240 units, +1 tonne |
| Charging efficiency | 90% cold; 45% at maximum strain |
| Charge input limit | 50 units/sec, storing up to 45/sec cold |
| Continuous capacitor discharge limit | 100 units/sec |
| Discharge burst bucket | 60 units, refilling at 100/sec |
| Idle demand | 8 units/sec |
| Normal steady forward demand | 34 propulsion + 8 idle = 42/sec |
| Acceleration demand | 2.4 units/sec per stud/sec² |
| Steering demand | Up to 10 units/sec |
| Braking demand | 0.35 × measured speed, plus motor/acceleration demand |
| Sprint request | Additional 100 units/sec |
| Fully funded sprint targets | 1.6× forward speed; 1.35× forward acceleration |
| Thermal threshold / maximum | 40% / 100% |
| Maximum reactor derating | 45%, leaving 44 units/sec on Core 220 |
| Standard cold cooling | 10.8 thermal points/sec; reduced as strain rises |
| Diagnostic weapon load | 100 units/sec for 2 seconds |

Balance is in `ChassisRegistry`, `ComponentRegistry` and `EnergyConfig`, not embedded in the locomotion controller. With this capacitor budget, a standing-start sprint measured approximately 20 studs/sec before reserves depleted; 25.6 is the fully funded speed target, not a promised sustained speed.

## Pulse defense

`PulseShield` is a pure state machine:

`READY → CHARGING → PERFECT_GUARD → ACTIVE → RECOVERY → COOLDOWN → READY`

Activation requires ACTIVE deployment, a ready generator and sufficient capacitor charge/discharge budget. It immediately spends 25 units. Timing is 0.15 seconds charging, 0.25 perfect guard, 0.5 ordinary protection, 0.25 recovery, then 4 seconds cooldown. Thus the complete normal rearm cycle is approximately 5.15 seconds. Cancellation or an early break retains the original cooldown deadline. Unfunded sustain ends protection early.

The default generator has 180 integrity, 50 units/sec sustain demand and a 130-degree forward cone. Ordinary baseline mitigation is ballistic 65%, laser 80%, plasma 50%, missile 40%, attenuated near cone edges and modified by generator quality. Perfect guard multiplies effectiveness by 1.45 (capped at 98%) and halves impact energy cost. Ordinary protection is capped at 82%. Impact energy costs 0.18 units per damage prevented normally, 0.09 during perfect guard. Integrity and actual energy available bound the amount prevented; rear, charging and expired attacks receive no protection. A shield is temporary defense rather than a health bonus.

### Server interfaces

```lua
-- Pure ledger, usable by future authoritative systems:
Energy.Request(power.energy, "weapons", rate)       -- continuous units/sec for the next step
Energy.Spend(power.energy, activationCost)         -- all-or-nothing stored-energy burst
Energy.Consume(power.energy, amount, true)         -- actual partial consumption

-- Server adapter; accepts continuous requests only on an active deployed model:
EnergySystems.RequestPower(power, "weapons", rate)

-- Trusted server attack resolver; returns prevented/penetrating damage, timing,
-- energy actually spent and remaining shield integrity. It does not change mech health.
EnergySystems.ResolveImpact(power, {
    damage = 60,
    category = "laser", -- ballistic, laser, plasma or missile
    fromX = sourceDirection.X,
    fromZ = sourceDirection.Z,
}, authoritativeYaw)
```

The direction points from the victim toward the attacker in world space. No remote accepts client damage, hit locations, costs, timing windows or mitigation multipliers. Shield activation has an input rate limit and authoritative state/cost checks. Test requests accept only server-defined pattern names with throttling and range/deployment checks.

## Controls and test range

- Existing WASD drive, V camera switch, R recenter, F enter/deploy/return and X safe ejection remain.
- **Left Shift + W:** sprint.
- **G:** activate pulse shield; the right-side button shows readiness/cooldown and low-capacitor unavailability.
- **H:** schedule the selected diagnostic impact.
- **J:** cycle LASER, BALLISTIC, PLASMA and REAR_MISSILE test patterns.
- **K:** request the diagnostic weapon-load simulation.

The existing proving ground gained one small roadside console/sign. Diagnostics work outdoors between z=70 and z=320. Impacts are nominally 60 damage and occur 1.5 seconds after scheduling; a live ETA is displayed. Pressing G around 1.2 seconds after H places the impact in the perfect window. Direction is fixed from the chassis heading at scheduling, allowing turning counterplay. Feedback reports category, timing, prevention, penetration, energy consumed and remaining integrity. Outcomes are diagnostic only, with no combat-health mutation.

## Visuals and cockpit

ShieldClient renders a lightweight forward hex barrier from procedural glass cells, neon emitter edges/scan rails and a pulse ring. It grows while charging, brightens for perfect guard, flashes warm at a perfect impact and dissipates in recovery. It follows the existing smoothed chassis frame while walking, steering or sprinting. All effect parts are anchored, non-colliding and non-queryable. The effect uses 31 parts plus its model/light during an activation and removes them afterward; no screen-space refraction is assumed.

The existing center reactor MFD now shows actual demand/effective output, capacitor charge/capacity, thermal load, used reactor supply, signed capacitor flow, propulsion and simulated weapon demand, shield state/cooldown and deficit/unavailability messages. The old DEMO RPM readout was removed. Structure, armament and unimplemented combat feeds retain their existing LIVE-equipment/STANDBY/DEMO distinctions. New measurements use the existing Telemetry bus and rounded server attributes at approximately 10 Hz. The exterior status strip is hidden in cockpit mode so it cannot cover the instruments.

## Pilot safety and lifecycle

Ejection still establishes pilot safety before mech callbacks. Resource/shield cancellation is isolated so it cannot interrupt evacuation. The existing server loop stops moving an evacuated mech immediately; shield protection ends, pending impacts and simulated weapon demand are cleared, and visual effects collapse. Recovery produces one stationary mech with fresh capacitor/shield state and restores the cockpit. Return cancels shield/actions without resetting the old generator's cooldown or granting a free capacitor refill.

## Verification executed

- **28/28** existing standalone locomotion/gait/deployment/ejection tests passed.
- **27/27** new standalone tests passed: conservation, continuous/discrete demand, limits, malformed values, charging, thermal effects, frame partitioning, priorities, empty-reserve movement, sprint, state/timing boundaries, cancellation, quality, direction, categories, exhaustion and sprint gait.
- **24/24** Studio regression tests passed: all 22 previous cases plus component compilation/upgrades and invalid resource components.
- All **48 Luau files compiled** without syntax failures. Stock analysis produced no non-platform diagnostics after filtering unknown Roblox globals/types; this is not a Roblox-aware strict typecheck.
- Rojo built `build/Ironframe-M08A.rbxl`; source synchronization was verified in the existing `Ironframe.rbxl`. Existing 21/21 cloud assets still loaded.
- `tools/m07_studio_checks.luau` passed the actual query-engine container/marker/hill/barrier/input regressions.
- `tools/m08a_studio_checks.luau` passed integrated server checks using temporary controllers and the real M07 collision path. Sprint peaked at 20.00, depleted reserves and recovered to 160 after braking/idle. After 1.6 seconds, sprint alone retained 44.70 units while sprint plus shield had zero. Stationary simulated weapons received 100/sec at total demand 108. An empty capacitor retained 9.33 studs/sec while accelerating, rejected the shield and denied sprint assistance under competing weapon demand. Maximum thermal strain derated output to approximately 44.06 without defeating the mech. Unfunded shield sustain entered RECOVERY.
- Actual player controls reached 16 studs/sec at demand 42, exited the hangar and traversed the field. Sprint measured 20.1; simultaneous simulated weapon load raised requested demand to approximately 245.7, reduced sprint speed and produced a clean low-energy shield refusal. Idle restored 160 charge and lowered thermal load.
- Actual scheduled impacts produced laser PERFECT 58.8 prevented / 1.2 penetrating / 5.292 energy, laser GUARD 48/12/8.64, plasma GUARD 30/30/5.4 and rear missile OFF_AXIS 0/60/0. Repeated activation during an active/cooling cycle did not increment activation serial.
- Actual keyboard Left Shift+W consumed reserves and raised thermal load; keyboard G activated the shield. Cockpit screenshots verified the live MFD and unobstructed instruments, and the external shield effect was inspected.
- Outdoor return restored STOWED with capacitor charge and cooldown preserved. Redeployment/recovery succeeded. Ejection during PERFECT_GUARD while sprinting and steering immediately reported safe/PILOT_EVACUATED/EJECTED, then recovered one mech with 160 charge, READY shield, no hull and zero shield-effect models. The moving shield's observed alignment error was 0.38 studs with a heading dot product of 0.99995.

The integration test initially expected complete sprint braking within four seconds; measured speed was 0.091 with 156.9 charge. The test now allows five seconds, consistent with the inherited deliberate braking behavior, and verifies exact zero speed/full recovery.

Run offline suites with `luau tools/offline_tests.luau` and `luau tools/energy_tests.luau` (`tools/check.sh` includes both). Run the Studio check chunks on the server during Play after Bay_1 exists; they clean up their temporary controllers/models.

## Performance and limits

Observed smoothed server drive step time was approximately 0.05 ms for one deployed mech, and the existing cockpit loop approximately 0.5 ms in this Studio session. These are observations, not a multi-client or GPU benchmark. Effects exist only during activation/recovery, and cleanup was checked after ejection. Replicated state is rate-limited; clients render the cosmetic barrier locally.

This remains a keyboard-focused prototype. No real weapon trajectories, combat-health/component damage, hit points on the barrier, multiplayer latency compensation, client prediction, mobile/gamepad driving or production balance pass were implemented. Diagnostic impacts use known source directions rather than projectiles; the impact flash is centered on the barrier. Server timing is authoritative, so visual feedback can lag under network latency. M07's compact body hull and sagittal foot gait retain their documented cosmetic limitations. Existing Studio CorePackages and legacy asset-type warnings remain; cloud references were preserved.

Recommended next milestone: **M08B — one authoritative energy weapon and server-owned target dummies**, using this same request ledger and mitigation interface, followed by latency/timing validation before broader combat or component damage work.

All work is local. No publish, push or pull request was performed.
