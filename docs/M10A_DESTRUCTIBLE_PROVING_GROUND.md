# M10A — Destructible Proving Grounds

Branch `feature/m10a-destructible-proving-ground` (from M09 `bd69e43`). Local commit only; nothing pushed, no PR.

Deploy the IF-42 Bastion, drive the existing road out of the hangar and through a new gate into the **Range 07 Destruction
Testing District**: three unmanned armored training tanks, one stationary training mech, 199 destructible structure modules
(walls, barricades, containers, fencing, machinery, two collapsible roofs), staged damage, real openings in walls, support-based
partial collapse, bounded client-side debris, a range-control panel and a one-button reset. No PvP, no armed AI, no damage to the
player's mech or pilot.

Screenshots (`docs/m10a/`, captured from the real Play session through the Studio MCP): `01` intact stationary tank, `02` district
gate, `03` shed / warehouse / bunker intact, `04` Mauler engaging T-01, `05` T-01 VEHICLE DESTROYED, `06` MG-9 wall breach + notice,
`07` training mech disabled + shed roof collapsed, `08` impact / debris / explosion burst, `09` training mech intact.

## 1. Layout (bay-local, +Z leads away from the hangar)

```
z   0..58    hangar (protected safe zone, unchanged)           z 392..408 tank traps + barricade line (35-wide road gap)
z  58..320   existing staging proving ground (unchanged)       z 395..540 central test field, stationary tanks T-01 / T-02,
z 320        far wall now has a 54-wide gate on the road                  ARMORED VEHICLE TESTING LANE (east) with patrol tank T-03
z 322        DISTRICT GATE  "RANGE 07"                          z 496..520 fuel point (3 explosive fuel tanks, generator, transformer)
z 335..360   RANGE CONTROL tower + reset station A (west)       z 524..568 STATIONARY TRAINING MECH pad, M-01 (west)
z 366        entry chicane (6 barriers, 29-wide passage)        z 552..600 container yard, 9 containers in two tiers (east)
z 578..606   gantry shed: 4 columns, 2 beams, 6 roof panels     z 614..654 Warehouse A (west) and Bunker B (east)
z 668        reset station B                                    z 700      sealed DUEL ARENA gate: the reserved expansion (+Z)
```

* The road (x = 0, 44 wide) runs hangar → gate → arena gate, so the Bastion always has a navigable route; the hangar remains a
  protected safe zone (nothing there is registered as a target).
* `DistrictBuilder.luau` documents every zone. Nothing is built beyond the sealed arena gate; the district folder carries
  `ExpansionDirection = "+Z"` and its zone bounds as attributes for a future duel arena.
* **Integration fix (not a rebalance):** the legacy M08B range drone #2 stood at x = 0 in the middle of that road (9-wide pedestal,
  12-high body), which wedged the 14-wide Bastion before it ever reached the gate. The three drones now stand at x = −56 / −36 / +46
  (`CombatTargets.DRONE_X`); their health, armor and behaviour are unchanged and every existing check script positions the mech
  relative to the drone it reads.
* Each bay owns its own district (like the proving ground), 136 studs wide inside the 140-stud bay spacing, so players never share or
  collide with each other's destruction. Effects and range readouts go only to the owning player.

## 2. Destruction architecture

| Piece | File | Role |
| --- | --- | --- |
| Config | `IronframeShared/DestructionConfig` | materials (health, per-weapon-class resistance, stage threshold, fx family), weapon id → class map, splash, limits, client budgets, audio ids |
| State | `IronframeShared/DestructibleState` | pure unit: `INTACT → DAMAGED → DESTROYED`, resistance maths, support graph (`Unsupported`) |
| Rules | `IronframeShared/ComponentRules` | pure tank / training-mech status from component states |
| Batching | `IronframeShared/FxBatch` | pure effect batcher: lossy impacts, lossless destruction events, per-packet caps |
| Server core | `IronframeServer/Destructibles` | part → (district, object, component) registry, hit entry point, staged visuals, collapse queue, blasts, stats, chunked reset, audit |
| World | `IronframeServer/DistrictBuilder` | all geometry and module placement |
| Machines | `TrainingTank`, `TrainingMech` | component builds, presentation, patrol |
| Control | `IronframeServer/RangeControl` | `DestructionFx` + `RequestRangeReset` remotes, zone attribute, server-only audit bindable |
| Client | `StarterPlayerScripts/DestructionFx`, `RangeHud` | pooled cosmetics; range panel |

**Authority.** Health, stage, support and collision are tables/instances owned by the server. `Weapons.Step` already raycasts; it now
passes `{ weapon, position, normal }` to `CombatTargets.Hit`, which forwards non-drone parts to `Destructibles.Hit`. The client only
receives cosmetic events; no client value can destroy anything. `Targetable == false` parts (the ejection capsule), unregistered parts
(hangar, ground, tower, perimeter) and weapons without a class (plasma, missile: not implemented) deal nothing.

**Real consequences.** A destroyed module's part (or holder model) is parented to `nil`: the weapon raycast, the mech's blockcast and
`GetPartBoundsInBox` all stop seeing it — collision and line of sight change. Reset re-parents the same instances (no re-creation).

**Stages.** `INTACT` → `DAMAGED` (tinted, panels tilt on their fixings, glass frosts, machinery smokes, crack / crater / scorch /
rebar overlay parts at the struck spot, ≤ 4 per module) → `DESTROYED` (removed; ≤ 160 server rubble parts district-wide for
concrete / structural; machinery stays as a blackened smoking hulk). Stage labels per material: BREACHED, COLLAPSED, DISABLED.

**Support / partial collapse.** A module may list `supports`; when any support is destroyed it collapses after 0.35–0.9 s, cascading
(`WH_*` wall courses stand on the course beneath, roof panels on beams, beams on columns, bunker roof slabs on the top wall course).
Collapse is not weapon damage and never counts as damage inflicted. Fuel tanks / explosive machinery queue a blast (`radius 15, 130`)
that chips nearby **structure only**.

**Mauler splash.** HEAVY hits also damage structure modules within 6.5 studs at ×0.5 falloff (≤ 10 modules). Vehicles, mechs, pilots
and capsules are never splash targets.

### Types and counts of destructible objects

| Kind | Modules | Material | Notes |
| --- | --- | --- | --- |
| Wall panels (Warehouse A ×4 walls, Bunker B ×4 walls) | 75 | CONCRETE lower courses, PANEL / glass upper, CONCRETE bunker | 8 wall groups; a wall is "breached" when any module falls |
| Roof panels / slabs | 18 | PANEL, STRUCTURE | supported by beams / top wall course |
| Columns and beams | 12 | STRUCTURE | shed + warehouse frames |
| Container shells (9 containers: roof, 2 sides, doors) | 36 | ARMOR | static frame stays; opened containers show cargo |
| Armored fence segments | 28 | ARMOR | lane and mech-pad fencing |
| Barricades, chicane, tank traps | 15 | CONCRETE, STRUCTURE | |
| Machinery (generators, transformers, fuel tanks) | 15 | MACHINERY | 4 fuel tanks are explosive |
| **Total modules** | **199** | 52 CONCRETE, 48 PANEL, 64 ARMOR, 20 STRUCTURE, 15 MACHINERY | |
| Training tanks | 3 × 5 components | VEHICLE_* | see §3 |
| Training mech | 1 × 4 components | MECH_* | see §3 |

## 3. Training machines

**Tank (`TrainingTank`).** Components HULL (700), TURRET (520), TRACK_L / TRACK_R (240), ENGINE (210); unmanned, no weapons fire.

* Track destroyed → mobility disabled (patrol stops, the track visibly shortens and sags, broken tread on the ground, sparks).
* Engine destroyed → mobility disabled, engine fire.
* Turret destroyed → turret/gun disabled (scan stops, barrel / turret droops, smoke and sparks).
* Hull destroyed → VEHICLE DESTROYED: everything stops, the turret is thrown off and settles tilted, texture stripped / charred,
  smoke, fire, flickering glow, explosion burst. A wreck keeps absorbing damage (counted) without further effects.
* DAMAGED stages add sparks / smoke; every hit leaves a bounded set of scorch discs (≤ 14 per tank) welded to the vehicle.
* **Assembly.** One anchored invisible root; every other part is a welded (`Weld`, explicit C0) unanchored part, the turret on its
  own welded pivot. Moving the patrol tank replicates one CFrame, the turret scan one weld offset (10 Hz).
* **Patrol.** T-03 follows a two-point route in the armored lane (5.5 studs/s, turns in place at 24°/s), pauses while a mech is within
  24 studs ahead (blockcast against `IronframeMechs`), and dust follows motion. T-01 / T-02 are stationary with fixed turret yaw.
* **Visual.** Skinned by the AI-generated, **segmented** tank `TNK_001` (hull / turret+gun / left track / right track, 15.8k triangles,
  scaled 1.5×); fixed invisible hit boxes measured against the scaled mesh keep hit geometry deterministic and independent of mesh
  topology. If the asset cannot be loaded the tank falls back to the fully procedural build (114 parts, used when assets are absent).

**Training mech (`TrainingMech`).** The existing procedural IF-42 rig (`MechFactory` → `BastionBuilder`, re-colored safety-orange)
parked outside `IronframeMechs` so no client controller, drive or animator touches it. No locomotion, no AI, not a second controller.
Joint-attached invisible hit volumes follow every pose:

| Component | Hit volumes | Loss |
| --- | --- | --- |
| CHASSIS (760) | torso, hip, head, left arm | **TARGET DISABLED**: slump pose, fire, smoke, explosion |
| ARM_MOUNT (260) | right arm + weapon | weapon shot off, limp dark arm |
| SHOULDER_ARMOR (300) | both pauldrons | plates fly off |
| LEG_ASSEMBLY (340) | thighs, shins, feet | the machine kneels (mobility disabled) |

Poses are `MechRig.Apply` with joint overrides (≈ 20 Hz, 0.5–1.1 s). The player's Bastion damage system is untouched; the training
mech is `Unmanned` and has no pilot.

## 4. Weapon interactions (numbers in `ComponentRegistry` unchanged: MG-9 8 dmg, LR-12 25, HMG-20 25; energy 0.6 / 24 / 2.5)

`effective = weaponDamage × resist[class]` (material or per-object override). Shots to destroy (offline-checked from raw numbers,
confirmed in Studio through the real hit path):

| Target (HP) | MG-9 | LR-12 | HMG-20 |
| --- | --- | --- | --- |
| Light panel (110) | 11 | 5 | 3 |
| Concrete barricade (520) | 217 | 47 | 14 |
| Heavy hull (700, ×0.16 / 0.55 / 0.9) | 55 s of fire | 12.7 s | 10.4 s |
| Track (240) | 6.7 s | 3.4 s | 2.6 s |
| Engine deck / machinery | 2.4 s (MG shreds exposed machinery) | 2 s | 2 s |

* **MG-9** — best against light panels, fences and exposed machinery, a different experience against concrete / hulls. Sparks,
  small dust and chips, pocks.
* **LR-12** — concentrated damage, the best against armored metal and tracks. Orange scorch discs that cool to black, lingering
  smoke, blue arcs on machinery, sizzle.
* **HMG-20** — the cover breaker: ×1.55 vs concrete, splash on neighbours, big dust + shock ring + flash light, heavy chips and
  fragments, crater with exposed rebar, loud impact.

## 5. Visual and audio

All cosmetics are client-side and pooled (`Config.client`): 20 emitter slots (dust / sparks / chips / smoke / flash / fire / shockwave
+ light), 64 ballistic fragments (one `BulkMoveTo` per frame, one raycast each, recycled oldest-first, 3.6 s life), 36 scorch discs,
10 sound voices. Panels fly off as their own silhouette; collapses are heavier and fall; machinery failure adds delayed electrical
crackle. Persistent smoke / fire (≤ 3 emitters per wreck) is server-created and destroyed by reset.

Audio is **new**, original deterministic synthesis (`tools/synthesize_destruction_audio.py`, six WAVs, CC0) uploaded through the
established Open Cloud flow (`tools/roblox_audio_upload.py`, creator user 3611602826): `concrete_hit 90380186327747`,
`metal_hit 89556137773249`, `laser_sizzle 125716281003648`, `collapse 110245360489063`, `explosion 98545819452219`,
`zap 123144333775805` — all Audio / Active / Approved; ids are registered in `DestructionConfig.audio` and cross-checked by
`python tools/synthesize_destruction_audio.py --check`. Verified: each loads in the Studio client with the expected duration.
**Not verified: any listening judgement** (no loopback), or playback outside the owner's account / unpublished test place.

## 6. AI Asset Factory

`assets/specs/batch_005.json` → `TNK_001 TrainingTankSegmented`, cloud model `89613907181522`, registered in `AssetRegistry`
(22 AI assets now load at start). Three attempts are in `assets/manifests/batch_005.json`: two single-mesh prompts ("turret only",
"hull only") both came back as complete tanks fused into ONE mesh (no separable turret or tracks, 40–60 % of the requested size) and
were rejected; the third used explicit part names and produced four usable parts, accepted. Known property: baked textures cannot be
tinted by `MeshPart.Color`, so heavy damage strips the texture and chars the colour, light damage is shown with scorch discs.

## 7. Range control and reset

Panel (left, while deployed in the district): DAMAGE INFLICTED with MG-9 / LR-12 / HMG-20 split, TARGETS DISABLED n / 4, VEHICLES
DESTROYED n / 3, COMPONENTS LOST, STRUCTURE SECTIONS n / 199, WALLS BREACHED n / 8, COLLAPSES; toasts (TRAINING ARMOR T-01 - VEHICLE
DESTROYED, WAREHOUSE A FRONT WALL - WALL BREACHED, GANTRY SHED - PARTIAL COLLAPSE ...). Buttons: RESET ENTIRE DISTRICT, REPAIR +
RESPAWN VEHICLES, RESTORE STRUCTURES; hotkey **B** = reset all; hold ALT in the cockpit for the cursor. Server rules: allow-listed
kind, pilot ACTIVE and OPERATIONAL, 1.5 s rate limit, only the pilot's own bay. A reset runs over several heartbeats (hits are ignored
meanwhile), restores authoritative health, collision, model state and effects, clears debris and rubble on the client, and never
reloads the place. Modules are re-parented; vehicles and the mech are destroyed and rebuilt (respawn) after being unregistered.
Terminology is machinery-only throughout.

## 8. Verification

**Offline** (`bash tools/check.sh`): all suites pass — offline 28, energy 27, profile 19, weapon 19, presentation 10,
**destruction 19** (config sanity, untouched weapon numbers, weapon-identity ordering, staging, resistances, support graph, tank and
mech rules, batcher). `luau-compile` of every source file and `rojo build` (`build/Ironframe-M10A.rbxl`) succeed.

**Studio Edit mode** (`tools/m10a_studio_checks.luau`, real `CombatTargets.Hit` path, AI-skinned tanks): 0 failures — shot counts above,
barricade removed / line of sight restored, wall panel above collapses after its course is destroyed, shed beam + 3 roof panels
collapse and the other side stands, track → IMMOBILIZED, turret → TURRET DISABLED (hull intact), hull → VEHICLE DESTROYED, mech
component and terminal states, full reset (health, parent, CFrame, rubble 0, overlays 0, vehicles OPERATIONAL), **4 destroy / reset
cycles with identical instance (1,329) and registry (234) counts**, capsule / plasma / unknown weapons deal 0.

**Studio Play** (production build, scripted through the client test bindables = same remotes and validation as a pilot; steps 3-8 and 10 were run on the previous build of the same code, steps 1-2, 9 and 11 plus the audio load check on the final build):

1. Deploy BALANCED→AUTOCANNON from the hangar, doors open, ACTIVE.
2. Drove hangar → district gate straight along the road in 27.6 s (zone attribute HANGAR → STAGING → DISTRICT, panel appears).
3. HMG-20 destroyed stationary tank T-01 (VEHICLE DESTROYED, 1,220 damage, smoke column, thrown turret); LR-12 damaged T-02;
   MG-9 breached the Warehouse A front wall (notice shown, WALLS BREACHED 1 / 8).
4. Production-path batch on the rest: T-03 track → IMMOBILIZED, turret, hull → VEHICLE DESTROYED; T-02 engine (MG-9) → IMMOBILIZED;
   mech armor / arm / legs → MOBILITY DISABLED, chassis → TARGET DISABLED; shed column → beam and roof panels collapse.
5. Weapon classes produced different damage totals (MG-9 / LR-12 / HMG-20 columns of the panel).
6. Energy profiles during sustained LR-12 fire at the warehouse (6 s, full capacitor): MOBILITY holds 86 u (state RESERVED), BALANCED
   49 u, WEAPONS 10 u (ENERGY LOW) — M09 reserve behaviour intact.
7. **RESET ENTIRE DISTRICT through the HUD remote**: all 3 tanks OPERATIONAL, mech OPERATIONAL, 0 sections, HUD zeroed.
8. Three more full destroy + reset cycles through the audit interface: instances 1,335 → 1,514 (destroyed) → 1,335 each time,
   registry 234, rubble 0, overlays 0.
9. Recall to hangar (1.5 s), redeploy, **eject inside the district**: `PILOT_EVACUATED`, capsule `Targetable=false` / `CanQuery=false`,
   mech rebuilt `OPERATIONAL / STOWED`, range zone cleared, panel hidden, character health 100.
10. Final build smoke: Play log shows 0 server errors / warnings and the only client warning is the pre-existing `Player:Move` message; district attributes 199 sections / 4 targets, owner bound.
11. Garage: SetPreset ENERGY / MISSILE / BALANCED / AUTOCANNON rebuild correctly (317 / 319 / 311 / 341 parts), SELF-TEST 25 / 25.
12. Hangar floor, staging field, district ground and range tower take 0 damage from 50 Mauler hits each.

The M07 / M08 / M09 Studio scripts were not re-run in full; M10A changes to existing code are limited to the hit-context argument,
the drone x-positions, the far-wall gate and one-line wiring in `Main` / `IronframeClient` (see git diff).

## 9. Performance (measured)

| | value |
| --- | --- |
| District instances (clean) | 1,329–1,335 descendants (199 modules, 3 tanks = 120, training mech = 547); peak 1,514 when most of it is destroyed |
| Parts | district ≈ 1,455 parts (before the tank skin swap); skinned tank = 15 parts + welds (≈ 40 instances), procedural tank ≈ 95 |
| Server `Destructibles.Step` | 0.03 ms average idle, 0.14 ms average over the cycle test, **worst 11.7 ms during resets** (rebuilds measured in Edit: training mech 13.1 ms, procedural tank 4.2 ms; each rebuilt machine now gets a heartbeat to itself; final Edit-mode reset of 9 frames peaked at 15.4 ms) |
| Client FX | 0.02 ms average, 0.44 ms worst per frame; FX root constant at 320 instances; fragments capped at 64 (184 recycled in one session, never above the pool); 945 bursts, 278 events, 0 events dropped for distance |
| Network | one batch per 0.1 s, ≤ 18 impacts (lossy) + ≤ 40 events per packet; 310 events in 31 packets over the 4-cycle test, 942 impacts dropped by design |
| Connections | none added per object; fixed set: 1 server remote, 1 client remote, 1 render-step, 1 HUD heartbeat, 1 input; unchanged across reset cycles |

## 10. Known limitations

* Verification used scripted control and screenshots, not a human at a keyboard; effect timing is judged from stills, audio from
  load/duration only.
* The new district is one per bay, not a shared arena. PvP needs a shared arena (see §11).
* Baked tank textures cannot be tinted; light damage on the AI skin is scorch discs only, heavy damage replaces the texture.
* The AI tank came out 11.5 × 17 studs (requested 16 × 28) and is scaled 1.5×; the mech skin is the procedural rig (AI armor meshes
  would need `ArmorGrade`, which only watches `IronframeMechs`).
* Training-mech damage is pose + part removal; no hit-scorch on the mech. Legs / chassis collapse uses a fixed 2-stage pose.
* Patrol tank yields only to mechs (not to anything else) and has a fixed two-point route; no pathfinding, no targeting.
* The mech reset frame costs ≈ 11 ms (547-part rebuild); acceptable for a manual command, could be spread over frames.
* Plasma / missile weapons are not implemented and therefore damage nothing here.
* Driving a 14-wide Bastion through the legacy staging field is still tight (slalom, arch, marker posts); the scripted pilot
  wedged repeatedly until the drone fix. Not re-tuned in this milestone.
* Two players / two bays were not exercised; mobile / gamepad control of the range panel was not tested.
* Studio `StreamingEnabled` is off; the district was not tested under streaming.

## 11. Recommended path to active AI opponents

1. Keep `Destructibles` as the damage authority and give opponents the same component table (`ComponentRules` already encodes
   disabled / mobile / turret states). Replace the patrol route with a small goal layer: waypoints + `PathfindingService` or a
   navmesh-free steering loop using the same blockcast probe as `Locomotion`.
2. Reuse `MechDrive` / `Locomotion` server-side for AI mechs (a controller needs no player), keep one authoritative hull part per
   mech, and move the training-mech pose damage onto the piloted-mech component model (shield, armor, legs) — that is the
   "guaranteed-ejection integration" the permanent rule requires before any weapon may address a mech.
3. Add a perception module (line of sight through `CanQuery` geometry, which destruction already changes) and a weapon driver that
   feeds the existing `Weapons.Step` energy / cadence rules so AI uses the same costs and profiles as players.
4. For duels: promote the district to a shared arena (one `Destructibles` district with several owners / observers — `owner` becomes a
   set), move the reset authority to a match controller, and keep fx per-observer batching.
5. Only then add damage events between mechs: component damage + safe ejection at terminal failure + capsule invulnerability
   (already enforced here by `Targetable = false`).
