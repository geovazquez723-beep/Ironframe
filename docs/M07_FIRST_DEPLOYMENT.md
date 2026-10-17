# M07 — First Deployment

## Recovery

Continued `feature/m07-first-deployment` from M06A `f99d168` without resetting, stashing, cleaning, or changing branches. The interrupted work contained five modified source files and seven new files: chassis drive/gait tuning, expanded leg limits, pure MechDrive/MechGait modules, 24 offline tests, Deployment/Locomotion/BayControl, a proving ground, and partial server integration. No staged changes were present. Checkpoint `f5cb532` preserves that exact useful source work before revisions.

The missing client half was implemented using the existing M06A systems: ShowroomAnimator now poses the same rig around the replicated hull, GarageCamera follows its position, CockpitMode follows its animated torso, and CockpitHud reads live movement channels. BayClient animates tagged doors and crane parts; DeploymentClient supplies controls and status in both camera modes.

## Playing

- V enters the existing cockpit. F also enters it from the garage; press F again to deploy.
- F in the cockpit initializes the reactor and opens the doors. Movement unlocks after the door startup interval.
- W/S drives forward/reverse; A/D steers the chassis. Release the keys to brake deliberately to zero.
- The showroom mech initially faces −Z. The real hangar exit is behind it at +Z: turn toward heading 180, then walk out.
- V switches between cockpit and the exterior orbit/follow view during movement; R recenters the active view. Mouse/arrows retain their existing view controls.
- F while active returns to the hangar: indoor autopilot docks onto the pad; outdoor return recalls the mech after a short delay. Walking back through the open doors before docking also works.
- X ejects in either view. Garage and cockpit buttons also use the same authoritative ejection remote.
- Loadout edits are available only while STOWED. Existing cockpit Q/E preset controls are preserved and server rejection applies while deployed.

## Architecture and safety

MechDrive advances plain numeric state on the server with fixed substeps, jerk-limited acceleration, deliberate braking, turn inertia, a 16 stud/sec forward cap, a 7 stud/sec reverse cap, and approximately 35 degrees/sec stationary turning. Inputs are sanitized, rate-limited, restricted to ACTIVE, and neutralized after a 0.75 second timeout. Normal client controls release on focus loss and suppress input while typing.

Locomotion owns one anchored, invisible query hull. Ground rays, turn-overlap queries and swept blockcasts resolve movement; cosmetic parts remain anchored. Casts include a safety skin even during tiny acceleration steps, preventing precision misses and obstacle creep. Ground support uses the highest sampled support so a wide chassis bridges narrow service trenches. A missing terrain sample prevents walking into a void. Hull movement is replicated; local visual posing never drives server position.

The existing 14-joint rig, six sockets, ten hydraulic links, three presets, generated meshes and cloud references remain intact. MechGait uses alternating stance/swing legs and sagittal two-bone IK, with hip/knee/ankle articulation, touchdown sounds/dip, arm movement and torso counterbalance. Animation follows measured chassis displacement and rotation, including collision stops. Existing MechRig poses the hydraulics from their endpoints. Cockpit head-look remains independent of chassis steering. Telemetry publishes speed, heading, direction, drive state, deployment and reactor state; combat feeds remain STANDBY/DEMO.

Deployment follows STOWED → DEPLOYING → ACTIVE → DOCKING → STOWED, with evacuation to EJECTED and recovery to STOWED. Ejection establishes pilot safety before callbacks. Callback failures cannot cancel disable/cleanup/rebuild scheduling. The server movement loop stops advancing an evacuated machine immediately, regardless of a visual hook failure. The abandoned controller/model is removed and recovery assembles one stationary mech.

## Environment

The +Z doors slide 22 studs outward and the crane hook retracts 17 studs locally. Server door query state is authoritative. Attribute-arrival listeners handle machinery metadata that replicates after the parts. Daylight makes the outdoor course readable while retaining the hangar structure and local lighting.

The bounded field has a central roadway, distance markers, container stacks, tanks, a clearance arch, staggered barriers, a curb and shallow ramps/hills. No new AI assets were generated.

## Verification performed

- Standalone Luau: **28/28 passed** (24 recovered drive/gait checks plus deployment validation/transitions and ejection fault/stale-session coverage).
- Luau compiler: **41 files compiled, zero syntax failures**, including both test scripts.
- Stock Luau analyzer: no non-platform diagnostics after excluding unknown Roblox globals/types. This is not a Roblox-aware strict typecheck.
- Rojo: built `build/Ironframe-M07.rbxl` successfully from `default.project.json`.
- Actual Studio `Ironframe.rbxl`: existing regression harness **22/22 passed**, with 21/21 existing cloud assets loaded; 14 joints, six filled sockets, ten hydraulics and 22 mech meshes reported.
- Actual keyboard W/S/D plus shared input-path tests verified forward/reverse, both steering directions, deliberate braking to zero, stationary idle and mechanical footsteps.
- Measured forward 15.95–16 and reverse −6.95 studs/sec. Walked through the doors into the proving ground beyond z=100; observed the daylight field and animated rig in the exterior view.
- Both camera transitions at 16 studs/sec, head-look/recenter, and cockpit tracking succeeded.
- Outdoor recall returned STOWED with no hull; indoor return from approximately 28 studs off-pad engaged AUTOPILOT and docked.
- Duplicate deploy and deployed loadout changes were rejected. Stale/nonfinite input was neutralized.
- Ejected while moving (approximately 12 studs/sec): pilot immediately safe/PILOT_EVACUATED/EJECTED; recovery restored one mech, zero speed, no abandoned hull, and the cockpit view. Repeated deployments and recoveries succeeded.
- Final synchronized server ran `tools/m07_studio_checks.luau`: 12 simulated seconds of sustained throttle stopped at a thin marker (x≈−16.15) and a container face (x≈−24.45), both with zero speed. Hill traversal reached y≈3.49 and stopped at the far barrier (z≈311). Input timeout/nonfinite cases also passed.

The Studio collision tests caught and drove correction of a real tiny-sweep tunneling defect before completion. The repeatable test chunk creates temporary controllers, uses the actual world query engine and cleans them up. Run it on the server during Play after Bay_1 is built. Run offline tests with `luau tools/offline_tests.luau`; `tools/check.sh` now includes them.

## Limits

The compact hull approximates the body; weapon/armor extremities are cosmetic and may clip close obstacles. Gait has grounded stance timing but does not independently raycast each foot on uneven terrain. Exterior view retains the existing orbit angle while following position. Outdoor return uses recall rather than pathfinding through obstacles. Keyboard controls are the supported drive interface; touch/gamepad driving and multiplayer latency were not validated. Existing Studio CorePackages warnings and a legacy asset-type warning were observed; cloud references were preserved.

The Git source and ignored Rojo build are the persistent deliverables. Studio edit sources were synchronized for testing; no publish, push or PR was performed.
