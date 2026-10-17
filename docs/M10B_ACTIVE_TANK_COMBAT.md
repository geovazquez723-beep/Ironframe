# M10B — Active Tank Combat & Mech Damage

Branch `feature/m10b-active-tank-combat` (from M10A `2785fa8`). Local commit only; nothing pushed, no PR.

Range 07 is now a solo combat-training environment. The three unmanned tanks (T-01 **Sentry**, T-02 **Heavy**, T-03 **Patrol**) detect,
track, warn and fire real, server-swept shells at the deployed IF-42 Bastion. Shells meet the existing directional pulse shield, the
energy economy and the destructible environment, and whatever gets through damages six mechanical regions of the Bastion, each
with a consequence. Core failure runs the existing guaranteed-safe ejection. Default mode is **PASSIVE RANGE** (M10A behaviour).

Screenshots (`docs/m10b/`, real Play session through the Studio MCP): `01` cockpit nominal (six-region STRUCTURE display), `02` patrol
tank charging its cannon (muzzle glow lights the hull), `03` heavy shell in flight with the closing guard ring and bearing chevron,
`04` live session alerts (TARGETED BY / UNSHIELDED HIT, two chevrons, GUARD ring, shell at the muzzle), `05` damaged Bastion (dead
right-hand mounts, smoke, darkened armour), `06` cockpit STRUCTURE display after heavy damage, `07` charred Bastion with smoke columns.

## 1. Architecture

| Piece | File | Role |
| --- | --- | --- |
| Config | `IronframeShared/CombatConfig` | three archetypes (ranges, delays, warning, reload, lead, spread, shell, armor), Bastion regions and consequences |
| Brain | `IronframeShared/TankBrain` | **pure** state machine `IDLE→DETECT→TRACK→AIM→FIRE→RELOAD→REPOSITION`, `DISABLED`, `RESET`; numbers in, instructions out |
| Damage model | `IronframeShared/MechDamage` | **pure** six-region Bastion model, hit-region map, effects, rig-part classification |
| Maths | `IronframeShared/CombatMath` | lead, ray-vs-box sweep, closest approach, relative bearing |
| Tank | `IronframeServer/TrainingTank` (extended) | archetype armor, muzzle pose, turret / hull API, brain per tank (respawn = fresh brain) |
| Combat | `IronframeServer/TankCombat` | perception, thinking, acting, shell manager, shield + damage resolution, mode, reset hook, audit |
| Bastion | `IronframeServer/BastionDamage` | applies the model to the real drive, reactor and weapon mounts; publishes `Dmg_*` attributes |
| Client | `TankFx`, `MechDamageFx`, `CombatHud`, `RangeHud` (extended), `CockpitHud` (extended) | telegraph, shells, impacts, damage visuals, alerts, mode control, six-region STRUCTURE MFD |

Authority is server-side throughout. The client receives `CombatFx` event arrays (`fire`, `end`) and replicated attributes; nothing
it computes can hit anything. Shells are **plain tables** (no server instances); each heartbeat a shell is swept with `Spherecast`
(world) and a ray-vs-hull-box test (the Bastion, the authoritative `Locomotion.HullPose`), and the nearer contact wins.

## 2. Enemy behaviour and targeting

State machine (all transitions are in `TankBrain`, offline-tested):

* **IDLE** scans / patrols as in M10A. **DETECT** (target in range with line of sight; the turret holds still while "acquiring").
  **TRACK** (turret slews at a limited rate, lead-corrected). **AIM** (turret locked on at a reduced slew rate, muzzle charging, targeting
  beam; exactly `warnTime`, then the shell leaves). **FIRE**, **RELOAD** (mobile tanks reposition). **REPOSITION** when no shot is
  possible (out of range, outside the traverse arc, or no line of fire). **DISABLED** is sticky: destroyed turret or hull. **RESET** while
  the district rebuilds.
* Perception per tank: horizontal range, traverse arc, and a line-of-sight ray from the real muzzle to three samples on the Bastion
  (torso, head, hips) against live geometry — destroyed cover is removed from the workspace, so lines of fire really change.
* **Valid target** = the pilot's Bastion that is deployed `ACTIVE`, `OPERATIONAL`, not evacuated, core intact, and in the `DISTRICT` zone.
  Hangar, staging, docked, ejected, escape capsule: never a target; everything in flight is cancelled.
* Component rules respected: no tracks / engine → no movement or pivot (still fires from where it stands); turret destroyed → DISABLED,
  never acquires or fires again; hull destroyed → DISABLED, stops.

| | Sentry T-01 | Patrol T-03 | Heavy T-02 |
| --- | --- | --- | --- |
| Mobility | fixed | drives its lane, slows to aim, stops in AIM / FIRE, keeps 85-130 studs | pivots its hull in place (10°/s) |
| Traverse (each side) | 115° (blind behind) | 100° | 90° (blind behind; ~12 s to pivot onto a flanker) |
| Detect / fire range | 185 / 175 | 175 / 150 | 200 / 190 |
| Acquire → warning → reload | 0.8 s → 0.9 s → 4.5 s | 0.7 s → 0.75 s → 5.5 s | 1.4 s → 1.2 s → 8.5 s |
| Shell | 70 dmg, 115 st/s, r 0.9 | 48 dmg, 105 st/s, r 0.8 | 150 dmg, 85 st/s, r 1.6 (bright, larger) |
| Cover damage (HEAVY class) | 55 | 40 | 120 |
| Lead (fraction of your velocity) | 0.20 | 0.25 | 0.15 |
| Aim spread | 1.3° | 1.8° | 1.0° |
| Armor | stock | stock | hull ×1.6, turret ×1.5, tracks / engine ×1.3 |

The first shell of an encounter is telegraphed three ways: the turret swings (first cue), the muzzle glow grows for the whole warning,
and a thin red targeting beam shows the barrel line for the last 45 %. After `armDelay` (2 s) from switching to ACTIVE nothing fires.

## 3. Incoming projectiles

* Fired from the actual muzzle (`TrainingTank.Muzzle`: hull root × turret weld × muzzle offset — exact on the frame the weld was written),
  along the real barrel direction plus a random cone. Verified: shell origin = muzzle position (0.00 studs) for all three tanks.
* Validated at discharge: tank intact, turret operational, district not resetting, shell cap (8) not reached.
* Bounded: per-shell life (`aim distance / speed + 1 s`, capped at 3.4-4.6 s), district box, and a cap of 8 in flight. Peak observed: 3.
* World hits go through `Destructibles.Hit` with weapon id `TANK_CANNON` (HEAVY class: cracks, craters, splash, collapse, exactly like the
  Mauler). Other tanks, the training mech, characters and the capsule are not in the sweep.
* Client: pooled tracers (8), impact bursts (6), tank telegraphs (3), one-shot sounds on throw-away emitters; trail, smoke, point light.
  Audio reuses existing uploaded assets only (Mauler report pitched down for the cannon, `zap` for shield events, metal hit for unshielded
  hits). **Not verified: any listening judgement.**

## 4. Shield and energy

No second shield system. A Bastion hit calls `EnergySystems.ResolveImpact` with `{category = "ballistic", damage, from = -shell direction}`
and the chassis yaw; only the **penetrating** remainder reaches a damage region. Verified in Studio (heavy shell, 150, calibrated 1.23 s
flight; the shield was raised through `EnergySystems.Activate`, the same call the G key makes):

| Case | Result |
| --- | --- |
| Press 0.275 s before impact | **PERFECT**: 141.3 blocked / 8.7 penetrating |
| Press 0.70 s before impact | **GUARD**: 97.4 blocked / 52.6 penetrating (65 %) |
| Press 0.03 s before (still charging) | UNGUARDED, 150 |
| Press 1.2 s before (guard already in recovery) | UNGUARDED, 150 |
| Facing away, perfect timing | **OFF_AXIS**, 150 to the REACTOR region |
| Empty capacitor | shield refused (`CAPACITOR LOW`), shell unmitigated |
| 25.2 energy | shield raised (cost 25), PERFECT; the economy keeps funding the absorb |
| Second press during the cycle / inside the 5 s cooldown | refused (`SHIELD ACTIVE` / `SHIELD COOLDOWN`) |
| Through destroyed cover | the sentry holds fire behind a 30-stud wall, a forced shell stops at the wall, after the Mauler removes it the sentry aims and fires |

Offline tests cover energy-starved absorbs and integrity (a second heavy shell in one raise is only partly absorbed). The cockpit's guard ring
closes on the centre of the perfect window (press `chargeTime + perfectTime/2 = 0.275 s` before impact); driven only by the HUD's
`GUARD NOW` label, 8 of 8 presses were PERFECT in one run (and 8 of 11 hits in a 45 s three-tank run).

M09 profiles were not touched. Reactor damage lowers generation, so MOBILITY (reserves propulsion), BALANCED and WEAPONS keep their meaning
under fire; no M09 semantics were changed.

## 5. Bastion damage model (`MechDamage`)

| Region | Health | Loss of it |
| --- | --- | --- |
| CORE TORSO | 900 | **core failure → guaranteed-safe ejection**; 20 % of every other region's damage also hits the core |
| L / R WEAPON ASSY | 300 each | offline: `left_arm + left_shoulder` / `right_arm + right_shoulder` cannot fire (`WeaponState = DISABLED`); torso mounts belong to the core |
| L / R LEG ASSY | 380 each | drive speed `1 - 0.22·damage - 0.12·destroyed` per leg (floor 0.40), steering ×√ of that |
| REACTOR HOUSING | 320 | reactor output `1 - 0.45·damage - 0.15·destroyed` (floor 0.40) through `EnergySystems.SetReactorScale` |

Stages: OK → DAMAGED (≤ 60 %) → CRITICAL (≤ 25 %) → FAILED. Hit region comes from where the shell meets the hull box in its local frame
(legs low, arms at the sides, reactor in the rear 30 %, core otherwise), so facing matters: a rear hit finds the reactor. There is **no pilot
region**; pilot health is not part of any damage path. Repair happens on docking, on a new assembly and on a full range reset.

Verified: top speed 16.0 → 14.2 → 10.6 → 6.4 st/s as the legs fail; reactor output 80 → 62 → 32 and back to 80 after repair; with the right
assembly destroyed the real client fire path gave `DISABLED` and 0 shots for slots 2 and 4 while slots 1 and 3 fired normally; a sentry
unshielded hit is 70 (a heavy 150): five unshielded heavy hits on the core leave it standing, the sixth fails it.

## 6. Visual damage (client, cosmetic)

`MechDamageFx` reads the published `Dmg_*` attributes: darkened armour (graded `EditableImage`, small and capped, shared budget), a client-only
`Highlight` that chars the whole machine in proportion to damage, bounded scorch discs welded each frame to the rig part nearest a penetrating
hit, sparks and smoke per region (≤ 12 emitters), flickering glow parts for electrical failure, a pulsing fault lamp and black mounts for a
dead weapon assembly, a failed reactor going dark, and a terminal shutdown on core failure (lights stutter out over ~1.1 s, smoke, sparks).
The abandoned machine stays up about 2.2 s (1.2 s longer than a manual test ejection) so the shutdown is seen, then goes with a final burst.

## 7. Cockpit telemetry (`CombatHud`, STRUCTURE MFD)

Concise lines, no arcade panels: a threat line (`INCOMING T-02 | IMPACT 1.6s | AHEAD`, or `TARGETED T-03 PATROL | FIRING IN 0.6s`), up to
three alerts (`PERFECT GUARD BLOCKED 141 / PENETRATED 9 [CORE TORSO]`, `SHIELD OFF-AXIS NO MITIGATION`, `UNSHIELDED HIT -70 [L WEAPON ASSY]`,
`R WEAPON ASSY OFFLINE - HARDPOINTS 2 + 4 DISABLED`, `REACTOR HOUSING CRITICAL - OUTPUT 63%`, `STRUCTURAL: CORE CRITICAL - EJECTION IMMINENT`),
bearing chevrons toward shooters on a collision course, the closing guard ring, and a brief edge flash. The physical STRUCTURE display now
shows six live region bars, the schematic coloured per region, drive / reactor factors and offline mounts. Exterior view adds a small
condition strip. Telemetry channels: `damage.regions/speed/reactor/disabled`, `combat.threat/targets/lastHit`.

## 8. Training controls

* Range panel (district only): **COMBAT TRAINING** button, hotkey **N**, incoming-fire statistics, status of each tank (type, AI state,
  armor status). `PASSIVE RANGE` is the default and every sortie ends back in PASSIVE (docking, ejection, core failure).
* Server rules (`RequestCombatMode`): allow-listed `"PASSIVE" | "ACTIVE"`, pilot `ACTIVE` and `OPERATIONAL`, 0.4 s rate limit.
* Reset (`RESET ENTIRE DISTRICT` / B) now also clears shells in flight, rebuilds tanks with fresh brains, and — for `ALL` — repairs the
  Bastion and refills its magazines. Tanks have unlimited ammunition (their cadence is the reload); "ammunition" in the reset is the player's.

## 9. Verification

**Offline** (`bash tools/check.sh`): offline 28, energy 27, profile 19, weapon 19, presentation 10, destruction 19, **combat 43** (config
ordering, warning accuracy, reload spacing, LOS / arc / range gating, disabled / immobilized / reset rules, region map, spill, stages,
consequences, ray / lead / bearing maths, shield behaviour against shell-sized attacks). `luau-compile` of every source and tool file clean,
`luau-analyze` clean apart from the known Roblox-global noise, `rojo build` → `build/Ironframe-M10B.rbxl`. Self-test **26 / 26**.

**Studio Play** (fresh Studio instance on the built place; deploy with the real F key twice; stages in `tools/m10b_studio_checks.luau`,
client assist in `tools/m10b_client_scenario.luau`) — all PASS on the final build: cover blocks / destroyed cover opens the line; shield matrix
above; energy / cooldown; legs / reactor / assemblies; core failure → ejection while a shell is in flight (cancelled, pilot safe, capsule
`Targetable = false`, `CanQuery = false`, PASSIVE, tanks idle, mech visible ~1.3 s, removed, rebuilt OPERATIONAL / STOWED and repaired);
stress (below).

Additional runs on earlier builds of the same code (shell speed and lead were retuned afterwards; behaviour re-checked where it matters):

* Real controls: `F`, `F` (enter cockpit, deploy), `W` held 4.5 s (drove into the district), `N` (ACTIVE), `2` + left mouse held (Mauler fires
  24 rounds; the scripted mouse aim did not land hits), `V`; HUD-driven guard presses through the same shield action as `G`.
* The sentry's turret destroyed by the Bastion's real Mauler fire in ~7 s (client weapon path) → `TURRET DISABLED`, AI `DISABLED`, its shot
  count stayed 1 over the next 18 s.
* Patrol: reposition from z 404 to 449 toward the preferred range; after `TRACK_L` was destroyed it moved 0.00 studs over 14 s and, with the
  Bastion in its arc, still fired 2 shells. The heavy pivoted its hull 0° → -93° over ~12 s to answer a flanker, then fired.
* Passive prevents attacks (tanks idle for 3 s in the district; switching to PASSIVE cancels shells at once).
* Recall under fire (`DOCKING`, shells cancelled, PASSIVE); manual ejection ×2 + return under fire (pilot safe, capsule untargetable, rebuilt).
* Dodging (8 runs of ~5 s at full throttle across the plaza, teleport-restarted so each run includes the acceleration phase): 18 shells,
  7 hit, 6 hit cover, 4 expired; standing still: 11 shells, 11 hits.
* Stress: 8 rapid mode / reset / state changes while shells were in flight — 0 survived; the district returns to **1,329 instances / 234 registered
  parts** after every `ALL` reset (during a fight cover impacts add up to ~30 bounded overlay parts, cleared by the reset); client FX pools constant
  (84-91 instances, 8 / 6 / 3 pooled objects).

## 10. Performance (measured)

| | value |
| --- | --- |
| Server `TankCombat` AI step | 0.017 ms average, worst 0.22-0.35 ms (3 tanks, LOS rays every 0.2 s) |
| Server shell step | 0.0002 ms average idle, worst 0.36 ms; peak 3 shells in flight (cap 8) |
| Network | one small `CombatFx` event per shell fire / end: 56 events / 45 s with three tanks |
| Client `TankFx` render step | 0.012 ms average, worst 0.31-0.85 ms (first frames) |
| Client `MechDamageFx` | 0.01-0.02 ms average, worst 0.37-0.57 ms; ≤ 12 emitters, ≤ 14 discs, ≤ 12 shared 256² images |
| Connections | one server heartbeat addition, one remote each way, three client render steps; none added per shell / tank |

## 11. Known limitations

* No human at a keyboard: control was scripted through the Studio MCP (real key / mouse events for F, W, N, V and mouse fire), and the guard
  timing was a HUD-cue assist bot. Whether the first shell makes a player "instinctively reach for the shield" is a judgement not made here.
* Dodge numbers come from a small sample with teleport-restarted runs; sentry / patrol / heavy lead, speed and spread need real play-testing.
* Line of sight uses rays, shells use a swept sphere, so a tank can spend shots on cover edges (it is also how stray shells open cover).
* Armour texture darkening depends on the shared `EditableImage` budget, which the M06A–M08 armour grading already strains (the console shows
  `Failed to create EditableImage ... memory budget` after deploys); when unavailable the whole-machine soot highlight, smoke, sparks, discs
  and lamps still show damage. The `ContentId rbxassetid://203785492` warning is also present in an M10A Studio instance (not from this milestone).
* Shells ignore other tanks and the training mech (no friendly fire); no splash damage to the Bastion; one hull box for the Bastion
  (regions are mapped from the hit point, not separate colliders).
* The Heavy is not visually larger; patrol repositioning is limited to its lane route; shield facing uses chassis yaw, not torso yaw.
* Test equipment in `RangeControl`'s server-only audit bindable (`teleport`, `hit`, `testwall`, `dfire`, `hold`, ...) is unreachable from
  clients; it is how the checks drive the production paths.
* Fixed here but belonging to M10A: `DestructionFx` used `V3.zero` (`V3 = Vector3.new`), which errored every frame once a debris fragment
  settled; more destruction made it visible.
* Single player, one district per bay; two players, gamepad / mobile control of the panel and StreamingEnabled were not exercised.
