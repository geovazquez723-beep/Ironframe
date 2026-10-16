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
