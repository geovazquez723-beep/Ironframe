# M09 — Tactical Energy Allocation Profiles

Branch `feature/m09-energy-profiles` (from M08D `0d0543d`). Three selectable profiles — **MOBILITY, BALANCED, WEAPONS** —
change *who gets energy first and what each discretionary system must leave in the capacitor*. They never add energy,
change damage/cadence/costs, or touch the installed reactor (80 u/s), capacitor (160) or cooling.

## Profile definitions (data: `EnergyProfiles.luau`)

| | priority (lower = first) | capacitor reserve (fraction of 160) |
|---|---|---|
| MOBILITY | sprint 3, shield 4, weapons 5 | sprint 0, weapons 0.40, shield 0 |
| BALANCED (default) | shield 3, sprint = weapons 4 (shared) | sprint 0.30, weapons 0.20, shield 0 |
| WEAPONS | shield 3, weapons 4, sprint 5 | sprint 0.55, weapons 0, shield 0 |

Mandatory baseline (reactor idle + basic propulsion) is hard-coded outside any profile (`Energy.Mandatory`): always served
first, no reserve, and the 0.65 limp-mode locomotion floor is unchanged.

**Reserve semantics.** A discretionary key whose reserve is not met (charge below `reserve × capacity`) is *gated off*:
continuous requests (sprint, shield sustain, weapon sim) take neither capacitor nor reactor output that substep, so the
output refills the capacitor for the subsystem the profile protects; discrete payments (weapons) are refused with state
`RESERVED` (vs `ENERGY LOW` when the capacitor is truly empty). Shield activation/sustain/impact costs have reserve 0 in all
profiles, so shield timing, cooldown, facing, perfect-guard window and cost are profile-independent.

## Arbitration changes (minimal, one ledger)

- `Energy.lua`: `SetPolicy`, `Reserve`, `Available`; `Request` takes its priority from the policy; `Consume/Spend` accept a
  paying-subsystem key (reserve honoured, tallied in `spent`); `Advance` groups equal-priority requests and splits supply in
  proportion to demand (no callback-order bias); gating evaluated from the start-of-substep charge. Ledger accounting is
  unchanged (`initial + generated = charge + consumed + loss + wasted`, verified in every test). No policy ⇒ exact M08 behaviour.
- Same-tick order: reserves depend on charge, not call order. Production order is fixed (locomotion substeps → weapons), and
  outcomes are identical in either order except within one payment of a threshold.
- `EnergySystems.luau`: owns a `profile` state (switch state machine), applies the active policy each step, publishes
  profile/pending/ETA/serial/reason/focus/limited/weapon-rate/shield/sprint demand attributes. `Weapons.luau` pays with key
  `"weapons"` and reports `RESERVED`.
- Switching (`RequestEnergyProfile` remote): server validates id (string ≤32, selectable, not a planned/locked name), requires
  ACTIVE deployment and OPERATIONAL machine, 0.5 s transition (old policy stays active until it completes), 2.0 s minimum
  interval between accepted requests, no queued switches. Thermal state, charge and shield timers are untouched. Ejection
  (`Systems.Cancel`) drops a pending switch; each deployment starts at BALANCED (`ResetProfile`); drive input and ejection never
  go through this path.

## Controls and cockpit

- **C** cycles MOBILITY → BALANCED → WEAPONS (audited: C was unused). A clickable **POWER PROFILE** strip (three buttons) sits under
  the shield/test buttons while piloting; ALT frees the cursor in cockpit view.
- Reactor MFD is now POWER DISTRIBUTION: profile segments (active = amber with a one-shot acknowledgement flash, pending = pulsing cyan
  with a progress bar and ETA), reactor demand/output, capacitor with CHARGING/DISCHARGING + flow, propulsion (with sprint),
  weapon and shield demand bars tagged `PRIORITY` / `LIMITED`, thermal, and a warning line naming the throttled subsystem.
  The forward view only gains a `PWR MOB/BAL/WPN` suffix on the existing weapon line. Screenshot: `docs/m09/`.

## Scenario comparison (identical hardware, full capacitor, constant demand)

Offline harness, `tools/profile_tests.luau` (60 Hz, mirrors server order): moving at max speed holding SHIFT, 12 s, LR-12 only:

| | sprint delivered | lasers fired | mean speed factor |
|---|---|---|---|
| MOBILITY | 0.324 | 2 | 1.194 |
| BALANCED | 0.321 | 3 | 1.193 |
| WEAPONS | 0.033 | 12 | 1.020 |

Sprint + LR-12 + Mauler + MG-9, 10–12 s: Mauler shots MOB 4 / BAL 30 / WPN 30 (cadence cap 3/s), MG-9 shots 12 / 98 / 98.
Four-second burst (laser only) sprint: MOB 0.55, BAL 0.40, WPN 0.10; lasers 2 / 3 / 8.

Studio Play (production Locomotion + EnergySystems + Weapons, AUTOCANNON loadout, 5 s sprint while cycling LR-12/Mauler/MG-9):

| | sprint delivered | shots | final charge | thermal |
|---|---|---|---|---|
| MOBILITY | 0.694 | 11 | 0.0 | 50.0 |
| BALANCED | 0.454 | 58 | 48.0 | 45.7 |
| WEAPONS | 0.088 | 64 | 7.2 | 65.3 |

Ledger error ≤ 1e-5 in all three. Low demand (MG-9 only, 3 s): 28 shots, charge 160.0 in all three profiles.

## Studio verification (Ironframe-M09.rbxl, real Play session)

- Deploy → `C` cycle: BALANCED → WEAPONS acknowledged on the MFD; `ACTIVE`, sprint `LIMITED SPRINT 34`, capacitor holding at 88/160
  (the 55 % sprint reserve), `DEFICIT … SPRINT THROTTLED`.
- Server switching: invalid id rejected; `OVERDRIVE` → `PROFILE LOCKED`; MOBILITY requested → pending, applied ~0.5 s later;
  immediate second request → `SWITCH COOLDOWN`; duplicate in-flight → `SWITCH IN PROGRESS`.
- Eject during a pending switch: mech rebuilt, profile BALANCED, no pending; redeploy and return-to-hangar both clean.
- M08A server checks and the M08D Mauler checks (damage 25, cadence 2.65/s, 3.8 s reload, plate ×0.65, MG-9/LR-12 payments) pass.
  M08A assertions that assumed "sprint drains the capacitor to ~0" or "sprint starves shield sustain" were pinned to the profile
  that preserves that behaviour (MOBILITY/WEAPONS), and a BALANCED reserve assertion was added.

## Offline results

`tools/check.sh`: syntax OK; no new analyzer findings (pre-existing Roblox-type noise only); offline 28, energy 27,
**profile 19**, weapon 19, presentation 10 — all passing. Rojo build OK.

## Known limitations / tuning

- Gating makes sprint-vs-laser bistable around `sprintReserve ≈ weaponsReserve + laserCost/capacity` (0.30 vs 0.20+0.15 here):
  BALANCED currently favours sprint + small arms while sprinting and gives up lasers; raise its weapon reserve gap to change that.
- MOBILITY effectively locks weapons out of sustained sprint (reserve 0.40 can never be refilled while sprint takes all surplus);
  intended, but 0.25–0.30 would soften it.
- Because gated sprint no longer drains the capacitor, BALANCED/WEAPONS bank reactor surplus faster than M08 (e.g. empty-capacitor
  shield activation recovers sooner while sprint is held).
- The shield test pattern, weapon-load sim and thermal model are unchanged. Planned profiles (BULWARK, OVERDRIVE, SIEGE, PHANTOM,
  COUNTERSTRIKE, EMERGENCY RESERVE) exist only as non-selectable `Planned` stubs with a `requires` note; adding one = a
  `Definitions` entry + `Order` id.
- Switch cooldown/transition values live in `EnergyProfiles.Transition/MinInterval` and are not yet per-hardware.
