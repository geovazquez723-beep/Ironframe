# M08C — Weapon effects and audio polish

Base: M08B `d3f966f`. Branch: `feature/m08c-weapon-polish`. Local commit only; no push/PR.

**Status:** casing/mechanical/visual changes implemented and verified. Original LR-12 WAV and bounded playback integration prepared. Roblox audio upload, destination experience permission validation and human listening remain required. The audible-laser success criterion is not claimed complete.

## Presentation architecture

`WeaponClient` still submits the same firing intent and consumes the same server-confirmed `WeaponEffects` event. It delegates presentation to `WeaponEffects`, `WeaponCasings` and `WeaponAudio`. `WeaponPresentation` holds cosmetic budgets/tuning and the pending laser ID; `WeaponMotion` contains pure recoil/bounce math. `CockpitAudio.CockpitMix()` shares the existing atmosphere perspective state with weapon EQ. Existing cockpit layout, camera controls, hangar, armor, server weapon controller, energy ledger, damage, ammunition and cadence are unchanged.

Combat balance was explicitly regression-tested: LR-12 24 energy, 0.25-second interval, 25 damage, 6 additional heat per pulse, 450-stud range; MG-9 0.6 energy, 0.1-second interval, 8 damage, 0.12 additional heat per round, 350-stud range, 60 rounds and 3-second reload. Only old presentation `sound` fields were removed from ComponentRegistry; the approved bundled MG sources and new laser registration now live in presentation configuration.

## Brass and mechanical feedback

Each MG mount now has a dedicated rigged receiver-side carrier and `EjectionPort` Attachment, approximately 0.85 studs forward of the breech and 0.72 studs outward. Left/right hardpoints eject away from the cockpit. Both imported and procedural weapon paths retain the port and a small visible cycling bolt. Existing generated meshes remain in use.

One casing is requested for each server-confirmed ballistic shot within the distance budget. Rejected shots, depleted magazines and laser shots never emit brass. A case uses three cheap metallic cylinders: a 0.48 x 0.18 stud brass body, rolled rim and dark recessed-looking mouth. It inherits chassis velocity, receives an outward impulse of roughly 8.5–11.5 studs/sec, upward impulse 3.2 studs/sec and randomized angular spin.

Physics is **client-integrated gravity and scenery raycast bounce**, not an unanchored Roblox physics assembly. This is intentional: all casing parts remain anchored, noncolliding, untouchable and nonqueryable, so they cannot push chassis/avatars or block authoritative shots. Raycasts exclude all mechs, characters, the cockpit and the effects root. Impacts damp sliding/spin and restitution; cases settle after at most three bounces, fade over the last 0.45 seconds and disappear at 2.6 seconds. The fixed budget is 28 active cases within 140 studs; exceeding it recycles the oldest case. A torso-local protected enclosure check, expanded for casing dimensions, suppresses/removes brass that would enter the local cockpit in either view.

Mechanical presentation adds an 18 ms recoil attack, short damped recovery, 0.24-stud receiver recoil, 0.18-stud bolt cycling, subtle 0.006-radian pitch kick, smaller varied muzzle flashes, directional smoke, brief port flash, receiver transient and faint first-bounce casing transient. Cosmetic recoil starts from receipt of the authorized event, avoiding loss of the kick to replication latency. Changing selection cancels residual recoil on the new weapon.

## Laser visuals and audio

Laser visuals now use a thin near-white core, restrained cyan halo, 18 ms emitter flash rise, modest local light, brighter confirmed mechanical contact flash and short residual sparks. The beam stays instant-hit and follows the animated emitter; no laser projectile travel/damage behavior was introduced. MG tracers remain cosmetic.

`assets/audio/lr12_discharge.wav` is original deterministic synthesis: electronic/noise attack, falling FM discharge, restrained bass resonance and short decay. Mono 44.1 kHz, 16-bit PCM, 0.32 seconds, peak -3.01 dBFS and RMS -18.44 dBFS. SHA-256: `27ebc063788d330ec2acba1c7eae31f4a8644b622ef54ba09e462d3677412dc5`. Source is `tools/synthesize_weapon_audio.py`, seed 1209; no recorded or third-party samples. Source/WAV/manifest are preserved; rights are CC0-1.0.

**Asset IDs:** no new numeric audio ID exists. Manifest `asset_id` is null; `WeaponPresentation.audio.laserAssetId` is empty. User inventory contained no laser sound. Creator Store results were inspected, but no unrelated asset was inserted as a substitute. Tools expose search/insert of existing audio, not WAV upload. The former UI slider beep is removed; laser playback intentionally remains silent until the original asset is imported and registered.

MG audio sources remain the existing Roblox client files `rbxasset://sounds/impact_explosion_03.mp3` and `rbxasset://sounds/action_footsteps_plastic.mp3`, cropped/pitched for discharge, receiver and casing details. They have no new numeric asset IDs. Weapon audio preallocates eight discharge and four detail voices; excess demand steals an existing voice instead of allocating more Sounds. All four laser layers are premixed into one original clip. Per-shot pitch variation is ±2.5%. Exterior uses spatial attenuation over 12..220 studs; cockpit retains the low band, reduces mid by 2 dB/high by 14 dB, and uses 62% of exterior volume. Voices stop on swap/return/ejection and release owner references. The pool's 38 baseline instances intentionally persist between shots; transient parts/casings do not.

## Verification — 2026-10-17

- All existing offline suites pass: movement/gait/deployment/ejection **28/28**, energy/shield **27/27**, weapons **13/13**. New presentation contracts **7/7**. Total **75**.
- All source/test Luau files compile; filtered standalone analysis reports no actionable diagnostics in the new/changed presentation modules (Roblox globals/types omitted). Rojo build and whitespace checks pass. Python WAV validation checks PCM format, sample count, headroom, RMS/DC and clean endpoints without rewriting registration.
- Studio startup SelfTest **24/24**. Existing M07 collision/deployment, M08A energy/shield and M08B authoritative firing/raycast regression scripts pass.
- Procedural preset assembly check: BALANCED has one outward MG port, MISSILE has two correctly mirrored ports, ENERGY has none. Imported MG port/bolt placement and visible brass were inspected in an exterior close-up during actual Play.
- Actual cockpit full magazine: **60 shots -> 60 cases**, peak sampled **24**, zero cockpit-volume artifacts; casing center initially **0.469 studs** from the port at the first sampled frame. After reload/settling: zero active casings, shot groups or audio voices; magazine 60/READY. All inspected brass parts were noncolliding, untouchable and nonqueryable. Server inspection found **zero casing instances**.
- Actual exterior full magazine (`tools/m08c_studio_checks.luau`): **60 shots -> 60 cases**, peak sampled **25**, first case approximately **0.601 studs from port / 4.993 studs from muzzle**. Cases bounced, tumbled, faded and cleared. Repeat firing remained bounded; live lifetime peak observed **26 cases** after hundreds of authorized shots, with no accumulation.
- Dedicated client budget checks (`tools/m08c_budget_checks.luau`): 60 immediate cosmetic emissions capped at **28**, recycling **32**; distant emission culled; 50 audio requests used eight discharge voices, stealing 42; swap/recall cleared all transients. Temporary test owners/instances were destroyed. These are resource-bound unit checks, separate from the server-authorized full-magazine tests.
- Walking MG hit mechanical targets at approximately **11.1 studs/sec**. MG sprint firing also verified at **10.55 studs/sec**, capacitor **57.8** with **159.8 u/s** continuous demand; visual cases/voices remained bounded.
- Walking laser produced confirmed hits. **31 visible beam samples**, maximum emitter/beam-start error **0.0000159 studs**. No laser casings were spawned. The pending audio counter correctly recorded missing laser audio; no playback claim is made.
- Laser plus sprint/shield test: one authorized pulse in two seconds, capacitor zero, **158.1 u/s** demand, movement still **14.3 studs/sec**. Existing energy starvation and shield competition remained intact.
- Actual recall while firing: zero active casing/effect/audio transients during docking, then STOWED. Actual ejection while sprint-firing: shot count stayed **589** during the evacuation interval, zero active transient effects/audio after cancellation, pilot health **100**, rebuilt mech SAFE with zero shots. Final-source swap and resource-budget checks passed after the last cosmetic cleanup fixes.
- MG audio files loaded in both views and the pool reported cockpit mix 1/exterior mix 0, with at most **four active voices** in magazine tests. This verifies asset loading/mix state and bounds, not human audibility or tonal quality.

## Performance and limits

During the cockpit full-magazine test, effects update EMA was approximately **0.348 ms** near depletion; exterior **0.318 ms**. Observed worst update across the longer local session was **0.915 ms**. Idle examples ranged from approximately **0.008–0.075 ms**. A magazine end sample contained **144 instances**, including the persistent 38-instance audio/brass pool; cleanup returned to 38.

Studio's test viewport was rendering at about **15 FPS / 66.67 ms** in these runs (sample worst frame roughly 69 ms). This is a constrained local multi-Studio environment, not a controlled effects-only FPS comparison. The simulation bounds frame integration to 50 ms during hitches; casing travel therefore slows under severe frame throttling, while real-time lifetime/count limits still hold. No multiplayer or low-end benchmark was completed. Captures were narrow, so wider presentation QA remains useful.

**Still required:** manual upload/moderation, actual destination-experience audio permission check, and listening to the original laser and MG mechanical details on real output devices in cockpit/exterior modes. There is no loopback/listening capture tool in this session. Successful Play calls or decoded loudness alone cannot establish audio quality. See `assets/audio/README.md` for precise import/configuration steps and `tools/verify_weapon_audio_studio.luau` for post-import loading checks. Until then, the LR-12 audible success criterion remains pending.

Unrelated existing Studio CorePackages style warnings and asset-type warnings for `203785492` remain outside this milestone. No balance, profile, new-weapon, AI, hangar, armor or cockpit-layout work was added.

## Re-run

Run the four offline Luau suites listed above (also included in `tools/check.sh`) and `python tools/synthesize_weapon_audio.py --check`. Build with `rojo build default.project.json -o build/Ironframe-M08C.rbxl`. Run the M07/M08A/M08B Studio scripts on Server during Play. Deploy BALANCED, then run `tools/m08c_studio_checks.luau` on Client in each view for the full magazine test; `tools/m08c_budget_checks.luau` is the independent client resource-bound test. `IronframeWeaponControl:Invoke("effects")` reports live presentation counters and timing. Run the separate audio verification script only after completing the import guide.
