# Studio verification checklist (M02)

Run `rojo serve`, connect the plugin, press **Play** (single player). Wait ~5 s for lighting to settle.

Automated (Output window)
- [ ] `[IF-TEST] 13/13 passed` and no `[IF-TEST] FAIL` lines. Panel shows `SELF-TEST 13 / 13 PASS`.
- [ ] `[IF-STEP-01]`..`[IF-STEP-05]` logs present, no red errors.
- [ ] Re-run any time from the command bar (server context):
      `require(game.ServerScriptService.IronframeServer.SelfTest).Run()`

Camera / avatar (manual, needs a real mouse)
- [ ] Opens on the mech's front three-quarter view, mech right of the stats panel.
- [ ] Hold RMB and drag: smooth 360-degree orbit, tilt clamped (no flip). Release: no stuck state.
- [ ] Wheel zooms smoothly between ~12 and ~72 studs; whole mech inspectable, incl. back and feet.
- [ ] MMB-drag moves focus height; `R` resets; arrow keys orbit/tilt; `-`/`=` zoom.
- [ ] Your Roblox avatar is invisible, cannot walk, and keeps full health (Explorer: Character still exists).

Mech
- [ ] Idle showroom animation: torso turns, head scans, gentle hydraulic settle, hydraulics stretch/compress.
- [ ] Weapons stay attached to shoulders/flanks/forearms as the torso turns.
- [ ] GENERAL / PLASMA / MISSILE are visibly different (palette, weapons, extra armor/spires/ammo bins).
- [ ] Panel diagnostics: `SOCKETS 6 / 6`, armor panels > 60, `PILOT SAFE / UNTARGETABLE`.

Safe ejection
- [ ] TEST SAFE EJECTION: status turns to PILOT_EVACUATED and the capsule appears first; ~1 s later the mech
      disappears; ~4 s later it rebuilds. Camera stays usable throughout. No pilot damage/death text.

M03 visual views (keys, with the garage focused)
- [ ] `1` front three-quarter, `2` side profile, `3` rear reactor/exhaust, `4` chest/cockpit/shoulder detail, `5` leg/hydraulics.
- [ ] Armor reads as painted plates with dark gaps over the frame; joint rings are dark metal, not white discs.
- [ ] No overexposure (white armor) or crushed blacks in any preset; glow limited to visor, canopy, reactor, coils, warheads.
- [ ] Animation: client-local attribute `ShowroomTorsoYaw` on the mech model changes over time (Explorer, Play client view).

M04B hangar checks
- [ ] Output: `[IF-ASSET] Loaded 6/6 AI assets from cloud ids`, `SELF-TEST 15 / 15 PASS`, no `[IF-HANGAR]` warnings.
- [ ] Views `6` overview, `7` east maintenance area, `8` crane/overhead, `2` west area: no camera clipping into walls,
      columns or ceiling; zoom out + orbit stays inside the hangar.
- [ ] Bastion remains the brightest, best-separated object at the default view; no overexposed armor.
- [ ] Six AI asset types visible (lifts, service arms, consoles, cable reels, cabinets, floodlights); the 8 hanging
      floodlights match the warm key/cool fill on the Bastion.
- [ ] Presets, safe ejection and rebuild still work; avatar hidden; stats panel and diagnostics unchanged.

M10A destructible proving grounds (see docs/M10A_DESTRUCTIBLE_PROVING_GROUND.md)
- [ ] `bash tools/check.sh` passes (includes `tools/destruction_tests.luau`); `python tools/synthesize_destruction_audio.py --check` is all `ok`.
- [ ] Edit mode: run `tools/m10a_studio_checks.luau` through execute_luau (optionally `AssetLibrary.Load()` first): `"failures":[]`.
- [ ] Play: output shows `[IF-ASSET] Loaded 22/22`; deploy, drive the road to the gate (HDG 180); the left panel `RANGE CONTROL` appears inside the district.
- [ ] Fire LR-12 (1), HMG-20 (2), MG-9 (3) at barricades / panels / tanks: DAMAGE INFLICTED splits by weapon; Mauler crumbles concrete, MG-9 shreds panels and the engine deck.
- [ ] A Warehouse A wall breach shows a notice and a real opening; destroying a shed column drops its beam and roof panels.
- [ ] Track kill stops T-03; turret kill disables the turret; hull kill = VEHICLE DESTROYED; training mech: armor, arm, legs, chassis = TARGET DISABLED.
- [ ] `B` / RESET ENTIRE DISTRICT restores everything; repeat 3x: `IronframeRangeAudit` `audit` shows identical `instances` and `totalIndexed`.
- [ ] Return to hangar, redeploy, eject inside the district: pilot safe, capsule untargetable, mech rebuilt; garage, cockpit, loadouts unchanged.

