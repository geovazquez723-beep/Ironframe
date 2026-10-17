# batch_003 catalog

Generated from the spec and manifest by `tools/assetfactory.py catalog`. Values are only those Studio reported.

Summary: ACCEPTED 4

| ID | Name | Status | Attempts | MeshParts | Bounding box (studs) | Persistence |
| --- | --- | --- | --- | --- | --- | --- |
| CPT_001 | CockpitDashboardShell | ACCEPTED | 1 | 2 | 2.3x1.0x1.8 | CLOUD_VERIFIED |
| CPT_002 | ControlConsoleHousing | ACCEPTED | 1 | 2 | 1.3x1.3x0.8 | CLOUD_VERIFIED |
| CPT_003 | PilotControlStick | ACCEPTED | 1 | 2 | 0.5x1.2x0.8 | CLOUD_VERIFIED |
| CPT_004 | OverheadEquipmentPanel | ACCEPTED | 1 | 2 | 1.4x0.8x1.6 | CLOUD_VERIFIED |

## CPT_001 CockpitDashboardShell - ACCEPTED
Intended use: Client-only decorative cowl over the MFD bank. Rig note: Torso frame; X-symmetric; sloped face toward the pilot (+Z)
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Domed armored hood with raised centre hump, side wings and a vent grille; reads as a dash cowl. Came out 2.3 wide, not the requested 5.0, so it is stretched ~1.6x in X at placement. Model front (vent) faces -Z.
  - part `dash shell_geom` size [2.312, 0.97, 1.8] mesh `rbxassetid://70812473780074` texture `rbxassetid://73261621050797`
  - part `vents_geom` size [0.776, 0.231, 0.093] mesh `rbxassetid://99255384545236` texture `rbxassetid://84926306939856`

## CPT_002 ControlConsoleHousing - ACCEPTED
Intended use: Client-only left and right console bodies (same mesh both sides). Rig note: Torso frame; long axis along Z; sloped top
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Compact cabinet with a small display, switch banks, dials and side conduits. Shorter in Z than requested (0.76 vs 2.6). Used as a cabinet under each wing-console screen, same mesh both sides.
  - part `console shell_geom` size [1.288, 1.3, 0.758] mesh `rbxassetid://139464849938664` texture `rbxassetid://114512627858437`
  - part `switch bays_geom` size [0.395, 0.099, 0.223] mesh `rbxassetid://93697138468331` texture `rbxassetid://135288418638002`

## CPT_003 PilotControlStick - ACCEPTED
Intended use: Client-only hand controls. Rig note: Vertical (+Y) shaft, grip faces -Z
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Bell-shaped grip with a swept lever above a ribbed boot; reads as a flight/control stick. Proportions differ from the prompt (short, wide grip).
  - part `grip_geom` size [0.418, 0.664, 0.8] mesh `rbxassetid://71783854527063` texture `rbxassetid://98473243740000`
  - part `boot_geom` size [0.515, 0.865, 0.766] mesh `rbxassetid://124061609623063` texture `rbxassetid://110335654152792`

## CPT_004 OverheadEquipmentPanel - ACCEPTED
Intended use: Client-only overhead diagnostic panel. Rig note: Flat top mounts to roof; sloped face toward pilot (+Z)
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Shallow panel with rows of round switch bays, a small display and side conduit rolls; clean overhead equipment look. Narrower than requested (1.4 vs 3.4): two units are placed side by side. Front faces -Z.
  - part `panel shell_geom` size [1.41, 0.754, 1.595] mesh `rbxassetid://108316685733755` texture `rbxassetid://138073161996028`
  - part `conduits_geom` size [1.404, 0.154, 1.45] mesh `rbxassetid://77997539832322` texture `rbxassetid://101761323377649`

