# M11A — Modular Mech Engineering & Garage Customization

Branch `feature/m11a-modular-engineering` (from M10C `fee138c`). Local commits only; nothing pushed, no PR.

The garage is now an engineering bay. The player picks weapons for the four hardpoints and one of two reactors, leg actuators and armour sets; the
server validates the request, compiles it **once** into an effective specification, and the deployed Bastion runs on that specification: drive
limits, energy economy, structure, weapons, cockpit telemetry. Build → deploy → fight ROOK / tanks → return → reconfigure works end to end
(screenshots in `docs/m11a/`, real Play sessions through the Studio MCP). **No human has played it.**

## 1. Pipeline (one source of truth)

`ComponentRegistry` (data) → garage catalog (`LoadoutCompiler.Catalog`, derived from `selectable = true`) → `RequestLoadout` (ids only) →
`LoadoutCompiler.ApplyRequest` (whitelist + compile) → `session.loadout` → `LoadoutCompiler.Compile` → **effective spec** → runtime.

| Compile output | Consumed by |
| --- | --- |
| `energy` (EnergyConfig with build modifiers) | `EnergySystems.Create` — reactor output, capacitor, charge rate, heat per energy, cooling, movement energy demand |
| `locomotion` (full drive table, hull unchanged) | `Locomotion.Create(…, effective)` — `MechDrive` limits (speed, reverse, acceleration, turn); client gait saturates at the replicated `TopSpeed` |
| `structure` (six region healths) | `BastionDamage.Create` → the existing `MechDamage` model (`damageCapacity`); repair / reset restore the build's own capacities |
| `weapons` (per socket: damage, cadence, magazine, reload, energy, mass) | garage comparison and sortie report; firing itself still reads the same registry entries through `WeaponState` |
| `metrics`, `stats`, `label` | garage panel, cockpit telemetry (`loadout.*`), sortie report |

Compilation happens at assembly (garage install, preset, ejection rebuild) and deployment reads `session.compiled`; nothing recompiles per frame.
Factory presets are cloned, never edited in place (`Loadouts.presets` stays pristine); `session.loadout` is the session's configuration and
survives deploy, dock, ejection / rebuild, repeated sorties and every range reset. Session-level retention only (no DataStore).

## 2. Components (all numbers in `ComponentRegistry`)

| Slot | Component | Registry data | Effective result |
| --- | --- | --- | --- |
| Reactor | **Core 220** (standard) | 80 u/s, mass 4.0 | capacitor 160, heat 0.12 per energy, unchanged M10C economy |
| Reactor | **Core 260 High-Output** | 112 u/s, mass 5.2, `capacitorScale` 0.65, `chargeRateScale` 1.25, `thermalScale` 1.25, `coolingScale` 1.4 | capacitor 104, charge rate 62.5, heat 0.15 per energy, dissipation ×1.4 |
| Actuators | **Standard** | scales 1.0 | 16.0 st/s, accel 7.0, turn 35°/s, leg 380 |
| Actuators | **Sprint Actuators M-2** | speed ×1.12, reverse ×1.15, accel ×1.2, turn ×1.2, legs ×0.78, movement energy ×1.3, mass +0.6 | 17.9 st/s (sprint 28.7), accel 8.4, turn 42°/s, leg 296 |
| Armour | **Composite** (standard) | integrity 200 (= reference 1200) | structure ×1.0 |
| Armour | **Reinforced** | integrity 500 (structure ×1.25), speed ×0.93, accel ×0.90, turn ×0.94, movement energy ×1.12, mass +1.5 | 14.9 st/s, accel 6.3, turn 33°/s; CORE 1125, arms 375, legs 475, reactor 400 |
| Weapons | MG-9, LR-12, HMG-20 Mauler | the existing components (`selectable`) | per-hardpoint, see below |

Composition is multiplicative and predictable (reinforced + sprint: 16.7 st/s, legs 371, energy ×1.46). Subsystem damage multiplies on top of the build
(`Locomotion.SetMobility` / `EnergySystems.SetReactorScale`), so a destroyed leg still costs the build's own speed under either actuator; the same hit
hurts weaker legs more. A shared mass budget (42 t) and the reactor power budget are enforced by the compiler: e.g. HMG preset + reinforced armour is 43.2 t and is
rejected. Existing components (CORE_300, CAP_HIGH_DENSITY, …) are untouched and compile as before.

**Hardpoints.** Configurable: `left_arm`, `right_arm` (size 3: MG-9, LR-12, HMG-20 or empty) and `left_shoulder`, `right_shoulder` (size 2: MG-9, LR-12 or empty).
Torso micro-mounts are not configurable (nothing implemented fits). Only components with a `combat` entry are offered. Cadence, magazine / reload, energy and heat per
shot, damage, recoil, effects, sound and the HUD name all come from the installed component id: the model publishes `Mount_<socket>` attributes and `MechRig`
reads the weapon for recoil from them (preset lookup remains the fallback), so engineered mounts aim, kick and show their real geometry.
Only one hardpoint fires at a time (the existing selected-slot model), so extra weapons add options and mass, not simultaneous firepower.

## 3. Build identities (created by choices, not new profiles)

| Identity | Example build | What it does |
| --- | --- | --- |
| Fast striker | Sprint Actuators + MG / LR | 17.9 st/s, accel +20 %, turn +20 %; legs 296, movement energy ×1.3 (cruise propulsion 34 → 46 u/s measured) |
| Armored brawler | Reinforced + HMG-20 (shoulders removed, 38.6 t) | core 1125, legs 475; 14.9 st/s; Mauler 25 dmg × 3/s, 24-round magazine |
| Energy marksman | High-Output reactor + LR-12 arms | +35 % held laser shots over 30 s (43 → 58); capacitor 104, hotter conversion, +1.2 t |

`tools/loadout_tests.luau` asserts that no alternative is better in every dimension and that each trades something.

## 4. Garage workflow and controls

Right-hand **ENGINEERING BAY** panel while STOWED in the hangar (hidden in the cockpit view): tabs **WEAPONS / REACTOR / DRIVE / ARMOR**; WEAPONS adds four hardpoint
buttons. Each list shows the registry's components with a one-line summary; selecting one shows installed → candidate numbers only where they change (green gain,
amber price, percentages), the resulting build mass, and — when the server would refuse it — the reason (`MASS LIMIT EXCEEDED`, …) next to what the part would have done. **INSTALL**
sends ids only; the machine on the pad is rebuilt at once (looks follow the mounts: a Mauler appears in the arm, the sprint actuators add accent collars and a coil strip, the
high-output core a heat-sink rack and glowing collar, reinforced armour its existing plates). **REVERT** swaps back to the configuration before the last install. The old preset
buttons are now **FACTORY PRESETS (RESET ALL SLOTS)**. The left panel and the cockpit (reactor name, capacitor `104 / 104`, POWER `29 / 112`, armament rows, structure bars) read the
build's effective values. Configuration is only accepted while STOWED; an install or revert sent while deployed is ignored (verified).

**LAST SORTIE** (bottom of the panel, `SortieReport`): build label, outcome (DOCKED / EJECTED / EJECTED — CORE FAILURE), duration, damage dealt, damage received (applied to the Bastion),
energy spent, peak heat, ROOK result (`DEFEATED IN 41s (CORE FAILURE)` / `NOT DEFEATED` / `NOT ENGAGED`) and the regions lost. It reuses counters the runtime already keeps.

## 5. Server validation

`RequestLoadout` accepts one table `{ mounts = { [socket] = id | false }, systems = { [slot] = id } }`; anything else is rejected with a short reason and the build is untouched:
unknown fields, non-table payloads, non-configurable sockets (torso) or slots (cooling, capacitor, shield), ids not offered for that place (CORE_300, missile pod, plasma cannon,
Mauler on a shoulder, wrong class, oversized / non-string ids), numeric stats smuggled in (`powerOutput`), and any request that does not compile (mass, power). Rate limit 0.25 s,
STOWED and OPERATIONAL only. `Compile` also rejects hand-forged loadouts. A build that only breaks a budget still reports its effective numbers (garage preview) but is not `valid`
and cannot be assembled or deployed.

## 6. Verification

**Offline** (`bash tools/check.sh`): offline 28, energy 27, profile 19, weapon 19, presentation 10, destruction 19, combat 43, enemy 57, **loadout 31** (registry and catalog, hardpoint options, deterministic
compile and no mutation, factory Bastion and ROOK unchanged, reactor / actuator / armour differences against the real `Energy` ledger, `MechDrive` simulation (top speed, acceleration, turn time),
movement-energy demand, damage composition under both actuators, armour survivability, structure retention through reset, profile arbitration conservation on the new reactor, sustained
laser fire with weapon heat, request validation with 24 hostile payloads, session-style retention, weapon slots and disabled mounts). `luau-compile` clean for every file, analyzer clean apart from Roblox
globals, `rojo build` → `build/Ironframe-M11A.rbxl`, Studio self-test 26 / 26.

**Studio Play** (own Studio instance; stages in `tools/m11a_studio_checks.luau`; automated execution, not human play). Installs through the real UI clicks (tab, option, INSTALL, REVERT) and the real remotes; deploy with the real `F`, `F`.

| Item | Result |
| --- | --- |
| A — factory Bastion | PASS: label `CORE 220 / STD DRIVE / COMPOSITE`, controller limit 16.0, capacity 160, output 80, structure 900 / 300 / 380 / 320, drive demand 20 |
| B — mobility actuators (UI install) | PASS: `TopSpeed` 17.92, controller 17.92, turn 42°/s, leg HP 296; measured top speed **17.8** vs 16.0 factory; cruise propulsion demand **46.4 vs 34.0 u/s** |
| C — reinforced armour | PASS: structure 1125 / 375 / 475 / 400 in the live damage model; measured top speed **14.9**; same hit leaves it 25 % further from failure (offline: more hits to core failure) |
| D — high-output reactor (UI install) | PASS: HUD `CAP 104/104`, `POWER 29 / 112`; **LR-12 held 30 s from cold: 58 shots vs 43** (peak heat 97 %, capacitor floor 22 / 104 vs 33 / 160): more sustained throughput, no head start, thinner bank |
| Weapon change | PASS: Mauler on the right arm (geometry, `Mount_right_arm`), LR-12 on the shoulder; Mauler 24 / 24 ammo, cost 2.5, 7.5 u/s, damage 25, 24 hits on ROOK (core 700 → 196), then RELOADING; two Maulers (10 t) rejected `MASS LIMIT EXCEEDED` |
| Full loop | PASS: configure → deploy → fight ROOK → return (sortie report) → reconfigure (UI) → deploy again; `reset MECH` kept the label and the build's own capacity (core 1125 restored to 1125) |
| Safe ejection with a modified build | PASS: core failure → `PILOT_EVACUATED` → rebuilt `OPERATIONAL / STOWED`, same label, same mounts, sortie `EJECTED - CORE FAILURE` |
| Hostile requests | PASS: 12 payloads through the real remote, build unchanged; installs while deployed ignored |
| PASSIVE / ACTIVE / MECH with an engineered build | PASS: PASSIVE 0 shots, ACTIVE tanks fire (ROOK STANDBY), MECH ROOK active (tanks idle) |
| Leaks | PASS: 18 consecutive installs / preset resets: workspace 3959, `IronframeMechs` 830 descendants, constant |
| Console | no script errors from the milestone's code (only the known UIBlox / `ContentId` noise; my own debug camera bindings were removed) |

**Gameplay comparisons (single automated runs, noisy, standing still unless noted)**: time to defeat ROOK holding LR-12 from 505: factory **~25–47 s** (2 runs), high-output marksman **~11–26 s** (3 runs),
reinforced Mauler brawler **~13 s** (1 run, 89 % core left). Damage received by a weaving factory and a weaving striker were equal within noise (508 vs 505 penetrating over 50 s): the scripted weave is too crude
to show an evasion benefit, so evasion benefit remains unproven (speed, acceleration and turn numbers are measured, the combat outcome is not).

## 7. Known limitations

* No human playtest: all tuning (scales above, mass budget, heat / cooling package) is a first pass. In particular the Mauler is far stronger against ROOK than an LR-12 build; it is not a strict upgrade
  (ammunition, reload, 5 t, arms only) but the brawler build is very good against ROOK's armour table and may need ROOK or Mauler rebalancing later (ROOK untouched by design).
* One chassis, three categories plus weapons; torso micro-mounts and the missile / plasma weapons stay unimplemented and are not offered.
* Retention is per session; a rejoin returns to the BALANCED factory preset.
* REVERT is one level. Presets reset every slot (stated in the panel).
* The panel is mouse-driven (gamepad / touch untested); text is small at 1080p and unchecked at other resolutions; no keyboard shortcuts yet.
* Visual differentiation is restrained: accent collars, a coil strip, a heat-sink rack and glowing collar were checked in screenshots, not from every angle. Engineered builds keep the olive palette;
  only the variant dressing (energy spires, ammunition bins) follows the mounts.
* The comparison panel previews with the same shared compiler; if client and server data ever diverged the server wins and rejects.
* The high-output package carries cooling because thermal, not energy, is the real ceiling on held laser fire; the first tuning (hotter, no cooling) measured a +2 % benefit and was replaced.

## 8. Needs human playtesting

Is the engineering panel readable and quick enough between sorties? Do the identities feel different (sprint legs vs reinforced armour vs high-output reactor) in actual duels against ROOK and the tanks?
Is +25 % structure for −7 % speed and +1.5 t a real choice? Does the shallow capacitor bite in normal laser / shield / sprint patterns? Is the Mauler too dominant? Is the LAST SORTIE block the right amount of feedback?

## 9. Branch and commits

Branch `feature/m11a-modular-engineering`, feature commit: see the next section header once committed. Not pushed, no PR.
