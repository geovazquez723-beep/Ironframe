# M06A — Immersive first-person cockpit

Branch `feature/m06a-immersive-cockpit`, from M05 `6dc62e2`. Committed locally, not pushed, no PR.
Screenshots are in this folder. Every claim below was observed in Roblox Studio Play unless listed under "Not verified".

## Architecture

Single camera system, two providers:

| Piece | Role |
| --- | --- |
| `CockpitMode` (new) | The only mode coordinator. Owns V / R / head-look / cursor / transitions / boot sequence / ejection reaction. Binds one render step at `Camera + 2`. |
| `GarageCamera` (changed, +`SetActive`, `GetCFrame`) | Unchanged exterior orbit controller. While the cockpit owns the camera it ignores all input, drags are released, and it keeps solving its pose so transitions blend to the live garage view. |
| `ShowroomAnimator` (changed, +`TorsoCF`) | Exposes the solved world frame of the animated Torso joint (from `MechRig.Apply`, which now returns the joint frames). |
| `CockpitBuilder` | Client-only interior in the **Torso joint frame**; one `PivotTo(torsoCF)` per frame keeps it glued to the animated torso. Parented to Workspace only while inside. |
| `CockpitHud` | 6 physical `SurfaceGui` displays + `ScreenGui` overlay (compass, reticle, banners, warning). |
| `CockpitAudio` | Roblox-native sounds only (see below). |
| `Telemetry` + `CockpitConfig` (shared) | Bus every instrument reads; tunables. |

* **Pilot eye**: `Config.EYE_OFFSET = (0, 4.3, -0.55)` in the Torso frame (inside the chest cockpit, behind the canopy at z -3.5). The camera is `torsoCF * eye * head-look`, so it turns with the +-16 deg torso animation. No competing controller exists; `RigSpec`, the 14 joints, the 6 sockets and the loadout compiler are untouched (self-test `m06a: rig contract untouched` asserts it).
* **Transitions**: 1.1 s blend between the garage pose and the live eye, under a dip-to-black timed so the lens crosses the hull while the screen is black. The exterior chest/head hull around the pilot (parts whose centre is inside a Torso-local box, never weapons/mounts/hydraulics, ~59-65 parts) is hidden with `LocalTransparencyModifier` only while inside, re-asserted every 0.5 s and re-applied automatically after a loadout rebuild. Nothing changes for other players or on the server.
* **Cursor/input reset**: entering locks the mouse to centre and hides the icon; leaving restores `MouseBehavior.Default` and the icon, releases garage drags, resets head-look. Holding Alt frees the cursor for the buttons.
* **Local lighting adaptation** (client-only, restored on exit): hangar spot lights near the mech get shadows enabled and the mech's own `ReactorCore` lamp is switched off. Without this the interior was lit "through its roof" (see Findings).
* **Ejection**: the server `Ejection` state machine is unchanged. The client watches the mech `State` attribute: on `PILOT_EVACUATED` it shows the red warning (indicators and cabin lights pulse red) for 0.45 s, then flies the camera out to a safe external view (done before the server's 1.0 s `DISABLE_DELAY`), shows `PILOT EVACUATED / MECH DISABLED / REBUILD IN PROGRESS`, and after the server rebuild re-enters the cockpit with the new mech.

## Cockpit geometry
Procedural (controlled, structural): armored canopy with A-pillars and hairline mullions, sill/header/brow, floor/roof/walls with ribs, dash body and cowl, three MFD bezels, two wing consoles, overhead display housing, seat, harness, lap belt, armrests, two control sticks, pedals, 8 wall equipment modules with vents, clamps and bolts, cable runs, roof conduits, hazard banding, 6 labelled placards, edge-lit strips, 32 indicator LEDs, 5 point lights. The central forward cone is free of structure except two 0.07-stud mullions.

## AI-generated assets (batch_003, 2 concurrent jobs, existing acceptance flow)
| ID | Role | Result | Persistence |
| --- | --- | --- | --- |
| CPT_001 dash shell | cowl over the MFD bank | 5,734 tris, 2 MeshParts, came out 2.3 wide (asked 5.0) so stretched ~1.5x in X | CLOUD_VERIFIED |
| CPT_002 console housing | cabinet under each wing-console screen (same mesh both sides) | 5,690 tris, 2 MeshParts, shorter than asked | CLOUD_VERIFIED |
| CPT_003 control stick | both hand controls | 3,884 tris, 2 MeshParts, short bell-shaped grip (reads as a stick, not a perfect one) | CLOUD_VERIFIED |
| CPT_004 overhead panel | two flanking the overhead display | 4,904 tris, 2 MeshParts, narrower than asked | CLOUD_VERIFIED |

Cloud ids are in `AssetRegistry`; the server loads them (`InsertService:LoadAsset`) at start and replicates read-only copies to `ReplicatedStorage/IronframeCockpitAssets`. Verified over repeated fresh Studio launches: `Loaded 21/21 AI assets`, `Replicated 4 cockpit AI assets to clients`. No place file is needed. The cockpit is complete without them (procedural stand-ins build when an asset is missing).
Generated counts: 4 assets, 8 MeshParts defined, 14 MeshPart instances in the cockpit (CPT_002/003/004 are placed twice).

## HUD
Palette: near-black panels, gunmetal geometry, cyan primary, amber status, red only for the evacuation warning. Fonts Michroma (titles) / RobotoMono (data).
* **Physical SurfaceGuis** (fixed-size canvases, `LightInfluence 0`): left MFD STRUCTURE (schematic + per-section armor bars), centre MFD REACTOR (power draw/output, heat generation, cooling, net), right MFD ARMAMENT (6 hardpoints, selected hardpoint, groups), left console DIAGNOSTICS (self-test, rig, mass, torso yaw, pilot safe), right console SENSORS (radar with live bearing ring and sweep), overhead SYSTEMS list + status line.
* **ScreenGui overlay**: compass tape + heading, system mode line, minimal reticle with stabilization marks, boot log/banner, evacuation warning, fade layer, mode and eject buttons. UIScale tracks viewport; vertical FOV is reduced on ultrawide so horizontal FOV stays <= 106 deg.
* **Honest data**: LIVE = authoritative server state republished on the Telemetry bus (loadout metrics, mounts, preset, pilot safe, self-test, rig). STANDBY = not implemented (damage feed, heat storage, ammunition, fire control, targeting, locomotion). DEMO = labelled placeholder (reactor idle RPM, radar sweep). The armor bars show rated integrity and say `DAMAGE FEED: STANDBY`.
* **Update model**: static layout built once; text/bars refresh at ~6 Hz when telemetry changed; only compass, radar sweep and RPM move per frame (one engine tween drives each screen's scan bar).

## Startup sequence
First entry (~9 s, skippable with Space): dim cabin, reactor spool-up audio, cyan strips and 32 indicator LEDs come on progressively with light flicker, six displays show an INITIALIZING bar one after another, an eight-line diagnostics log, then `IF-42 BASTION — SYSTEMS ONLINE`. Later entries relink in ~0.4 s.

## Audio
Only files shipped inside the Roblox client (`rbxasset://sounds/*`) through the Audio API: reactor hum (explosion sample, pitched down 0.32x, 24 dB low-pass at 150 Hz), air handling, distant hangar bed, startup blips. Studio has no synth instances (`AudioOscillator` is unavailable), so no sound is generated. A bug (wrong enum name) was caught by `CockpitMode.Stats().audio`; after the fix all three voices report `built`, `IsPlaying = true`, loaded length > 0.

## Verified controls and behaviour
* Real keyboard input via the Studio MCP: `V` enters/exits, `Left` arrow head-looks (-31.5 deg after 0.5 s), `R` recenters to 0.0, garage key `2` still gives the side profile after returning.
* 5 consecutive enter/exit cycles plus V-mashing during a transition: always ends in a consistent mode; garage FOV back to 50, `CameraType` Scriptable, mouse `Default`/icon on; cockpit has `LockCenter`/icon off; hidden exterior parts 0 outside and 59-65 inside.
* Head-look limits (yaw +-55, pitch +28/-32) render without clipping through the shell (screenshots 02, 03, 04a, 04b); the interior is a closed volume and the eye never translates.
* Cockpit follows the torso: `pilot.torsoYaw` telemetry moved over time (-14 to +16 deg observed) while the HDG tape, radar ring and view tracked it.
* All three presets through `Q/E` inside the cockpit: weapon readouts, power/heat/cooling numbers and hidden-exterior set update (screenshots 07a/07b; BALANCED in 01).
* Ejection: the sequence above, twice. At t=1.6 s the mech is gone and the camera is external (`GARAGE`, cursor free); at t=7.1 s the new mech exists and the cockpit is restored with hidden parts re-applied.

## Tests
* `tools/check.sh`: syntax clean for all files; only the usual Roblox-global analyzer notes are filtered.
* Server self-tests 22/22 at start (4 new: rig contract untouched, eye/limits/comfort invariants, telemetry bus, cockpit asset replication read-only).
* Asset factory: `validate` ok, `catalog` and `registry` regenerated (21 assets).

## Performance
* Cockpit: 452 parts (14 AI MeshParts), 6 SurfaceGuis, 32 LEDs, 5 point lights; exterior mech unchanged at 306 parts (22 AI meshes).
* Cockpit `step` cost 0.69 ms mean per frame (its own render step, including hull-hide re-assert and HUD).
* Heartbeat averaged 60.0 Hz in both garage and cockpit (display-capped, so headroom is not measured), 3256x1153 viewport.

## Findings
* Interior surfaces were blown out white by the hangar floodlights (no shadows) and the mech's rear reactor lamp; fixed by the client-only lighting adaptation above plus shadow-casting shell pieces.
* The first window slit was cropped by a solid dash body; found by raycasting screen pixels, fixed by lowering it.
* Neon + bloom makes tiny LEDs look large; LEDs are dimmed 40 % and sized 0.045-0.07 studs.
* The black discs in the garage side view are baseline M05 joint caps (same in `docs/m05/03_side.jpg`), not a regression.

## Not verified / limitations
* **Mouse head-look** is implemented (`InputChanged` deltas under `LockCenter`) but the synthetic mouse in the Studio harness produced no deltas, so only keyboard head-look was observed.
* **Audibility and mix** were not heard; only instantiation, loading and playing state were checked.
* Only an ultrawide 2.8:1 viewport was captured; 16:9 is handled by the FOV cap but not screenshotted. No gamepad/touch cockpit controls.
* Single local client; replication to other players is by design (nothing in the interior or the local hull-hiding replicates) but was not tested with two clients.
* Reactor idle RPM and radar sweep are DEMO; damage, heat, ammunition, targeting and movement displays are STANDBY.
* AI meshes came out smaller/different from the briefed sizes; the stick in particular is an approximation. A second generation pass could improve CPT_003.
* Swaying/vibration defaults are tiny (`SWAY` 0.0022 rad, `VIBRATION` 0.0035 studs); `player:SetAttribute("CockpitComfort", 0)` disables both.
* Test hook: client `BindableFunction` `PlayerScripts/IronframeCockpitControl` (toggle, look, recenter, eject, preset, skipBoot, stats) exists for Studio verification.

## Screenshots
01 forward view, 02 left console, 03 right console, 04a overhead, 04b lower dash/head down, 05a/05b/05c startup (displays booting, log, banner), 06a ejection warning, 06b pilot evacuated, 07a/07b ENERGY and MISSILE presets.
(02-04 were captured one iteration before the final compass back-plate/boot-log tweak; geometry is identical.)
