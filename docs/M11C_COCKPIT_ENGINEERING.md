# M11C — Cockpit Engineering & Tactical Avionics

Branch `feature/m11c-cockpit-avionics` (from M11B `4eac7b1`). Local commits only; nothing pushed, no PR.

The Bastion's cockpit is now a working sensor environment. The radar shows real entities from an authoritative server sensor model, the optics zoom the one
camera controller, a thermal imager renders only what the server says has a visible signature, a tracker locks a machine the pilot can actually see, and all of
it is installed, weighed and powered through the M11A engineering bay. Two equipment packages (STANDARD, RECON RETROFIT) fit the same frame with different
interiors, bays and sensor performance. Everything was exercised in real Play sessions through the Studio MCP (automated, **not human play**).

## 1. Architecture: frame, package, avionics

| Concept | Where | What it is |
| --- | --- | --- |
| **Layout** (the physical frame) | `CockpitLayouts` (`frames.BASTION_FRAME`), `ChassisRegistry.IF42_BASTION.cockpit` | eye point, displays and their canvases, equipment **mounts** (`auxLeft`, `auxRight`, `hood`), annunciator list. A future chassis names its own layout. |
| **Cockpit package** (equipment) | `ComponentRegistry` class `cockpit` (`CKP_STANDARD`, `CKP_RECON`) | mass, rated power, avionics **bays**, palette, fittings list, sensor bonuses, `layouts` it fits |
| **Avionics module** | `ComponentRegistry` class `avionics` (`slot` = radar / optics / thermal / targeting) | mass, rated power, `sensor` capability numbers |
| **Shared services** | `Avionics`, `SensorModel`, `ThermalSignature`, `TargetContract`, `ZoomControl`, `CockpitWarnings` (shared, pure) + `TargetRegistry`, `AvionicsService` (server) | written once; no cockpit variant has its own radar |

`LoadoutCompiler` compiles `loadout.cockpit` (one id) and `loadout.avionics` (`{ [slot] = id }`; a missing map means the chassis' factory equipment, so factory presets and
their labels are byte-identical to M11B) into `compiled.cockpit` and `compiled.avionics` (the effective sensor spec after package bonuses), and adds mass / rated power to the
same budgets as every other component. Layout and package link by name only: a chassis with a different frame, camera anchors, console arrangement and catalog reuses every
sensor service unchanged, and the displays are the only layout-specific consumer (the HUD builds one SurfaceGui per entry of the layout's display list; the radar draws on
whichever display the layout calls `ConsoleR`).

## 2. Equipment catalog and tradeoffs

| Component | Mass | Rated power | Capability |
| --- | --- | --- | --- |
| **CKP_STANDARD** Industrial Combat Cockpit | 0 | 0 | 2 bays. Amber / green instruments, work lighting, toggle guards |
| **CKP_RECON** Recon Retrofit | 1.1 t | 2.0 u/s | 3 bays. Radar range ×1.15, scan rate ×1.25, thermal range ×1.2, tracker component analysis (detail 2). Aux monitors, blue-white lamps |
| **AV_RADAR_BASIC** RS-4 (integrated) | 0 | 0 (idle bus) | 240 st, 1.7 scans/s, 5 st / 3° resolution, identifies inside 150 st, no heading, obstruction −60 % per wall |
| **AV_RADAR_ENHANCED** RS-9 | 0.9 t | 5.0 | 400 st, 4 scans/s, 1 st / 1° resolution, full identification, heading and speed, obstruction −35 % per wall; falls back to RS-4 numbers when starved |
| **AV_OPTICS_ZOOM** OP-2 | 0.5 t | 1.5 (0.4 standby at 1×) | 1× / 2× / 4× with gyro stabilisation |
| **AV_THERMAL** TI-3 | 0.9 t | 8.0 (0.8 off) | thermal view of machines in line of sight out to 260 st |
| **AV_TRACKER** TC-1 | 0.6 t | 4.0 (1.0 idle) | lock a visible machine within 300 st, status (detail 1) or component analysis (detail 2) |

Radar occupies its own mast slot; the other three modules each need a **bay**, enforced by the compiler (`Avionics bays exceeded`). The factory Bastion carries the integrated
RS-4 only, so a factory deploy has working radar and nothing else. The Bastion presets are 39.7 / 41.6 / 41.0 / 41.7 t of 42 t, so every module is a real choice: on
BALANCED the full Recon suite (4.0 t, 20.5 u/s rated) is only possible after dropping the 3 t missile pod; on AUTOCANNON even the 0.5 t optics need a weapon removed. Standard
takes two of the three bays, Recon all three plus better sensors for +1.1 t and +2 u/s. Nothing is strictly better (`tools/avionics_tests.luau` asserts it).

**Energy.** Optional avionics are a new ledger key, `avionics`: priority 6 (below sprint) and a default capacitor floor of 25 % (`Energy.Floor`, honoured exactly like a
profile reserve): sensors ride on reactor surplus and the top of the capacitor and never eat the charge the shield needs. Idle and propulsion stay mandatory and first. Demand is
`Avionics.Demand(spec, modes)` computed by the server from the compiled equipment and the current zoom / thermal / lock state, written to `EnergySystems` as `avionicsDemand`;
the ledger's delivered share becomes `avionicsFactor` (smoothed, published as `AvionicsFactor`). The three energy profiles and their arbitration are untouched (tested: propulsion
and idle are served in full under all three profiles with the full suite fitted; the ledger still conserves energy).
Consequences of starvation (`Avionics.Capability`, measured in Studio): RS-9 → RS-4 numbers (DEGRADED), thermal "NO POWER", tracker loses analysis then goes offline below 15 %,
optics unstabilised (full magnified shake). The integrated radar keeps working at any power. Sensor-mast damage (core health ≤ 60 % / ≤ 25 %) cuts radar reach to 85 % / 60 %
and, when critical, takes out thermal and tracker analysis.

## 3. Sensor architecture and the radar

`AvionicsService.Step` (one Heartbeat hook, 10 Hz evaluation per deployed pilot):

1. `TargetRegistry.Collect` adapts the district's actors (training tanks, ROOK-01, the M-01 training mech) into `TargetContract` tables (id, kind, position, heading,
   operational / disabled / destroyed, powered, shot counter, components function). New actor kinds register another provider; a malformed actor is skipped and warned once.
2. `Avionics.Capability(spec, powerFactor, coreHealth)` decides what the equipment really does this instant.
3. `SensorModel.Scan` (due every `interval`): a contact is created or refreshed when the actor is inside `range × (1 − obstruction × min(walls, 2) / 2)`. **Radar is not
   line of sight**: walls cost range, they do not hide a close machine (`countBlockers` casts at most 3 rays, `RespectCanCollide`). A machine beyond the reduced reach is not
   returned. Resolution is quantised to the module's step, identification (name, archetype) needs the contact inside `identRange`, contacts have **opaque numeric keys**
   (an unidentified contact cannot be matched to a name), heading and speed only on RS-9. Aging: stale after 1.5 s (RS-4) / 1.0 s (RS-9), dropped after 6 / 10 s; a wreck stays
   as a DESTROYED contact for 15 / 25 s, is then cleared and is not re-acquired until the machine is rebuilt.
4. Lock maintenance and thermal visibility use real optical rays from the pilot's eye (own machine and the target excluded; another machine in front **is** cover).
5. One bounded `AvionicsUpdate` packet (≤ 8 contacts, ≤ 4 thermal entries, the lock, capability summary) to the owner, at most 10 per second; nothing is sent for a docked
   machine and a final `off` packet clears the client.

**Radar display.** The right console's SENSORS display became RADAR (`CockpitHud.buildSensors`): up is the machine's heading (chassis, not camera), cardinal letters and contacts
rotate against it every frame with writes only when the heading moved > 0.15° or a packet arrived, a thin rim marker shows where the pilot is looking, three scales (O), blip
shapes (square vehicle / diamond mech, hollow = unidentified, X = destroyed, x = disabled, dim = stale, white ring = locked), heading ticks on RS-9, and a ping ring that fires
once per real scan return. The decorative rotating sweep and the DEMO tag are gone.

**Leak boundary (honest).** Contacts, locks and thermal data reach the client only through the owner's packet; every avionics display reads that. The client can still *read*
replicated workspace models (the place does not use StreamingEnabled), as it always could, and the M10B / M10C `CombatHud` threat alerts (unchanged) still scan the district
models; a modified client could read enemy positions regardless of any HUD. What M11C guarantees is that no instrument shows information the equipment does not provide, and
that the server decides detection, identification, locks and thermal visibility.

## 4. Optics, thermal, tracking

**Zoom.** `AvionicsClient` owns a `ZoomControl` state; `CockpitMode` stays the single camera controller and asks `avionics.Camera(baseFov)`: the field of view is
`2·atan(tan(base/2) / m)` of the controller's own baseline (already capped for ultrawide), smoothed in log space, never degrees ÷ m. Measured: baseline 58.15° → 2× 31.07° → 4× 15.83°
(tan ratios 1.998 and 3.99). Head-look sensitivity scales by 1/m; sway is stabilised (constant on screen) while powered. The server confirms the mode (`AvMag`); zoom changes **no weapon
number** (asserted offline; verified in Studio: 14 of 14 MG-9 rounds hit the machine under the reticle at 2×). `Reset` runs on cockpit toggle off, garage return, ejection, a rebuilt
machine, entering the cockpit and every dock: after an ejection from 2× the camera read fov 51.6 → garage 50.0 → restored cockpit 58.1 with zoom 1.00 throughout.

**Thermal.** `ThermalSignature.Level` is a game rule: running engine 0.42, +0.18 moving, +0.28 × the machine's own reactor heat (ROOK's real thermal ledger), +0.34 pulse after a shot
(6 s), disabled / destroyed machines cool from the level they had with a 28 s half-life, a burning wreck holds +0.22 for 45 s, an unpowered intact machine is ambient 0.06. Memory is
updated for every actor every tick, seen or not. View (`ThermalView`, FULL): camera-parented ColorCorrection (saturation −0.7, contrast, cold tint) + light blur, 54 faint scanlines,
vignette, and one **`Highlight` with `DepthMode = Occluded`** per hot machine (≤ 4) coloured by level; no `AlwaysOnTop`. The server lists only machines in range with a clear optical
ray and signature ≥ 0.08. Fallbacks: BASIC (low quality: colour correction only) and MARKERS (no `Highlight`: heat blobs at the machines' screen positions, tested in Studio).
While the imager is on the cockpit canopy glass is set fully transparent: Studio showed the nearly invisible glass still occludes depth-tested highlights. No texture generation,
no EditableImage, no second scene.

**Tracker.** `L` sends the camera look vector; the server picks real actors inside the cone (7° / zoom) that are in range and optically visible; `L` again cycles (24° cone); `U`
releases. The lock is TRACK while the optical ray is clear, COAST for 3 s behind cover (box turns amber, "OBSCURED: COASTING"), then released; a destroyed target is held 2 s then
released; out of range ×1.15, tracker offline or starved release it. The box (`AvionicsClient`) follows the locked machine's real replicated model (server centre minus the model pivot
at first sight, so it cannot drift) with a ~12 Hz cover raycast; off-screen it becomes an edge arrow. Component analysis (RECON, power OK) lists real component **bands**
(NOMINAL / DAMAGED / CRITICAL / OFFLINE) from the authoritative damage state; exact health is never sent. No fire control, no lead prediction: informational only. Weapon range
(IN RANGE / OUT OF RANGE) uses the selected weapon's registry range.

## 5. Cockpit packages in the interior

STANDARD keeps the established geometry and gains amber-and-green instruments (`INDUSTRIAL` palette), subdued warm lamps, industrial extras (roof work-lamp housings, toggle guards, a
bulkhead plate) and its own boot log. RECON adds: two swing-arm **auxiliary monitors** (TARGET ANALYSIS, SENSOR ARRAY) mounted outside the forward cone at ±45°, a **sensor control
bank** under the right monitor (four status lamps, lit only while radar online / thermal on / optics > 1× / lock tracking, with toggles and dials), a roof **sensor head**, ice-blue
strip lighting, `RECON` palette and boot lines naming the fitted modules ("RADAR RS-9 … ALIGNED", "THERMAL TI-3 … FPA COOLDOWN"), a lighter hum and louder air handler (`CockpitAudio.SetPackage`).
Both carry a six-lamp **annunciator strip** (CAP / RCTR / SENS / THRM / WPN / CORE) on the dash: `CockpitWarnings.Evaluate` from live telemetry, amber for a caution, red and pulsing
only for a critical state, silent otherwise. The package is rebuilt (`Builder.Build`, `Hud.Rebuild`) only in the garage view; a package installed while in the cockpit view applies on exit.
The assets are procedural parts: **no new AI assets were generated** (the existing CPT_001..004 meshes are untouched).

**Instrument audit.** STRUCTURE (damage feed), REACTOR (adds an AVIONICS row and starvation warning), ARMAMENT, compass and shield line were already live. DIAGNOSTICS (self-test and rig
counts, not combat information) became TARGETING. SENSORS became RADAR. The overhead list is now all live: REACTOR, COOLING (thermal load), HYDRAULICS (leg damage), EJECTION, LOCOMOTION,
SENSORS, TARGETING, FIRE CONTROL; LIFE SUPPORT (a static label) was dropped. Wall placards (coolant loop, aux power, canopy seal) remain as secondary environmental detail.

## 6. Garage workflow

The engineering bay gained **COCKPIT** (package list with mass / power / bays and a FACTORY EQUIPMENT reset) and **AVIONICS** (RADAR / OPTICS / THERMAL / TRACKER slot buttons, module list, `EMPTY BAY`)
tabs: same comparison panel (`RADAR RANGE`, `SCAN RATE`, `IDENT RANGE`, `MAX ZOOM`, `THERMAL RNG`, `TRACK RANGE`, `TRACK DETAIL`, `AVIONICS MASS`, `RATED POWER`, `BAYS USED`, `BUILD MASS`), same INSTALL / REVERT,
same server validation path (`RequestLoadout` now also accepts `cockpit` and `avionics`, ids only). Rejections show the compiler's reason (`AVIONICS BAYS EXCEEDED`, `MASS LIMIT EXCEEDED`).
Retention: equipment lives in `session.loadout`, so it survives deploy, dock, ejection rebuild, trial reset and sortie after sortie (verified through ejection). A factory **preset** resets the
weapon / reactor / drive / armour slots and **keeps** the cockpit and avionics; if the retained equipment would not fit the preset's mass or power the factory equipment is restored instead
(verified: MISSILE preset over a two-module Standard build reset the modules). No DataStore.

## 7. Controls (audited against every `KeyCode` in the client)

Already used: A B C D E F G H J K M N Q R S T V W X Space Shift Alt arrows 1–8 Minus Equals. New, cockpit view only, deployed and operational: **Z** zoom cycle (1× / 2× / 4×), **Y** thermal,
**L** acquire / next target, **U** release, **O** radar scale (full / ½ / ¼). A small clickable strip at the left edge mirrors them (ALT frees the cursor) and is greyed where nothing is fitted;
the in-cockpit hint strip lists them. Existing deploy, shield, weapons, energy profile, training and camera bindings are unchanged.

## 8. Verification

**Offline** (`bash tools/check.sh`): offline 28, energy 27, profile 19, weapon 19, presentation 10, destruction 19, combat 43, enemy 57, loadout 31, fidelity 29, **avionics 42** (new:
package / catalog definitions, five-module catalog, factory presets unchanged, bay / mass / power budgets, wrong slot / unknown / hostile payloads, retention through weapon requests,
`Same` and labels, detection range, bearing and distance, resolution, obstruction numbers, identification, contact aging and expiry, wreck hold and re-acquisition, power starvation and
sensor damage capability, run-time demand, energy ledger with the avionics load (priority, capacitor floor, profile arbitration and conservation), thermal signature rules, true optical
magnification, zoom clamp / smoothing / reset for six lifecycle paths, zoom absent from weapon data, annunciator rules). `luau-compile` clean for every file, analyzer clean apart from
Roblox globals, `rojo build` → `build/Ironframe-M11C.rbxl`, Studio self-test 26 / 26.

**Studio Play** (own Studio instance; scripts in `tools/m11c_studio_checks.luau`; real client controls and remotes; automated execution):

| # | Requirement | Result |
| --- | --- | --- |
| 1 | Factory Bastion from the garage into Range 07 | PASS: RS-4 ONLINE, 5 contacts, demand 0 |
| 2–3 | Radar contacts for real tanks | PASS: T-01 / T-02 / T-03 identified inside 150 st, M-01 and ROOK-01 as UNK (disabled / active); bearings 225 / 171 / 156 / 195 / 180 from (0, 400) facing +Z |
| 4 | Turn and confirm bearings | PASS: absolute bearings identical after a 180° yaw change (T-01 225, T-02 171 …) while the machine turned from +Z to −Z; the display rotates them against the chassis heading (the blips moved from the top half of the scope to the bottom half) |
| 5 | Moving patrol tank | PASS: T-03 b 33 → 155 → 148 → 136 and d 91 → 47 → 38 → 29 over 8 s |
| 6 | Disable a tank | PASS: T-02 contact ACTIVE → DISABLED (turret) → DESTROYED; actor heat 0.63 just after the kill; lock → DESTROYED → released after 2 s |
| 7 | Obscure a target | PASS (test wall between the pilot and T-02): radar kept all 5 contacts, thermal list 4 → 1, lock COAST "OBSCURED: COASTING" then released after 3 s |
| 8–9 | MECH TRIAL, acquire and track ROOK | PASS: lock ROOK-01 TRACK at 76 st, component bands for all six regions, IN RANGE; sensor-mast damage from ROOK's fire lowered radar reach as designed |
| 10 | Zoom changes the real FOV | PASS: 58.15° / 31.07° / 15.83° at 1× / 2× / 4×; firing at 2× hits the machine under the reticle |
| 11–12 | Thermal and cover | PASS: orange glow on machines, ROOK glowing only where visible past cover, nothing behind the wall (screenshot 05); depth mode Occluded; found and fixed: canopy glass occludes highlights |
| 13 | Tracking and target loss | PASS: box on the model, edge arrow off-screen, COAST → released, destroyed → released, out-of-range release (offline) |
| 14 | Recon interior | PASS (screenshots 04, 06–09): aux monitors, sensor head, blue-white lighting, RC-7 plate |
| 15 | Alternate avionics and demand | PASS: UI installs; demand 9.2 idle, 19.4 with imager + zoom + lock; bay limit message for a third module in the Standard cockpit |
| 16 | Energy starvation | PASS: factor 0.00 → RS-9 → RS-4 DEGRADED (276 st, 0.48 s), thermal NO POWER, tracker offline, "SENSORS STARVED / DEFICIT"; full recovery within 5 s (screenshot 10) |
| 17 | Redeploy keeps the equipment | PASS: three deploy / dock cycles and an ejection rebuild; label, package and modules identical |
| 18 | Safe ejection and camera restore | PASS: zoom + thermal on → ejected → fov 51.6 → garage 50.0 → cockpit 58.1 restored, zoom 1.00, thermal off, avionics inactive, demand 0 |
| 19 | Tank training and ROOK combat unchanged | PASS for what was exercised: passive range, MECH TRIAL (ROOK engaged and hit the Bastion), firing, destruction by audit shots, ejection, reset; ACTIVE TRAINING was not re-run this milestone (no change to it); console clean of milestone errors |
| 20 | Repeat cycles, cleanup, hostile input | PASS: workspace 5696, PlayerGui 490, camera children 2, constant over six toggle cycles and three deploy / dock cycles; 17 hostile loadout payloads and 13 hostile avionics commands left the build unchanged and logged nothing |

**Performance.** Server: avionics service ≈ 0.15 ms per active evaluation (worst 0.74 ms observed), ≈ 53 rays/s at 5 actors with RS-9 + thermal + lock on the Recon package (5 scans/s), ≤ 10 packets/s, no per-frame cost when docked. Client: avionics step 0.031 ms/frame, cockpit step 0.25 ms/frame (466 → 514 parts with the Recon fittings), thermal view
70 instances while active (54 scanline frames) and none when off. Instance counts after the three cycles equal the counts before. (Single measurements in one Studio session, not a benchmark.)

**Screenshots** (`docs/m11c/`, captured through the Studio MCP from the live client; 01–07 and 09 come from an intermediate build of the same session, before the strip dimming, font and bank-position
fixes; 08, 10, 11 are from the final build):
`01` Standard cockpit, `02` radar with five real contacts (Standard), `03` garage AVIONICS tab, `04` Recon cockpit (stowed), `05` thermal + 2× zoom + tracking box, `06` Recon TARGETING and TARGET ANALYSIS
displays and roof sensor head, `07` sensor array display with the radar, `08` Recon cockpit with lock T-02 in daylight, `09` SENSOR ARRAY monitor, `10` energy-starved avionics, `11` MARKERS thermal fallback.

## 9. Known limitations

* No human playtest. All sensor, power and mass numbers are first-pass; the tradeoffs are measured, not proven fun.
* Radar obstruction counts distinct solid structures only (cap 2); there is no terrain horizon, no weather, no clutter. Contacts do not model jamming or stealth.
* Thermal is a game effect: the signature is a number from machine state, the view is colour correction plus occluded highlights. It does not model wall radiation, ambient temperature or surface material, and
  hot muzzle flashes or impacts do not leave heat marks. One flat level colours a whole machine (no hot engine deck). The canopy glass is cleared while the imager is on. Highlights cap at 4 machines.
* Tracking boxes follow the replicated model; a machine not streamed in falls back to extrapolating the server position. The tracker has no ballistic computer and no lead.
* `CombatHud` (M10B / M10C) still scans the district models for its threat alerts; the client can read replicated models. See section 3.
* The recon package changes the interior and the sensors, not the exterior mesh. No second chassis, no new asset generation; the aux displays are small and need a head turn; text sizes were checked at 1080p-class
  captures only.
* The clickable control strip is mouse-only; gamepad and touch are untested. Radar scale is client-side.
* Ambient audio differences are one filter / pitch / volume profile (no new sound assets); the annunciators have no sound.
* A factory preset keeps the cockpit and avionics and resets them only when they do not fit; REVERT is still one level.

## 10. Files

New shared (pure): `Avionics`, `SensorModel`, `ThermalSignature`, `TargetContract`, `ZoomControl`, `CockpitLayouts`, `CockpitWarnings`. New server: `TargetRegistry`, `AvionicsService`. New client:
`AvionicsClient`, `ThermalView`. Changed: `ComponentRegistry`, `ChassisRegistry`, `LoadoutCompiler`, `Energy` (priority + floor for `avionics`), `EnergySystems`, `Telemetry`, `Main.server`, `RangeControl` (audit commands),
`CockpitBuilder`, `CockpitHud`, `CockpitMode`, `CockpitAudio`, `EngineeringPanel`, `IronframeClient`. Tests `tools/avionics_tests.luau` (in `check.sh`), `tools/m11c_studio_checks.luau`.

## 11. Branch and commits

Branch `feature/m11c-cockpit-avionics`, feature commit `73ab270` on top of M11B `4eac7b1`. Not pushed, no PR.
