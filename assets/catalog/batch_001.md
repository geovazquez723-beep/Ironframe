# batch_001 catalog

Generated from the spec and manifest by `tools/assetfactory.py catalog`. Values are only those Studio reported.

Summary: ACCEPTED 6, NEEDS_REVIEW 1, REJECTED 1

| ID | Name | Status | Attempts | MeshParts | Bounding box (studs) | Persistence |
| --- | --- | --- | --- | --- | --- | --- |
| HNG_001 | CraneHookAssembly | NEEDS_REVIEW | 1 | 4 | 3.8x5.2x3.0 | CLOUD_VERIFIED |
| HNG_002 | HydraulicMaintenanceLift | ACCEPTED | 1 | 4 | 4.5x7.0x8.1 | CLOUD_VERIFIED |
| HNG_003 | RoboticServiceArm | ACCEPTED | 1 | 5 | 3.6x9.2x7.0 | CLOUD_VERIFIED |
| HNG_004 | DiagnosticConsole | ACCEPTED | 1 | 3 | 3.0x5.0x2.9 | CLOUD_VERIFIED |
| HNG_005 | CableReel | ACCEPTED | 3 | 2 | 2.7x2.8x3.0 | CLOUD_VERIFIED |
| HNG_006 | ToolCabinet | ACCEPTED | 1 | 3 | 4.2x2.9x2.5 | CLOUD_VERIFIED |
| HNG_007 | OverheadFloodlight | ACCEPTED | 1 | 3 | 2.7x3.6x3.0 | CLOUD_VERIFIED |
| MEC_001 | ShoulderArmorPrototype | REJECTED | 2 | 3 | 4.3x4.0x2.3 | CLOUD_VERIFIED |

## HNG_001 CraneHookAssembly - NEEDS_REVIEW
Intended use: Hangar ceiling rail prop above the maintenance plinth. Rig note: Static prop; origin should sit at the top of the rope so it can hang from an overhead rail
- Attempt 1: NEEDS_REVIEW; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_001_CraneHookAssembly`; error: none
  - Evaluation: Plausible trolley hoist block with sheave wheels, bolted olive housing and hook. Hook and rope are small relative to the 5x12x3 request (bbox 3.8x5.2x3), so it will not read as a 12-stud-tall hanging assembly; usable as a hoist block. Rig: origin is not at the rope top.
  - part `hook_geom` size [1.072, 3.056, 3] mesh `rbxassetid://120395663588569` texture `rbxassetid://74652614760030`
  - part `hook block housing_geom` size [3.78, 2.859, 2.403] mesh `rbxassetid://80502930547653` texture `rbxassetid://129006755050660`
  - part `sheave wheel_geom` size [2.134, 1.733, 1.668] mesh `rbxassetid://86821554206152` texture `rbxassetid://121580110737105`
  - part `wire rope_geom` size [1.192, 1.922, 0.277] mesh `rbxassetid://122460773895389` texture `rbxassetid://85052562326070`

## HNG_002 HydraulicMaintenanceLift - ACCEPTED
Intended use: Hangar floor prop beside a mech bay. Rig note: Static prop; scissor arms and platform may later animate vertically (separate parts required)
- Attempt 1: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_002_HydraulicMaintenanceLift`; error: none
  - Evaluation: Convincing wheeled scissor lift: crossed arms, grated platform with rail, cylinder, wheels, olive paint over grey frame. Visual accept. Footprint narrower than the requested 12x7x10 (4.5x7x8.1).
  - part `base frame_geom` size [4.48, 1.853, 7.045] mesh `rbxassetid://90046989722848` texture `rbxassetid://106999476213439`
  - part `scissor arms_geom` size [3.281, 4.001, 6.487] mesh `rbxassetid://73405972957166` texture `rbxassetid://131912873576880`
  - part `platform_geom` size [3.519, 1.469, 8.069] mesh `rbxassetid://72893589242665` texture `rbxassetid://122452852692628`
  - part `hydraulic cylinder_geom` size [2.382, 1.378, 0.692] mesh `rbxassetid://87038730797086` texture `rbxassetid://101881793627329`

## HNG_003 RoboticServiceArm - ACCEPTED
Intended use: Hangar prop that services mechs; candidate for simple idle animation. Rig note: Parts must be separate for joint rotation; pivots are NOT guaranteed at joints (review needed)
- Attempt 1: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_003_RoboticServiceArm`; error: none
  - Evaluation: Strong: bolted pedestal, jointed lower/upper arm with hydraulic lines, yellow collar, gripper tool head. Visual accept. Parts are separate but pivots are not at the joints and the wrist is a tiny fragment: re-pivot before any animation.
  - part `pedestal base_geom` size [3.6, 2.941, 3.775] mesh `rbxassetid://70510021649970` texture `rbxassetid://122858079195852`
  - part `lower arm_geom` size [2.848, 4.355, 2.161] mesh `rbxassetid://73623100599542` texture `rbxassetid://109523833552553`
  - part `upper arm_geom` size [1.767, 5.368, 6.655] mesh `rbxassetid://124524858322896` texture `rbxassetid://90406408406930`
  - part `wrist_geom` size [0.864, 0.504, 0.885] mesh `rbxassetid://137755148796390` texture `rbxassetid://108325259739432`
  - part `tool head_geom` size [1.879, 2.384, 1.895] mesh `rbxassetid://71226442091773` texture `rbxassetid://129648644128914`

## HNG_004 DiagnosticConsole - ACCEPTED
Intended use: Hangar terminal prop; screen part could later carry a SurfaceGui. Rig note: Static prop; screen face should be a flat quad (review)
- Attempt 1: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_004_DiagnosticConsole`; error: none
  - Evaluation: Rugged angled console with recessed screen bezel, button panel, vents, cable and base plate. Visual accept. Screen is a separate part (candidate for a SurfaceGui); no baked text.
  - part `console body_geom` size [2.989, 5.0, 2.95] mesh `rbxassetid://74911469386338` texture `rbxassetid://75661362415177`
  - part `screen_geom` size [2.07, 1.469, 0.441] mesh `rbxassetid://120993648998994` texture `rbxassetid://106719778525676`
  - part `keyboard tray_geom` size [2.748, 1.047, 1.389] mesh `rbxassetid://122781936620814` texture `rbxassetid://132901506471683`

## HNG_005 CableReel - ACCEPTED
Intended use: Hangar floor prop. Rig note: Static prop; drum may spin about its axle later
- Attempt 1: FAILED; model `-`; error: Async job failed: Failed to publish assets with error: Operation failed: Too Many Requests (rate limit while 3 jobs ran concurrently). An earlier synchronous call returned Request timed out, yet its generation still arrived in Workspace.
- Attempt 2: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_005_CableReel`; error: none
  - Evaluation: Good: olive flanges with ribs, wound black cable, welded tubular frame, crank hub. Visual accept.
  - part `reel drum_geom` size [3.488, 2.927, 3.0] mesh `rbxassetid://87789588886539` texture `rbxassetid://73475328719472`
  - part `support frame_geom` size [3.214, 1.731, 2.789] mesh `rbxassetid://135387540239600` texture `rbxassetid://89045083508347`
- Attempt 3: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_005_CableReel`; error: none
  - Evaluation: Good: olive flanges, wound black cable, light tubular frame, yellow crank accent. Visual accept; marginally smaller than requested.
  - part `reel drum_geom` size [1.524, 1.437, 2.49] mesh `rbxassetid://109511568078523` texture `rbxassetid://84721205816259`
  - part `support frame_geom` size [2.709, 2.837, 2.736] mesh `rbxassetid://90888081212133` texture `rbxassetid://128294579073657`

## HNG_006 ToolCabinet - ACCEPTED
Intended use: Hangar floor prop. Rig note: Static prop
- Attempt 1: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_006_ToolCabinet`; error: none
  - Evaluation: Reads as a drawer cabinet with doors, corner trim and casters, olive with yellow edge accents. Visual accept. Squat (4.2x2.9x2.5 vs requested 5x6x2.5); the wheels part is one tiny caster mesh, not four.
  - part `cabinet body_geom` size [4.157, 2.653, 2.393] mesh `rbxassetid://78231599137602` texture `rbxassetid://76701824516702`
  - part `doors_geom` size [3.731, 2.119, 0.233] mesh `rbxassetid://71462403806021` texture `rbxassetid://96684954471766`
  - part `wheels_geom` size [0.441, 0.425, 0.307] mesh `rbxassetid://116607017187417` texture `rbxassetid://129823341053436`

## HNG_007 OverheadFloodlight - ACCEPTED
Intended use: Hangar lighting fixture; a SpotLight can be attached to the lamp housing. Rig note: Static prop; lens face should point -Z or be re-oriented (review)
- Attempt 1: ACCEPTED; model `Workspace.IronframeGeneratedAssets.batch_001.HNG_007_OverheadFloodlight`; error: none
  - Evaluation: Caged lamp housing with lens, U-yoke and ceiling plate; clean and plausible. Visual accept. A SpotLight can attach to the lamp housing.
  - part `lamp housing_geom` size [2.283, 2.226, 2.811] mesh `rbxassetid://72811214679812` texture `rbxassetid://79306301217956`
  - part `mounting yoke_geom` size [2.32, 1.916, 2.939] mesh `rbxassetid://97062599894271` texture `rbxassetid://84924083234870`
  - part `ceiling bracket_geom` size [2.698, 3.557, 2.012] mesh `rbxassetid://116262872620960` texture `rbxassetid://75674412544970`

## MEC_001 ShoulderArmorPrototype - REJECTED
Intended use: Prototype to replace procedural PauldronShell*/PauldronCap* (see ASSET_PIPELINE.md). Rig note: Needs re-pivoting to the Torso-frame LocalCF and a left/right mirror before PartKit override; visual only for now
- Attempt 1: REJECTED; model `Workspace.IronframeGeneratedAssets.batch_001._rejected.MEC_001_attempt1_cuirass`; error: none
  - Evaluation: REJECTED: a human-style cuirass (breastplate with two shoulder pads and a neck opening) with organic scute texture, not a single mech pauldron.
  - part `shoulder shell_geom` size [4.644, 4.0, 3.23] mesh `rbxassetid://109515118597538` texture `rbxassetid://92704457250493`
  - part `mounting pylon_geom` size [2.393, 0.583, 2.462] mesh `rbxassetid://101488328651180` texture `rbxassetid://104007565319222`
  - part `armor lame plates_geom` size [4.51, 3.757, 3.041] mesh `rbxassetid://78963431886921` texture `rbxassetid://139332051372770`
- Attempt 2: REJECTED; model `Workspace.IronframeGeneratedAssets.batch_001.MEC_001_ShoulderArmorPrototype`; error: none
  - Evaluation: REJECTED after the single allowed regeneration: still a torso breastplate with two shoulder pads and a neck hole; the hanging armor plates part collapsed to a 50-triangle fragment. Both candidates preserved. Try single-part generation of one pauldron or generate_procedural_model.
  - part `shoulder shell_geom` size [4.26, 2.828, 2.347] mesh `rbxassetid://119117450380096` texture `rbxassetid://128424945448946`
  - part `mounting pylon_geom` size [2.804, 3.309, 1.574] mesh `rbxassetid://104049572954798` texture `rbxassetid://129971428005226`
  - part `hanging armor plates_geom` size [0.327, 0.269, 0.159] mesh `rbxassetid://119368033357666` texture `rbxassetid://134119353415940`

