# M08D - HMG-20 Mauler heavy autocannon

Base: M08C `b0f02e9`. Branch: `feature/m08d-heavy-autocannon`. Local commit only; no push, no PR.

## Delivered

1. **Open Cloud audio pipeline** (`tools/roblox_audio_upload.py`): upload, register, validate and optional experience grant, key read from
   `ROBLOX_OPEN_CLOUD_API_KEY` without echoing it. Connectivity verified. The already-uploaded LR-12 asset `123083870222487` was registered
   (type Audio, state Active, moderation Approved, creator user `3611602826`), and `WeaponPresentation.audio.laserAssetId` now points at it.
2. **HMG-20 Mauler** as a separate logical weapon (`W_HMG_MAULER`), a fourth preset **AUTOCANNON**, and the full presentation stack.
3. **Original Mauler audio**: generated, scored, uploaded through the pipeline (asset `75916048000769`, Approved/Active) and wired in.

## HMG-20 statistics (configurable in `ComponentRegistry.W_HMG_MAULER.combat`)

| | HMG-20 | MG-9 (unchanged) | LR-12 (unchanged) |
|---|---:|---:|---:|
| Class | heavy ballistic, AUTO | ballistic, AUTO | laser, PULSE |
| Interval / rate | 1/3 s = **3.0 per s** (180 RPM) | 0.1 s | 0.25 s |
| Damage per hit | **25** (3.1x MG-9; x0.65 vs PLATE armor = 16.25) | 8 | 25 |
| Energy per shot | **2.5** (max 7.5 u/s) | 0.6 (6 u/s) | 24 (96 u/s) |
| Heat per shot | 0.9 (max 2.7/s) | 0.12 (1.2/s) | 6 (24/s) |
| Magazine / reload | **24 / 3.8 s** | 60 / 3 s | capacitor |
| Range | 500 studs | 350 | 450 |
| Mass / reactor draw | 5.0 t / 7 | 2.5 / 3 | 2.1 / 8 |
| Hardpoints | **arms only** (size 3) | arms, shoulders | arms, shoulders |

Everything is enforced by the existing server controller (`Weapons`, `WeaponState`, `Energy.Consume`): cadence, ammunition, payment
and ray resolution are unchanged code paths, with no second energy account. The one shared-rule addition is an **opt-in `phaseLock`**
(HMG-20 only, 0.05 s): a held trigger keeps its exact 1/3 s schedule instead of rounding each interval up to the next server frame. It
never creates a catch-up burst (a 5 s stall banks no shots) and MG-9/LR-12 do not set it, so their cadence is bit-identical.

AUTOCANNON preset: LR-12 left arm, **HMG-20 right arm**, MG-9 left shoulder, LR-12 right shoulder, ML-3 + MG-2 torso: 41.7 / 42.0 t,
30 / 80 power. All three original presets are untouched. A fourth garage button was added (panel enlarged 46 px).

### Tradeoffs (offline 60 Hz simulation, 20 s held trigger on the shared energy ledger)

| Situation | MG-9 shots / damage | HMG-20 shots / damage | LR-12 |
|---|---:|---:|---:|
| Stationary | 137 / 1096 | 48 / 1200 | |
| Sprinting | 22 / 176 | 7 / 175 | |
| Sprint + pulse shield | 15 / 120 | 5 / 125 | 1 shot |

Sustained damage is deliberately at parity with the MG-9 (a few percent either way). The Mauler's advantages are alpha strike per hit,
range (500) and efficiency of attention; its costs are 24 rounds (8 s of fire) then a 3.8 s exposed reload, 4.2x the energy per shot
(10.4 damage per energy against 13.3), twice the mass, arms-only mounting, and slow acquisition feedback at 3 Hz. It is far cheaper than
the laser (7.5 vs 96 u/s) so it remains usable while sprinting under shield, where the laser starves.

## Visuals

Procedural HMG-20 assembly (existing `WeaponModules` builder system; chassis, rig and mount interfaces untouched): armored receiver with
stepped top cover and inboard flank plate, heavy mounting yoke with braces, cylindrical recoil housing with four buffer rings, vented fixed
shroud, separate sliding heavy barrel, baffled muzzle brake, inboard ammunition drum with band and feed chute, and an outboard ejection-port frame
with dark recess, cycling bolt and a rigged `EjectionPort` Attachment (outward from either arm).

AI Asset Factory (`assets/specs/batch_004.json`, `manifests/batch_004.json`, `catalog/batch_004.md`): two `generate_mesh` attempts for a heavy
housing (assets `138102814864499`, `115137389737734`) were inspected in Play beside the Bastion and **both rejected** (human-style LMG with stock/grip;
then a pistol-like silhouette with detached box). Nothing from batch_004 is registered or used; the procedural assembly is the shipped look.
Honest limitation: the procedural cannon is blocky compared with the existing AI meshes; no further generation was attempted.

## Casings, recoil, effects

* **Casings**: `WeaponCasings` gained per-weapon profiles (`WeaponPresentation.casingProfiles`). The Mauler shell is 1.05 x 0.40 studs (MG-9: 0.48 x 0.18),
  ejected at 12.5 studs/s outward, lift 5.2, lateral spread 2.2, 1.3x tumble, restitution 0.38, up to 4 bounces, 3.0 s lifetime. Still the same
  client-integrated anchored-part simulation (no replicated or server brass, no collision/query/touch, raycast bounce against scenery only, mech/character/cockpit
  excluded), the same shared 28-shell cap plus a Mauler-only cap of 10, same cockpit-protection test with a larger margin (0.8). One shell per server-confirmed shot.
* **Recoil** (cosmetic, `MechRig.Apply`): 0.62 stud receiver kick in 22 ms, 0.27 s return to battery, 0.016 rad pitch, bolt travel 0.42, barrel/brake/emitter slide
  0.5 studs relative to the receiver, and a 0.0045 rad (0.26 degree) body pitch nudge. No camera shake was added; no authoritative state is touched.
* **Muzzle**: 0.7 x 0.7 x 1.9 flash with a 2.4 light (35 percent in cockpit view), expanding pressure-blast shell (one part, 90 ms), 5 smoke puffs (larger/longer),
  heavier tracer, larger port flash with a low receiver slam transient and a low casing-bounce transient.
* **Mechanical target hits** (`damage > 0` confirmed by the server): 14 larger/faster sparks, 1.5x contact flash, 5 dark armor-chip particles under gravity, effect
  life 0.6 s (non-damaging hits get 5 sparks). No component destruction, no pilot/character damage path.

## Audio

`assets/audio/mauler_discharge.wav` (0.62 s, original synthesis, 3 candidates, objective selection of candidate C) uploaded with the pipeline as asset
`75916048000769`. See `assets/audio/README.md` for the recipe, metrics and cockpit/exterior shaping. In Studio both registered assets load (`IsLoaded`),
report the expected durations (0.62 s / 0.32 s) and decode (peak PlaybackLoudness 381 for the HMG-20, 175 for the LR-12).

**Not verified:** human listening (no loopback), playback in any experience other than the owner's local test place (it is unpublished: universe id 0, so no experience
grant could be made or tested), and whether the previously uploaded LR-12 asset is byte-identical to `lr12_discharge.wav` (only its name/type/state were checked).

## Verification (2026-10-17)

Offline: `bash tools/check.sh` all green: locomotion/gait/deployment 28/28, energy/shield 27/27, weapons **19/19** (6 new), presentation **10/10** (3 new); every
`src` file compiles; the analyzer reports nothing outside the usual unknown-Roblox-global noise. `python tools/synthesize_mauler_audio.py --check` and
`python tools/synthesize_weapon_audio.py --check` pass. Rojo builds.

Studio (Play, Ironframe-M08D build):

* Startup SelfTest **25/25** (new: preset compiles, shoulder rejection, ported/barrel-tagged Mauler in procedural and imported-armor paths); four presets valid.
* Server integration (`tools/m08d_studio_checks.luau`): Mauler fires for 25 damage with exactly 2.5 energy and ammo 23; same-frame spam blocked; held fire for 3 s gave 8 shots
  (2.66/s under the throttled Studio server step; offline 60 Hz = 3.000/s); PLATE mitigation exactly 16.25; magazine empties, reload is 3.80 s and blocks fire, refills 24;
  MG-9 shoulder and LR-12 payment independent (24.0 energy for the laser); no fire while STOWED/DEPLOYING/DOCKING/EJECTED; avatar immunity.
* Regression: M07 collisions, M08A energy/shield, M08B authoritative firing/security all pass unchanged. MG-9 full magazine: 60 shots, 60 casings, peak 25, first shell 0.17 studs from port.
* Exterior full magazine, real production path against `RangeDrone2` (PLATE): **24 shots, 24 server hits, 390 damage (24 x 16.25), 24 heavy casings, peak 10 live shells**, shell 1.05 x 0.40,
  none collidable/queryable/touchable, first shell at the port, zero in the cockpit enclosure.
* Cockpit full magazine: 24 shots/24 casings, **0 shells inside the enclosure**, cockpit mix 1.0, light 0.83 peak, largest per-frame camera rotation **0.20 degrees**.
* Sprinting while firing: all 24 rounds fired, speed up to 16.9 st/s, capacitor down to 48/160, thermal 57.5, peak total demand 162 u/s; effects bounded.
* Pulse shield during fire: states CHARGING, ACTIVE, PERFECT_GUARD, RECOVERY, COOLDOWN observed while shots kept landing (shots 79 -> 97). The baseline reactor (80 u/s) sustains
  the stationary Mauler (7.5 u/s) and the shield together; capacitor depletion is demonstrated by the sprint run and the offline scenarios, not by this stationary run.
* Recall while firing: DOCKING at 0.2 s, shot counter frozen, STOWED within 6 s, zero casings/effects/voices. Ejection while firing: PILOT_EVACUATED in 0.12 s, shot counter frozen, pilot
  health 100, zero live transients, mech rebuilt SAFE/STOWED with 0 shots and 38 baseline instances.
* Budgets (`tools/m08d_budget_checks.luau`): 60 heavy emissions cap at 10 (recycled 50), shared cap 28 holds under mixed fire, distant emission culled, 50 Mauler voices use 8 (stole 42),
  swap and recall clear everything.

Performance (client, window focused, 60 FPS): exterior full magazine mean frame **16.67 ms**, worst 18.2 ms, effects update EMA **0.09 ms** (worst 0.28 ms), peak 100 instances in the effects
root (38 persistent baseline) and 38 after; cockpit mean 16.67 ms, worst 19.1 ms, EMA 0.10 ms (worst 0.32), voices peak 4 of 12. The MG-9 regression magazine measured EMA 0.19 ms, worst 0.93 ms.
Earlier runs with the Studio window unfocused rendered at ~15 FPS (66.7 ms) and showed the same bounded counts. Single client, no multiplayer or low-end benchmark.

## Known limitations

* Procedural weapon art (AI housing rejected twice). No visual screenshot of muzzle flash or the impact particles was captured: Studio's screenshot call lagged more than 0.6 s behind the
  effects (0.075 s flash), so effects were verified by instance inspection and counts, and a frozen-frame capture showed the flash origin only.
* No human audition of the generated audio; no second-account or other-experience playback test.
* AUTOCANNON preset is not part of the original three; the Mauler cannot be fit on shoulders/torso (size 3 vs 2/1) by design.
* Mauler energy is trivial on the stock reactor unless sprinting or shielding; heavier weapons or lower output would be needed to make it contest the capacitor on its own.
* Misc existing Studio noise (UIBlox warnings, asset `203785492` type warnings) is unchanged.

## Re-run

```
bash tools/check.sh
python tools/synthesize_mauler_audio.py --check
rojo build default.project.json -o build/Ironframe-M08D.rbxl
```
Studio (Play): SelfTest prints `[IF-TEST] 25/25`; Server `tools/m08d_studio_checks.luau`; Client (AUTOCANNON deployed, facing the range cone, select right arm)
`tools/m08d_client_checks.luau`, `tools/m08d_budget_checks.luau`, and `tools/verify_weapon_audio_studio.luau`.
