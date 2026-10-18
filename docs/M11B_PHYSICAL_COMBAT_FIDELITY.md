# M11B — Physical Combat Fidelity & Mechanical Destruction

Branch `feature/m11b-physical-combat-fidelity` (from M11A `07b1caf`). Local commits only; nothing pushed, no PR.
Commit: `COMMIT_HASH`.

This is a quality milestone: no new weapons, chassis, environments or modes, no weapon accuracy or damage number changed. Shots at a tank
now land on the armour you can see, different weapons leave different damage, and the machine visibly suffers what the simulation says it has
taken. **No human has played it**; everything below was exercised through Play sessions driven by the Studio MCP (screenshots in `docs/m11b/`).

## 1. Root causes (measured, not assumed)

Traced end to end: muzzle → ray / swept sphere → collision → registered component → damage → batched event → client effect.

| # | Cause | Evidence |
| --- | --- | --- |
| 1 | **The tanks were drawn by four visual-only meshes and hit through invisible boxes.** `TrainingTank.buildSkinned` put `CanQuery = false` on the AI mesh (TNK_001) and registered hand-measured `Part` boxes (`HullHit`, `TurretHit`, `BarrelHit`, `TrackHitL/R`, `EngineHit`). The turret box stood in the air above the roof; the barrel box floated beside the gun. | `docs/m11b/before_boxes_side.jpg`, `before_boxes_front.jpg`. Raw-triangle ground truth (below): the turret box was on average **3.6 studs** in front of the surface a ray would hit on the mesh behind it, the hull box 3.0, the barrel box had **12 of 18** rays hit it with no mesh behind at all. |
| 2 | **The gun is not on the turret centre line** (2.6 studs left, ~6° outward, ~10° up), but the muzzle, the muzzle flash, the telegraph beam and the aim solution all assumed a centred, level barrel: shells left from a point in the turret front, not from the barrel. | barrel axis fitted to the mesh triangles; `b.muzzleLocal` was `(0, 2.8, -15.6)`. |
| 3 | **ROOK-01's 18 hand-placed boxes** (and the single hull box the tanks' shells flew at on the Bastion) were 1–2 studs off the drawn armour on average and up to 6 away (the head box floated above the head, the arm boxes stood in the air beside the arms). | `before_overlay_rook_front.jpg`; ray metric below. |
| 4 | **Impact effects were placed at the shell centre, not the contact.** A tank shell that hit the Bastion reported `p.pos` (the sphere centre, one shell radius off the box face) as the impact; a shield absorption was drawn at the armour, indistinguishable from a shell striking it. | `TankCombat.resolveMechHit`, `TankFx.onEnd`. |
| 5 | **Convex-decomposition normals lean.** A mesh hit reports the normal of the convex piece it struck; in dished areas (road wheels) marks and sparks stood at 45° to the visible surface. | measured on the first crater: surface normal `(-0.69, -0.37, -0.62)` for a side hit. |
| 6 | Smaller defects found on the way: a wrecked or shield-absorbed round produced no effect at all; the track-dust emitter stayed on after a tank was immobilised; effect-slot lifetimes compounded across reuse; `MeshPart.Color` cannot tint the baked texture (damage tint did nothing on the mesh until it was a texture strip). | code + Studio. |

### Measurement (Studio; `tools/m11b_studio_checks.luau` `alignment`)

For each tank the raw triangles of every mesh (`AssetService:CreateEditableMeshAsync`, read-only) are the ground truth. Rays on a regular grid from five
directions are cast against the triangles and against the tank's queryable parts. "air" = a hit with no mesh behind it; "gap" = |distance to triangle − distance to hit body|.

| | rays hitting both | air hits | mean gap | worst float |
| --- | --- | --- | --- | --- |
| **M11A boxes**, tank T-01 (1.5 stud grid) | 455 | **63** (4–5 % of the grid) | up to **3.6 studs** per box | 16 studs (hull), 8.2 (turret) |
| **M11B precise meshes**, T-01 (1.0 grid) | 1049 | **2** | **0.029 studs** | 4.2 at one thin-geometry grazing ray; 3 rays of 1049 above 0.5 |
| M11B, final build T-01 / T-02 (1.5 grid) | 466 / 468 | **0 / 0** | **0.020 / 0.018** | none above 0.5 |
| **ROOK-01, M10C hand boxes** (rest pose) | 451 | **120** | 1.44 | 6.4 |
| **ROOK-01, M11B fitted volumes** | 471 | **2** | **0.127** | 1.7 (12 rays above 1.0) |

(T-03 patrols and has the same geometry; moving tanks cannot be sampled statically, it was checked with the same shot tests as T-01 / T-02.)

## 2. Architecture changes

### 2.1 Tanks: the visible mesh is the hit geometry

* `TankParts` (new, server): `MeshPart.CollisionFidelity` cannot be changed on a MeshPart loaded from the cloud model, but `AssetService:CreateMeshPartAsync`
  accepts it. Each of the four tank meshes (hull, turret + gun, two tracks) is rebuilt **once per server** with `PreciseConvexDecomposition`, textures
  copied across, during world setup (parallel, **1.9 s total**). Every tank clones those parts; a clone keeps the collision data, so building and resetting
  tanks never touches the decomposer. Those four parts are the queryable, damage-registered bodies of HULL, TURRET, TRACK_L, TRACK_R.
* **Fallback is visible, not silent:** if the precise meshes cannot be built the tank falls back to the M11A boxes and reports `HitFidelity = "BOX"` on its
  model (`"PRECISE"` otherwise); the audit and overlay show it.
* The **engine** has no mesh: it is the rear upper deck of the hull mesh. `TankHit.HullComponent(y, z)` (pure, tested) turns the registered surface point
  into `ENGINE` or `HULL`; `Destructibles.IndexPart` takes an optional `resolve(part, position)` for exactly this. Moving tanks are handled because the point is
  taken in the tank-root frame.
* The muzzle is the **real barrel tip**, oriented along the real barrel axis (`b.muzzleLocal`); `TankCombat` lays the barrel (not the turret front) on the target
  (`tank.barrelYaw`). The telegraph beam now shows the shot line (muzzle → Bastion), not the barrel axis.
* Blocking: the Bastion's drive probe sees the same meshes, so it stops at the visible hull (driven into T-01: stopped within a stud of the front plate,
  speed 0, no jitter, no tunnelling).

### 2.2 Mechs: fitted compound volumes (ROOK-01, the deployed Bastion)

* `VolumeHit` (shared, pure, covered by the offline suite): `Fit(parts)` turns every armour / frame / joint / reactor / weapon part of useful size into one oriented box in the
  chassis frame (rest pose = `MechRig.Solve(identity) × LocalCF`, the same numbers the clients pose the drawn rig from), classified by the existing
  `MechDamage.ClassifyPart`, with a shrink for balls / cylinders / wedges / AI meshes. `Ray(...)` returns the **nearest** box only (first legitimate surface),
  with an optional swept-sphere inflation and a broad-phase bounding sphere. ROOK fits 157 boxes (ARM_L 35, ARM_R 38, CORE 42, LEG 17+17, REACTOR 8; 285 parts dropped as greeble).
* `MechHit` (server) builds and queries them. **They are plain tables, not parts**: the M10C ROOK hit parts had to be moved and re-replicated every time ROOK moved; the fitted
  volumes replicate nothing. Weapons reach them through `Destructibles.Probe` (limited to the world hit distance, so cover still wins) and
  `Destructibles.HitVolume`, which share `deliver()` with the part path, so a tank mesh hit and a mech volume hit take the same route.
* Tank shells use the Bastion's fitted volumes (cached on the session per rig model, refitted after a loadout change) instead of one box; the contact point and
  surface normal come from the volume face.

### 2.3 One delivery path, richer events

`Destructibles.deliver` (new) is the single function behind part hits and volume hits: class → resolve → damage → mark / reaction → statistics → one batched event.
The `h` event now carries the **component** (`c`), the object (`o`), the incoming direction (`i`) and, for ROOK, the shield timing and interception point (`sh`, `sp`).
Armour that took no damage (a wrecked component, a shield-absorbed round) still emits a damage-free `h` event, so it still sparks. Weapon audit: `Weapons.Strike` is the
production hitscan shared by the weapon step and the server-only `shoot` audit command.

### 2.4 Shield vs armour

The P-01 shield is a forward plane (22 × 16 studs, 13 studs ahead of the chassis). `VolumeHit.PlaneCrossing` (pure, tested) gives where a path crosses it. The tank shell
`end` event now carries the armour contact (`p`, on the visible surface) and, when the shield absorbed energy, the interception point `sp`. The client draws a cool/gold expanding field ring
at `sp` (no metal, no smoke); a fully absorbed round ends its tracer **at the plane** and never shows an armour impact; a round that bled through continues to a metal impact at `p`.
Measured on the final build, head-on at 13 studs: contact `z = 384.19`, shield point `z = 393.00` (exactly 13 studs ahead of the chassis at `z = 380`), timing `GUARD`, prevented 44, penetrating 25.
Flank paths that miss the rectangle fall back to a shield-coloured ring at the contact (never metal sparks).

### 2.5 Diagnostics (Studio only)

`HitDebug` (server): the audit command `hitdebug true|false` draws every registered hit body (tank meshes as per-component highlights, the engine-deck region, ROOK and Bastion fitted
volumes as translucent boxes following the chassis), every registered impact (point + normal, coloured by weapon class, 10 s) and every weapon ray. It refuses to run outside Studio,
is created by the server only, is reachable only through the server-only audit bindable, is **off by default**, and removes every instance when disabled.

## 3. Impacts: per-weapon, on the armour

`ImpactProfile` (shared, pure, tested) is the recipe table (counts, sizes, light, mark, sound) per weapon class and component family; `DestructionFx.machineImpact` plays it.

| | MG-9 | LR-12 | HMG-20 Mauler |
| --- | --- | --- | --- |
| spark burst | 5, small, **along the reflected path** | 11 fine, fast | 24, large |
| flash / light | pin-point, 14/s decay | hot white-orange, light **lingers** (decay 3.2) | hard flash + shock ring, 17-stud light |
| debris / smoke | none | one wisp of smoke | 12 chips, 4 dark plate fragments, dust |
| persistent mark (server, welded, bounded) | small bright-rimmed pit (16, recycled oldest first) | charred ring + molten dot that cools in 2.6 s (6) | dished crater, lighter rim, two cracks (6 craters, 24 parts) |
| hit reaction | — | — | the whole tank rocks ~1.2° on its suspension for 0.7 s (damped, cosmetic: root CFrame only) |
| sound (existing assets, retuned) | metal "tick", pitch 1.55, vol 0.38 | energy sizzle + zap | metal clang pitch 0.62 vol 1.0 + low explosion thud |

Component modifiers: tracks kick up dirt, turrets ring with extra sparks, the engine / machinery and reactor arc electrically, the reactor vents steam. Tests assert MG < LASER < HEAVY
visual weight on every component with the Mauler ≥ 3× the machine gun, that an MG round is not artillery (no shock ring, fragments, chips or smoke), and that every count is bounded.
`docs/m11b/after_weapon_comparison.jpg` shows all three at once on the same fender: a pit with a few sparks, a molten dot, and a crater with flying chips.

Mark orientation: for mesh hits the player's hitscan fits a plane to four parallel probe rays (`Weapons.SurfaceNormal`) instead of trusting the convex-piece normal (cause 5).
ROOK / Bastion armour is dark, so their marks (`MechDamageFx`) are light bare-metal scuffs on dark plates and dark char on light plates, snapped to the struck part's face.

## 4. Destruction (authored variants, bounded, no runtime mesh surgery)

The authoritative states are unchanged (`Rules.Tank`, `MechDamage`). What changed is what you see:

* **Damage variants.** A translucent soot shell (a textureless 1.2 %-larger copy of the mesh, ≤ 4 per tank) darkens a component as it degrades; `MeshPart.Color` cannot tint the baked texture.
* **Tracks.** On failure the track mesh (which is also its hit body) sags at the rear and skews, ten tread links are thrown out behind it and a road wheel lies beside it
  (two welded parts), the hub sparks and smokes, a clang / dirt cloud / flying links play at the hub, the tank stays immobile through the unchanged rules, dust emitters stop.
* **Turret.** A disabled turret jams a few degrees off-line and slumps nose-down, the roof vents smoke, the gun mount sparks (electrical burst, thrown hatch pieces). It is **not** thrown off for component damage.
* **Engine.** The rear deck blackens (scorch patch + ember), flames show at both louvred grilles, black smoke, a flash, the training beacon dies.
* **Hull (terminal).** A timed sequence (`TankHit.Sequence`, all beats ≤ 2 s): shutdown + primary explosion (0 s) → turret ring fails, the turret is thrown and settles askew on the hull (0.3 s) → two cook-off flashes (0.55 s, 1.0 s)
  → eight breakup plates thrown clear and welded where they land (1.0 s) → fire at the engine, smoke columns and a dying glow (1.1 s). The wreck is persistent and solid; hits still register (sparks) but cost nothing.
* **Mechs.** When an arm assembly, a leg or the reactor of ROOK / the Bastion fails, a region-specific failure burst plays at it (`Destructibles.MechFailure`); existing `MechDamageFx` smoke, fault lamps and shutdown continue to follow the unchanged damage rules.

Instance budget: a tank's damage presentation is welded, non-queryable and owned by its model; `TankHit.MaxParts()` = 93 worst case per tank (asserted ≤ 100). Measured: a tank is 14 children
undamaged; the three tanks together went 42 → 88 children after a wrecked hull, a broken track, a dead engine and a few dozen marks; the district goes 1376 → 1485 descendants at worst and **returns to exactly 1376 after each of six consecutive range resets** (with damage re-applied between).

### Decisions worth recording

* **Splitting the AI mesh (detaching a barrel / half a track) was tried and rejected.** `EditableMesh` made in-experience is fixed-size, a mesh rebuilt from triangles works on the server, but a server-built
  mesh **does not replicate to clients** (they see missing-mesh cubes). The brief prefers authored breakup assemblies over runtime mesh subtraction; posed meshes + welded debris do that with no new asset and no client dependency.
* **No generated damaged-component assets were needed** (the AI asset factory was not used); the existing pipeline and audio assets are untouched, no credential is read or written.

## 5. Offline tests (`tools/check.sh`)

`tools/fidelity_tests.luau` — **29 tests**: engine-deck resolution and exact boundaries; per-component damage independence and consequences (Rules); reset restores every component; destruction-sequence order / duration / instance
budget; weapon recipes (rank, "MG is not artillery", laser glow lingers, Mauler weight, component modifiers, bounds, weapon-id → class incl. `TANK_CANNON`, weapon numbers untouched); reflection; volume fitting (what is kept / dropped, regions, shrink);
**visible hit-proxy alignment** (a ray at each fitted face lands exactly on it) and **near-miss rejection** (0.3 studs beside / above misses); empty air between limbs; first legitimate surface (one region once); cover (a nearer wall blocks, a wall just behind does not);
swept shells and start-inside; rotated boxes; broad phase never changes an answer (400 random rays); deterministic refit (reset and rebuild); per-region mech damage with the model's own spill; shield-plane crossing (frontal, oblique, misses, from behind, flank, already in front).

All suites run by `tools/check.sh`: offline 28, energy 27, profile 19, weapon 19, weapon presentation 10, destruction 19, combat 43, enemy 57, loadout 31, **fidelity 29** — all pass; Luau compile and analyze are clean (only the pre-existing Roblox-global noise); `rojo build` succeeds.
Existing shield (energy / combat suites) and safe-ejection behaviour are unchanged and were re-verified live (below).

## 6. Studio verification (real Play sessions; `tools/m11b_studio_checks.luau`)

1. **True miss.** Rays beside the barrel at 1.0 / 1.6 / 2.5 studs miss (only the muzzle-brake edge at 0.5 hits); a ray passing 3+ studs above the turret passes; ROOK: a ray 5+ studs beside the arm and one above the head miss.
2. **Component resolution** (production `Weapons.Strike`): glacis → HULL; rear deck → ENGINE; lower rear plate → HULL; side of the track → TRACK_L; turret roof → TURRET; the engine grille region on the hull mesh resolves to ENGINE at `x = ±6.5` where the turret does not cover it.
3. **Tracks.** 8 Mauler shots at a track → `IMMOBILIZED`; `after_track_break.jpg`.
4. **Turret.** 32 shots at the roof → `TURRET DISABLED`: slumped, charred, smoking (`after_turret_disabled.jpg`); the tank can no longer aim or fire (rules unchanged).
5. **Hull.** 50 shots → `VEHICLE DESTROYED`: fireball with flying plates, then the persistent wreck (`after_hull_wreck.jpg`). **Engine** (`after_engine_fire.jpg`).
6. **Weapon comparison** `after_weapon_comparison.jpg` (MG pit, laser molten dot, Mauler crater on one fender).
7. **ROOK.** Overlay before/after (`before_overlay_rook_front.jpg` / `after_overlay_rook_front.jpg`); MG / LR / HMG all register on the CORE front plate 2.2 studs in front of the chassis, a leg shot registers LEG_L, a rear shot REACTOR, with a wall in between they register on the wall and never on ROOK.
8. **Combat.** The three tanks engaged the deployed Bastion in ACTIVE mode: 5 shells / 5 hits resolved through the fitted volumes, damaging ARM_R, ARM_L and CORE separately; 14-second ROOK trial fired 42 bolts, 39 hits. Cover: a test wall blocks hitscan to a tank and to ROOK and collapses after 9 Mauler shots, after which the shot reaches the hull. **Shield:** GUARD / PERFECT timing and the interception point as in 2.4. **Safe ejection:** after sustained fire the core failed → `EJECTED - CORE FAILURE`, `pilotSafe = true`, `pilotTargetable = false`, the range returned to PASSIVE, ROOK / tanks stood down.
9. **Resets.** Six consecutive `reset ALL` after wrecking a hull, breaking a track and killing an engine: all three tanks `OPERATIONAL`, `HitFidelity = PRECISE`, descendants back to the baseline each time (above).
10. **Performance.** See below.

### Performance

| | |
| --- | --- |
| precise meshes at world setup | 4 meshes, **1.9 s once per server** (parallel); none after that |
| hitscan ray vs the district (3 tanks, precise) | **6 µs** each (3000 rays) |
| swept sphere r = 1.6 (the heavy shell) vs the district | **58 µs** each; at most 8 shells in flight → < 0.5 ms worst per frame |
| `Destructibles.Step` | 0.03 ms average; the 13.8 ms worst case is a tank rebuild frame (the M10A budget, unchanged) |
| client `DestructionFx` | 0.008 ms average, 0.59 ms worst; **320 instances** in its fixed pools (unchanged), 64 fragments recycled 189 times under fire |
| ROOK hit geometry | 157 plain boxes, zero instances and zero replication; fitted once per rig |
| EditableImage | no new use (the M11B work never creates one) |

## 7. Known remaining limitations

* **Mech volumes are the rest pose carried with the chassis.** The clients pose the drawn rig (gait, arm aiming) and the server does not see that pose, so legs and arms can be a few studs off while the machine walks or aims; standing and at range (the usual fight) they match to 0.13 studs.
* The Mauler hit reaction and every effect were judged from screenshots taken within a second or so of firing; a human has not played the feel. Camera response was left alone on purpose ("no exaggerated screen shake"); the Mauler's recoil is the existing mount recoil.
* The shield ripple was verified through the event payload (timing, `sp` exactly on the plane) and the earlier shield-plane screenshot; a screenshot of the ripple itself could not be timed.
* Marks are flat discs: on strongly curved armour a large mark meets the surface only near its middle (sizes were reduced for that); tank marks are bounded by design (oldest recycled).
* Tracks do not physically detach (see decisions); the broken track sags, loses a wheel and a tread strand. The wreck turret "settles askew" by pose, it does not tumble.
* The training mech M-01 (the stationary target) still uses its M10A joint-attached boxes; `tools/m10a_studio_checks.luau` assumes the old `ENGINE` hit part (the engine is now a region of the hull mesh; use `shoot`).
* Dark ROOK armour hides dark marks, hence the light scuffs; ROOK's own scorch marks are client-side (like the Bastion's) and not shared between players.
* `Weapons.SurfaceNormal` adds four rays per mesh hit (only for hitscan weapons on mesh targets).

## 8. Visual evidence (`docs/m11b/`)

| Before | After |
| --- | --- |
| `before_boxes_side.jpg`, `before_boxes_front.jpg` — the M11A tank hit boxes over the tank (turret box in the air, barrel box beside the gun) | `after_overlay_side.jpg` — the precise hit meshes, one colour per component, on the same tank |
| `before_overlay_rook_front.jpg` — ROOK's 18 hand-placed boxes | `after_overlay_rook_front.jpg` — the 157 fitted volumes |
| (no marks) | `after_weapon_comparison.jpg` — MG pit / laser molten dot / Mauler crater on one fender |
| (tracks squashed in place) | `after_track_break.jpg`, `after_turret_disabled.jpg`, `after_engine_fire.jpg`, `after_hull_wreck.jpg` |
