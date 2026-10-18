# M10C — Autonomous Mech Combat (ROOK-01)

Branch `feature/m10c-autonomous-mech-combat` (from M10B `adf73c5`). Local commits only; nothing pushed, no PR.

Range 07 now has its first autonomous mech opponent, **ROOK-01 — Autonomous Combat Test Unit**: an unmanned Bastion-derived training chassis that
walks, senses, picks a weapon, manages its reactor and capacitor, raises the directional pulse shield, takes six-region damage and is defeated
by ordinary weapon fire. Selecting **MECH TRIAL — ROOK-01** (Range panel button or **M**) arms it; PASSIVE RANGE stays the default and the
M10B ACTIVE TRAINING (tanks, **N**) is unchanged. Screenshots are in `docs/m10c/` (real Play sessions through the Studio MCP).

## 1. Architecture and reuse

| Piece | File | Role |
| --- | --- | --- |
| Enemy data | `IronframeShared/EnemyConfig` | one table per enemy: preset, station, court lattice, six-region health and armour, weapon doctrine, perception, tactics, defence, energy doctrine, accuracy. A second enemy is a new entry |
| Brain | `IronframeShared/MechBrain` | **pure** state machine `IDLE → ACQUIRE → APPROACH → ENGAGE ⇄ REPOSITION`, `DEFEND`, `DISABLED`, `RESET`; weapon choice, attack timelines, shield decision, energy-profile wish, aim-error model. No Roblox types, no clock, injected rng |
| Navigation | `IronframeShared/MechNav` | **pure** lattice + A\* routing, steering, stuck / blocked-turn detection with reverse recovery, tactical position scoring |
| Runner | `IronframeServer/EnemyMech` | builds ROOK, measures the senses, runs the orders through the real systems, hit volumes, damage, disable, reset, audit |
| Rounds | `IronframeServer/TankCombat` (extended) | `MECH` mode; `SpawnBolt` puts ROOK's rounds into the existing swept-projectile manager (world hits via `Destructibles.Hit`, player hits via shield + `BastionDamage`) |
| Look | `BastionBuilder` (ROOK palette + variant), `Loadouts.enemy.ROOK`, `ShowroomAnimator`, `TankFx`, `CombatHud`, `RangeHud` | visuals, telegraphs, cockpit readouts, Range panel |

**Reused unchanged:** the IF-42 rig and `MechRig` aiming / recoil (ROOK's arms point at its aim point through the same `WeaponAim` attribute
contract), `Locomotion` + `MechDrive` (same acceleration, jerk, turn limits, ground / hull probes), the client gait + footfalls (the server never
moves a rig part), `EnergySystems` / `Energy` / `EnergyProfiles` / `PulseShield` (same reactor 80, capacitor 160, thermal ledger, P-01 shield
timings and costs, same MOBILITY / BALANCED / WEAPONS switching delay and interval), `WeaponState` on the real MG-9 and LR-12 components (magazine
60 / reload 3 s, per-shot energy and heat, intervals), `WeaponEffects` muzzle / casings / audio, `MechDamage` six regions and consequences,
`ShieldClient`, `MechDamageFx`, `Destructibles` for cover and hit registration.

**Modest generalisations (all backwards compatible, covered by the existing suites):**
`MechDamage.New(capacities?)`; `BastionDamage` accepts any session-shaped table (`damageCapacity`, `onCoreFailure`); `Destructibles` gains a
`robot` object kind (`takeHit`), a `MECH` reset kind and ROOK cleanup; `Weapons.Step` adds the shot `origin` to the hit context (the shield needs
the attacker's direction); `TankCombat` bolts carry `category` / `weaponId`; `Loadouts.enemy` + `Loadouts.Get` keep enemy loadouts out of the
player's `presets` (SetPreset can never select ROOK); `MechRig` reads presets through `Loadouts.Get`; `MechNav`/`MechBrain` are new pure modules.

## 2. Controls and encounter flow

* Range panel (district only): **MECH TRIAL — ROOK-01** button (also **M**), **RESET TRIAL** button, ROOK status lines
  (`state / structure % / capacitor % / shield / rounds`). `N` still toggles tank training; from MECH it starts ACTIVE (ends the trial). `B`
  resets everything. The server allow-lists `PASSIVE | ACTIVE | MECH`, requires an ACTIVE operational pilot, rate-limits 0.4 s.
* Flow: select MECH TRIAL → "POWERING UP" (2.5 s arm delay, ROOK is always rebuilt fresh at trial start) → ROOK scans from its station pad
  (z = 606, bay-local), acquires, walks the chicane to its engagement band, fights → defeat (core failure, or both weapon assemblies
  destroyed = NEUTRALIZED) → "TRIAL COMPLETE" → **RESET TRIAL** (ROOK rebuilt from scratch, Bastion repaired, magazines refilled) or end the trial.
  Ending the trial / docking / ejection / core failure returns to PASSIVE; a stood-down ROOK walks back to its pad and locks.
* The court: road section z 500–612 with three staggered 16-high destructible cover walls (A, B, C; the same `wallGrid` modules as the
  buildings, restored by RESTORE STRUCTURES / reset), a station pad and a gate sign. ROOK's centre stays inside |x| ≤ 18, z 500–612.
* Mech-vs-mech: hulls are not colliders (as before); ROOK treats the player as a solid circle when planning and a separation step pushes both
  machines apart through their real swept hull probes.

## 3. ROOK-01

* **Visual identity**: dark graphite and weathered steel armour (some panels bare metal), muted yellow markings, `ROOK` / `01` stencils on the
  pauldron fronts, shin and thigh bands, `ROOK-01` on the pad, a hot-orange sensor window on a tall head sensor module, indicator lamps that
  pulse by AI state (slow amber standby, white blink on contact, red in combat, cyan while the guard is up, dark when down). Procedural parts
  only (no AI asset generation was needed); damage is the existing `MechDamageFx` (soot, scorch, smoke, dead-mount lamps) plus a client hit
  flinch and a terminal slump (kneel, tip forward, smoke and fire) on core failure.
* **Regions** (hit volumes carried with the chassis, tight, so a centre-mass shot is CORE; the backpack REACTOR is only reachable from behind
  or the flanks; arms and legs are separate small targets):

| Region | HP | MG / LASER / HEAVY multiplier | Loss of it |
| --- | --- | --- | --- |
| CORE | 700 | 0.55 / 0.80 / 1.00 | terminal DISABLED until reset (20 % of every other region's damage also hits the core) |
| ARM_L (LR-12) | 220 | 0.80 / 1.00 / 1.20 | laser (`left_arm`) offline |
| ARM_R (MG-9) | 220 | 0.80 / 1.00 / 1.20 | gun (`right_arm`) offline; both gone = NEUTRALIZED |
| LEG_L / LEG_R | 260 each | 0.70 / 0.90 / 1.15 | drive speed ×(1−0.22·dmg−0.12·destroyed per leg, floor 0.4), steering ×√ |
| REACTOR | 240 | 1.00 / 1.10 / 1.30 | reactor output ×(1−0.45·dmg−0.15·destroyed, floor 0.4) |

  Hit order: pulse shield (the real P-01, directional, category-specific) → armour multiplier → region → consequences.
* **Weapons** (data in `EnemyConfig`, components untouched; rounds are swept projectiles, never instant):

| | MG-9 | LR-12 |
| --- | --- | --- |
| Pattern | 0.35 s spool, 6-round burst, 1.3 s gap | 1.1 s charge (aim locks at 80 %), 3 pulses 0.25 s apart, 4.2 s cooldown |
| Range | ≤ 140 (optimal 80) | 35–175 (optimal 120; preferred beyond 78) |
| Round | 250 st/s, 8 dmg ×1.0 ballistic | 520 st/s, 25 dmg ×1.25 laser |
| Aim error | 3.0° base | 1.1° base |
| Energy | 0.6 per round (the component's) | 24 per pulse + 22/s while charging |
| Cues | muzzle glow, spool, HUD `MG-9 SPOOLING` | muzzle glow growing, targeting line (flickering, steady after the lock), `TARGETED … FIRING IN x.xs`, guard ring |

  The laser never starts or continues while the platform is moving; the arm tracks with a finite rate (aim point eases to the lead-corrected
  target, then freezes at the lock), so a lateral move after the lock misses. Aim error also grows with range (×(1+0.5·range/100)), target
  speed, ROOK's own speed and a damaged arm (capped ×4). Fire needs the **gun-height lane** to the target's torso: a target the head sensor sees
  over a wall (head peeks) is not fired at, and ROOK repositions for a lane.
* **Perception**: sight 230 studs, ±105° arc (360° inside 38), line of sight from the sensor to three samples on the Bastion against live
  geometry (destroyed cover opens it). Contact is remembered 7 s with a drifting estimate; gunfire gives a position fix ±24 studs; no valid
  target (ejected, docked, evacuated, outside the district) clears the memory at once. Reaction: 0.9 s acquire delay, 0.45 s (+0.25 jitter)
  shield reaction with a 70 % chance to react.
* **Tactics**: band 62–112 studs, retreat inside 40, flank every ~9.5 s of stable engagement (not when limping), cover when structure < 38 % or
  capacitor < 25 % (dwell until 62 % or 5.5 s), regain-LOS / search manoeuvres. Navigation is a validated lattice (5 × 17 nodes over the court,
  re-validated against real geometry, hull sweeps for every edge) + A\*, direct when the sweep is clear, whisker clearances, stuck / blocked-turn
  detection with a reverse recovery. No teleporting.
* **Energy**: MOBILITY to relocate, WEAPONS to prepare / run a laser volley, BALANCED otherwise and while starved, with 0.8 s hysteresis; the
  real switch delay and 2 s interval still apply. Weapons are withheld by budget (capacitor above the weapon reserve), burst bucket, thermal
  and reactor health; a starved ROOK keeps only the cheap gun, then falls back to cover.

## 4. Verification

**Offline** (`bash tools/check.sh`): offline 28, energy 27, profile 19, weapon 19, presentation 10, destruction 19, combat 43, **enemy 57**
(config contracts, every state transition, acquisition and lost contact, weapon selection by range / energy / ammo / motion, attack timelines,
cooldowns, aim-error model, shield reaction delay / probability / direction / gap / cooldown against the real P-01, profile hysteresis against the
real switch rules, energy starvation against the real ledger, damage-dependent behaviour, core failure, RESET, lattice + A\*, steering, stuck
detection and recovery, firing lane). `luau-compile` clean for every file, `luau-analyze` clean apart from Roblox-global noise, `rojo build` →
`build/Ironframe-M10C.rbxl`, self-test 26 / 26 in Studio.

**Studio Play** (own Studio instance on the built place, real `F`, `F` deploy and the real `M` hotkey; stages in `tools/m10c_studio_checks.luau`).
Console shows no script errors (only the known UIBlox / `ContentId` noise).

| Item | Result |
| --- | --- |
| Deploy, enter Range 07, start MECH TRIAL (`M`), ROOK acquires | PASS (`IDLE → ACQUIRE → APPROACH`, notice "POWERING UP", target readout) |
| Autonomous locomotion | PASS: from 166 studs into the 62–112 band through the cover chicane via waypoints, top speed 10.2 st/s (cap 0.85), footfalls / gait from the client, flank and reposition manoeuvres, recovery from a pinned corner (reverse + replan); 0 teleports |
| Real weapon attacks | PASS: 79 swept rounds / 79 hits on a stationary unshielded Bastion in 40 s; 33 rounds / 27 hits on a weaving Bastion in 40 s |
| Cover blocks fire | PASS: 0 rounds in 6 s with the player south of cover A while the head sensor still saw the target (lane blocked) |
| Player shield mitigates | PASS: pressing the real shield at (first-pulse arrival − 0.275 s): 79 hits → 6 PERFECT, 12 GUARD, 61 unguarded, 483 of ~1073 raw damage prevented |
| ROOK energy consumed | PASS: capacitor 160 → 112 per laser volley and back, profile MOBILITY / BALANCED / WEAPONS switching |
| ROOK shield (reacts to being shot) | PASS: 5 raises in 24 s of sustained player laser fire, cooldown-limited (hits through the real client weapon path: LR-12 19 hits = core 700 → 320 in 8 s) |
| Weapon assembly disabled | PASS: 14 LR-12 hits on ARM_L → `left_arm`, `left_shoulder` offline |
| Leg penalty | PASS on a live ROOK: top speed 10.2 → 4.9 st/s with both legs destroyed (factor 0.40) |
| Reactor damage | PASS on a live ROOK: output 80 → 32 (factor 0.40) |
| Core destroyed → terminal | PASS: DISABLED, drive locked, power cancelled, bolts cancelled, kneeling wreck with smoke and fire, 0 further rounds in 8 s |
| Reset and repeat | PASS: RESET TRIAL / `reset MECH` rebuilds ROOK, repairs and rearms the Bastion; 6 consecutive trials identical |
| Player core failure | PASS: safe ejection, mode → PASSIVE, ROOK stands down at once and walks home, 0 rounds after, capsule `Targetable = false`, `CanQuery = false`, rebuilt OPERATIONAL / STOWED |
| PASSIVE / ACTIVE unchanged | PASS: PASSIVE 0 shots; ACTIVE tanks fire (4 shells in 14 s) and ROOK stays STANDBY; MECH tanks IDLE, ROOK active |
| Cleanup over 6 trials | PASS: district 1373, indexed parts 264, ROOK 512 (515 while a wreck smokes), `IronframeMechs` 828, workspace 3932 — identical after every reset |

Limitation: the Studio MCP cannot aim a mouse reliably. The weapon-to-enemy interaction above went through the real **client** weapon path
(`WeaponIntent` with a scripted aim point, server raycast, `CombatTargets.Hit` → `Destructibles.Hit` → ROOK's shield → armour → region); component
destruction, leg / reactor penalties and the terminal case used the server-only audit hooks (`rookhit` / `rookwreck`, unreachable from clients)
through the same `Destructibles.Hit` path. Dodging used the real drive input at the client's 12 Hz. **No human played this.**

## 5. Performance

| | value |
| --- | --- |
| `EnemyMech.Step` (perception, brain, orders, locomotion, volumes) | 0.12 ms average, worst 4.4 ms (a position re-pick: ~85 line-of-sight rays plus a lattice sweep) |
| LOS rays / hull casts | ≈ 6.7 Hz LOS (3 rays) while a contact is in sight, ≈ 15 Hz whiskers (3 casts) while moving; 20 k casts over 30 s |
| `TankCombat` AI step including ROOK | 0.13 ms avg, worst 4.4 ms; bolt step 0.022 ms avg, worst 0.15 ms; peak 3 bolts in flight (cap 24) |
| Hit volumes | 15 anchored parts, one `BulkMoveTo` only when the chassis moved |
| Network | one `CombatFx` event per round fired / ended, one `WeaponEffects` event per round (same as the player's own fire); ROOK's rig is posed on clients from one replicated hull part |
| Client `TankFx` | 0.04 ms average, worst 0.42 ms; pools unchanged (8 bolts, 6 bursts); `WeaponEffects` 0.13 ms / 0.35 ms; `MechDamageFx` 0.004 ms |
| Level build | the lattice (86 nodes, ~145 edges) is validated once at build and again at every ROOK rebuild |

## 6. Known limitations

* Untuned by humans: damage, spread, cadences, reaction times, band and flank timing are first-pass numbers (below). A stationary, unshielded
  Bastion loses its core in roughly 50–60 s; a weaving one took ~130 damage in 40 s; a competent player who shoots back can kill ROOK's core in
  ~10 s of laser fire when it does not shield. Expect adjustment in both directions.
* ROOK shields against **sustained** fire it can see aimed at itself (or after a hit); it does not read a single hitscan shot in flight. A
  committed laser volley is never abandoned for the shield (the price of the shot).
* One cover geometry; the lattice is validated at build / every 20 s of repositioning, not on every wall collapse (conservative: newly opened
  routes appear after a re-validation). Hit volumes are rest-pose volumes carried with the chassis, not animated joints: during a full stride the
  legs can be a couple of studs off the visible feet.
* Panel seams (0.06 studs) let a line of sight exactly on a seam through; the gun-lane check masks it for fire, not for awareness.
* The whole machine uses the Bastion's generous 14 × 15.5 × 14.5 hull for the player's own hit tests (unchanged from M10B).
* Mech hulls still do not collide as solids: separation is a soft push.
* Sound: ROOK reuses the Bastion's weapon audio; no ROOK-specific sounds (no listening judgement made). Lamp pulses and the targeting line were
  checked in screenshots, not for feel.
* Multi-player, gamepad / touch for the new buttons, StreamingEnabled and a second enemy were not exercised.

## 7. Needs human playtesting

Is the 0.9 s laser telegraph (lock at 0.88 s) a fair, learnable window? Is the MG's 6-round burst readable at range? Does the approach pace
(10 st/s) feel menacing or sluggish? Does ROOK's shield feel like an "impressive play" or a nuisance (70 % react, ~1.2 s hold, cooldown 5.1 s)?
Is flanking noticeable, and is the cover chicane a good duel space (is 16 high the right cover height)? Is the 2.5 s arm delay and the "fresh
ROOK on every trial" rule acceptable? Is the cockpit target readout too small at 1080p?

## 8. Initial tuning (all in `EnemyConfig`)

Perception: sight 230 / arc ±105° / proximity 38 / memory 7 s / acquire 0.9 s / fire cone 26° / lost-LOS hold 0.6 s. Tactics: band 62–112, too close 40,
caps approach 0.85 / retreat 0.55, flank every 9.5 ± 3 s, cover below 38 % structure, dwell 5.5 s to 62 % capacitor. Defence: reaction 0.45 +
0–0.25 s, chance 0.7, arc ±50°, min capacitor 22 %, min gap 1.5 s, hit awareness 0.7 s, guard hold 1.15 s. Energy: profile hold 0.8 s, WEAPONS above
50 %, low 25 %, laser withheld below 35 % (+0.5 × reactor loss). Accuracy: range gain 0.5, target-speed gain 1.0 (per 14 st/s), own-speed gain
0.9, damaged-arm gain 1.2, cap ×4. Trial: arm delay 2.5 s, bolt cap 24, separation circle 9 studs each.

## 9. Branch and commits

Branch `feature/m10c-autonomous-mech-combat`, feature commit `9ee9ee6` (on top of M10B `adf73c5`). Not pushed, no PR.
