# M08B — First Weapons

Based on M08A `547c13f`; local branch `feature/m08b-first-weapons`. No push or PR.

## Architecture

- `ComponentRegistry.combat` is the runtime definition on each existing logical component, including compatible sockets, damage category, per-hit damage, interval, range, energy, heat, magazine, reload, muzzle and effects. Existing garage mass/power/nominal ratings remain unchanged and are not treated as live firing measurements.
- `WeaponState` holds pure installed-weapon authorization, cadence, magazine and reload rules. Only LR-12 and MG-9 have functional combat definitions. All six existing sockets and all presets remain intact. Plasma, missiles and micro weapons are displayed as unavailable, not silently substituted.
- `Weapons` owns server intent validation, 350 ms dead-man release, 20 Hz packet limit, operational/deployment checks, integer hardpoint selection, finite world aim, 65-degree forward aim cone, authoritative mount frames, barrel-clearance sweep and range-limited line-of-sight raycast. Clients never supply damage or hits. A server heartbeat emits at most one shot per weapon, with no catch-up burst after hitches.
- Weapons use M08A `Energy.Consume` atomically against the SAME charge, discharge tokens, thermal state and conservation ledger. No second power pool or weapon energy store exists. Payment occurs after locomotion/shield substeps; failed aim, disabled states, cadence rejection, reload and insufficient funds consume no energy or ammunition. Valid shots into empty space/cover still cost resources.
- `WeaponGeometry` uses `RigSpec.SocketLocalCF` and solved joints. Server hit geometry uses the authoritative chassis; cosmetic weapon aiming follows animated joints on clients. The imported meshes are preserved. Invisible rigged muzzle markers are present in both imported and procedural builds.
- `WeaponClient` renders beam core/halo, muzzle glow/light, impact glow/sparks, ballistic tracers and cosmetic shells. Whole weapon assemblies recoil briefly. Effects follow the animated emitter each rendered frame, have no collision/query/physics, expire within 0.5 seconds, cull beyond 650 studs and cap at 48 concurrent effect groups per client.
- `CombatTargets` privately registers mechanical targets. Arbitrary parts, tags, mechs, capsules and Humanoids cannot receive damage. `TargetState` supplies durability, mitigation and repair rules. No PvP or player damage path exists.

## Prototype tuning

| | LR-12 | MG-9 |
|---|---:|---:|
| Fire behavior | repeating pulses while held | automatic |
| Maximum cadence | 4/sec | 10/sec |
| Damage per hit | 25 laser | 8 ballistic |
| Range | 450 studs | 350 studs |
| Energy per shot | 24 units | 0.6 units |
| Maximum firing demand | 96 units/sec | 6 units/sec |
| Additional thermal per shot | 6 percentage points | 0.12 percentage points |
| Maximum additional thermal rate | 24/sec | 1.2/sec |
| Magazine | capacitor | 60 rounds |
| Reload | capacitor regeneration | 3 seconds, automatic at empty or manual |

Fire mode, interval and effects are definition data. This milestone chooses pulses for the laser; a continuous-beam damage mode is not implemented. Magazines receive unlimited range resupply on reload; reserve ammunition logistics are not implemented.

Three range drones at bay-local Z=205 have 600 durability. STANDARD takes full damage; PLATE reduces ballistic damage to 65%; ABLATIVE reduces laser damage to 65%. Billboards show actual durability, hit count and resolved damage. Destroyed targets repair after eight seconds; damaged targets repair after fifteen seconds without a hit. No target AI or target shields were added. Existing M08A shield mitigation regression remains covered independently.

## Controls and cockpit

- Hold LMB to fire. Cockpit aims through the center reticle; exterior aims through the mouse cursor. Camera ray resolves an aim point only; the server resolves the shot from the mount.
- 1–6 select the existing hardpoints in RigSpec order. Unsupported weapons show UNAVAILABLE.
- T reloads the MG. R continues to recenter/reset the camera.
- F deploy/return, WASD drive, Shift sprint, V view, G shield, H/J/K diagnostics, X ejection, Q/E loadout cycling and garage orbit/zoom controls retain their existing roles.
- Focus loss releases firing. Input stops in garage, startup, docking/recovery and evacuation. Return and ejection explicitly cancel firing.
- Existing armament MFD shows accepted selection, actual magazines, mode/state, energy per shot, maximum demand/heat rate, reload/cooldown and confirmed hit/damage counts. The reticle status repeats selected weapon, readiness and hit count. A compact exterior readout supplies firing feedback and energy warnings. Garage loadout panel hides during deployment and returns when stowed.
- Reactor, structure, compass, shield and radar layouts remain intact. M08A reactor demand is continuous demand (including its explicitly labelled weapon-load SIM); weapon burst cost is reported separately. Maximum weapon demand/heat are clearly labelled maximum, not fabricated live rates. Future targeting/contact telemetry remains standby/demo.

## Energy behavior and future profiles

Weapon bursts use capacitor activation costs, as shield activation already does. Reactor surplus replenishes that capacitor through the existing charge limits and thermal efficiency. Sprinting/base drive and shielding leave less surplus and spend the same reserves/tokens, so laser cadence becomes energy limited. There is no free reactor-funded shot and no double debit of an allocated continuous request.

Discrete shots settle after continuous consumers. Prolonged full sprint with an empty capacitor can prevent BOTH weapons; the MG needs much less energy and lasts longer before starvation. Releasing sprint permits recharge and predictable firing recovery. Basic drive retains M08A's conservative limp behavior. This is an explicit settlement order, not an energy allocation profile. M08A's category priorities, demand/delivered rates, capacitor charge/tokens and conservation ledger remain available for a future allocator; no profile switching or speculative profile framework was introduced.

## Verification (2026-10-17)

- Offline movement/gait/deployment/ejection: **28/28** passed.
- Offline M08A energy/shield: **27/27** passed.
- New offline weapons: **13/13** passed, including installed socket authorization, atomic conservation/heat, cadence spam, disabled/invalid aim, insufficient energy, depletion/reload timing, armor categories, repair, combined demands, thermal penalties and limp movement.
- Deterministic 20-second severe-demand comparison: laser stationary 34 shots; laser propulsion 48 + sprint 90 demand 3 shots; same with repeated shield activation 1 shot; MG with the same combined demand 15 shots. These stress inputs deliberately exceed reactor output. Counts include resource starvation and cadence; they are not nominal DPS.
- All source and test Luau files compiled. Filtered standalone analysis of the new modules reported no non-engine diagnostics (standalone Luau does not define Roblox globals/types). `git diff --check` and Rojo build passed.
- Studio startup SelfTest: **24/24**. Existing `m07_studio_checks.luau` and `m08a_studio_checks.luau` passed, including real collision queries, sprint, shield resource competition, perfect/rear/category mitigation, thermal efficiency, empty reserve and cancellation.
- New `m08b_studio_checks.luau` passed against production controller/raycast and isolated registered targets: laser damage 25/cost 24; ballistic PLATE damage 5.2/ammo 59; packet/cadence/invalid-index/vector checks; aim cone; cover; forged target tag; pilot immunity; garage/startup/docking/ejection locks; cancellation and repair. The harness builds its own temporary registered targets and destroys them afterward, avoiding reliance on registration from another Studio command context.
- Actual Play, deployed Bastion: stationary cockpit laser produced **13 confirmed hits in four seconds**, capacitor **16.4**, thermal **53.7%**, state **ENERGY LOW**. Both laser and MG also produced confirmed hits while moving and in exterior view. Keyboard 2 selected MG; actual mouse-down/up produced firing and server ammo consumption. Test BindableFunctions submit the same intent remote and never bypass validation.
- Moving MG: **54 visible muzzle samples**, maximum emitter/flash positional error **0 studs** after frame update. Sample effects used **32 local instances**, mean client frame **16.67 ms**, worst sampled frame **18.31 ms**, server loop EMA **0.096 ms** with one deployed mech. These are short local measurements, not a multiplayer/low-end benchmark.
- Live MG depletion/reload: **60 shots**, **0 rounds / RELOADING**, then **60 rounds / READY** after the configured reload; pilot remained at 100 health.
- Laser and MG built-in audio assets both loaded successfully. Audio is prototype sound design; listening quality is not asserted by the loaded-asset check.
- Actual ejection while held firing: shot count remained **6 -> 6** during the evacuation interval; pilot health **100**; rebuilt mech **STOWED / SAFE**, zero shots. Existing fault-injected ejection tests also pass.
- Final exterior-readout scaling and deployed garage-panel hiding were checked in Play. The captured Studio viewport was narrow (296 px), so broad display/layout QA remains limited.

## Remaining limits

No sustained-beam mode, shielded targets, reserve ammo logistics, enemy AI, PvP, destructive components, missiles/plasma firing or energy profiles. Server aim uses the authoritative chassis/rest socket positions while cosmetic gait and recoil move the displayed muzzle; hit authority is unaffected, but cosmetic start points can differ slightly from the server shot origin while walking. No wide-screen art review, audio listening review or multiplayer stress benchmark was completed. Studio also emitted pre-existing CorePackages style warnings and an unrelated cloud asset-type warning (`203785492`).

The automatic approval reviewer rejected a bulk Studio source overwrite due to possible unsaved-edit loss. Validation proceeded through reads and exact-source guards before narrowly updating only matching modules in the separate M08B test instance; no overwrite of unexpected Studio edits was required.

## Re-run

Run `tools/offline_tests.luau`, `tools/energy_tests.luau`, `tools/weapon_tests.luau` with Luau; `tools/check.sh` includes all three. Build `default.project.json` with Rojo. During Studio Play run the three `tools/m*_studio_checks.luau` scripts on Server. Live client test affordances are `IronframeWeaponControl`, `IronframeDeploymentControl` and `IronframeCockpitControl` under LocalPlayer.PlayerScripts. They operate through normal remote validation.
