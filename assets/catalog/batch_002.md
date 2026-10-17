# batch_002 catalog

Generated from the spec and manifest by `tools/assetfactory.py catalog`. Values are only those Studio reported.

Summary: ACCEPTED 11, REJECTED 1

| ID | Name | Status | Attempts | MeshParts | Bounding box (studs) | Persistence |
| --- | --- | --- | --- | --- | --- | --- |
| MEC_010 | ChestArmorAssembly | ACCEPTED | 3 | 1 | 5.6x5.5x2.5 | CLOUD_VERIFIED |
| MEC_011 | HeavyPauldron | ACCEPTED | 3 | 1 | 4.4x3.0x3.2 | CLOUD_VERIFIED |
| MEC_012 | ArmoredShinAssembly | ACCEPTED | 4 | 1 | 2.3x4.0x1.6 | CLOUD_VERIFIED |
| MEC_013 | HeavyFootArmor | ACCEPTED | 2 | 1 | 2.0x2.0x3.9 | CLOUD_VERIFIED |
| MEC_014 | CockpitHousing | ACCEPTED | 2 | 1 | 2.2x2.2x1.4 | CLOUD_VERIFIED |
| MEC_015 | UpperLegArmor | ACCEPTED | 1 | 1 | 2.1x3.6x1.8 | CLOUD_VERIFIED |
| MEC_016 | UpperArmArmor | REJECTED | 2 | 1 | 1.1x1.1x3.0 | - |
| MEC_017 | ForearmGauntlet | ACCEPTED | 1 | 1 | 1.7x3.8x1.8 | CLOUD_VERIFIED |
| WPN_010 | AutocannonVisual | ACCEPTED | 1 | 1 | 0.9x1.8x2.0 | CLOUD_VERIFIED |
| WPN_011 | LaserRifleVisual | ACCEPTED | 1 | 1 | 0.7x1.6x3.4 | CLOUD_VERIFIED |
| WPN_012 | PlasmaCannonVisual | ACCEPTED | 1 | 1 | 2.4x2.2x4.1 | CLOUD_VERIFIED |
| WPN_013 | MissilePodVisual | ACCEPTED | 1 | 1 | 2.0x2.2x1.5 | CLOUD_VERIFIED |

## MEC_010 ChestArmorAssembly - ACCEPTED
Intended use: Replaces procedural chest plates/wings/intakes on the Torso joint. Rig note: Torso frame; left-right symmetric; front toward -Z
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: Reads as a wearable vest with shoulder caps (the known wearable-armor failure); second explicit part is a 0.4-stud fragment.
  - part `armor shell_geom` size [6.78, 5.5, 5.342] mesh `rbxassetid://126062462870542` texture `rbxassetid://105471918279878`
  - part `intake grilles_geom` size [0.375, 0.207, 0.366] mesh `rbxassetid://90581935080096` texture `rbxassetid://77931110036167`
- Attempt 2: REJECTED; model `-`; error: none
  - Evaluation: Generator produced a literal tracked tank; unusable.
  - part `body_geom` size [3.851, 3.014, 5.5] mesh `rbxassetid://127913948473231` texture `rbxassetid://83781759359012`
- Attempt 3: ACCEPTED; model `-`; error: none
  - Evaluation: Angular mecha chest shell with amber vent windows, broad flared shoulder-top plates and a keel. Shallow (2.5 deep): used as the front armor shell over the procedural chest frame.
  - part `body_geom` size [5.582, 5.5, 2.457] mesh `rbxassetid://110784935757568` texture `rbxassetid://108815130901462`

## MEC_011 HeavyPauldron - ACCEPTED
Intended use: Replaces procedural PauldronShell/Cap/Front/Rear/Lames; same mesh used both sides. Rig note: Symmetric in X and Z so one mesh serves left and right
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: Barrel/grenade shape, undersized, degenerate second part.
  - part `pauldron shell_geom` size [2.58, 3.0, 2.41] mesh `rbxassetid://88014658664805` texture `rbxassetid://78261140155326`
  - part `lames_geom` size [0.081, 0.083, 0.066] mesh `rbxassetid://74496089387750` texture `rbxassetid://135676625337930`
- Attempt 2: REJECTED; model `-`; error: none
  - Evaluation: Plain smooth shield, no mechanical detail, thin.
  - part `body_geom` size [2.667, 3.0, 1.628] mesh `rbxassetid://121609396132460` texture `rbxassetid://109607504781718`
- Attempt 3: ACCEPTED; model `-`; error: none
  - Evaluation: Layered pauldron with yellow stencil bands, side rails and bolt clusters; near X-symmetric so one mesh serves both sides.
  - part `body_geom` size [4.364, 3.0, 3.176] mesh `rbxassetid://100019703856295` texture `rbxassetid://107739462157781`

## MEC_012 ArmoredShinAssembly - ACCEPTED
Intended use: Replaces procedural ShinFront/ShinSide/CalfPod on the Knee joint. Rig note: Hangs along -Y from Knee; X-symmetric; shared by both legs
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: Produced a pair of legs/trousers; not a single shin.
  - part `shin guard_geom` size [3.291, 4.133, 1.896] mesh `rbxassetid://128378082349799` texture `rbxassetid://128700846175216`
  - part `calf housing_geom` size [0.087, 0.174, 0.358] mesh `rbxassetid://92392014053631` texture `rbxassetid://118354885136532`
- Attempt 2: FAILED; model `-`; error: Failed to fetch image for model generation
  - Evaluation: Studio reported: Failed to fetch image for model generation (transient).
- Attempt 3: REJECTED; model `-`; error: none
  - Evaluation: Produced a miniature robot torso with arms, not a shin.
  - part `body_geom` size [3.2, 2.984, 1.877] mesh `rbxassetid://79362132215867` texture `rbxassetid://104665243409227`
- Attempt 4: ACCEPTED; model `-`; error: none
  - Evaluation: Single tapered greave plate with spine and lip. Smooth but clean; pairs with the procedural ShinFrame/CalfPod.
  - part `body_geom` size [2.288, 3.998, 1.6] mesh `rbxassetid://121031808969189` texture `rbxassetid://87046921017269`

## MEC_013 HeavyFootArmor - ACCEPTED
Intended use: Replaces procedural FootBase/FootArmor/ToePlate/HeelBlock on the Ankle joint. Rig note: Ankle frame; X-symmetric; toe toward -Z
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: A human-style boot at 1 stud wide; unusable.
  - part `foot shell_geom` size [1.079, 2.2, 2.1] mesh `rbxassetid://109143219245621` texture `rbxassetid://86199549469592`
  - part `ankle collar_geom` size [0.852, 0.311, 0.371] mesh `rbxassetid://113709052252326` texture `rbxassetid://120215645900405`
- Attempt 2: ACCEPTED; model `-`; error: none
  - Evaluation: Wedge foot with ankle socket ring, toe and heel guards; reads as a machine foot, not a boot. Will be scaled uniformly.
  - part `body_geom` size [2.005, 2.0, 3.94] mesh `rbxassetid://121358370930125` texture `rbxassetid://119355289184467`

## MEC_014 CockpitHousing - ACCEPTED
Intended use: Replaces procedural cockpit pillars, hood, sill, wings in the chest front. Rig note: Torso frame; X-symmetric; opening faces -Z
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: Came out as a mecha head/helmet with a visor, not a cockpit housing.
  - part `body_geom` size [2.606, 2.468, 2.4] mesh `rbxassetid://86962750973123` texture `rbxassetid://94053250840515`
- Attempt 2: ACCEPTED; model `-`; error: none
  - Evaluation: Symmetric beveled window bezel with brow block and sill; hollow opening for a glass pane. Works as a cockpit surround.
  - part `body_geom` size [2.205, 2.2, 1.402] mesh `rbxassetid://126058201438423` texture `rbxassetid://73905931617259`

## MEC_015 UpperLegArmor - ACCEPTED
Intended use: Replaces procedural ThighFront/ThighSide/ThighInner on the Thigh joint. Rig note: Hangs along -Y from Thigh; X-symmetric; shared by both legs
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Heavy thigh shell with layered side pod and top vents.
  - part `body_geom` size [2.067, 3.553, 1.8] mesh `rbxassetid://82559873474887` texture `rbxassetid://117890116412055`

## MEC_016 UpperArmArmor - REJECTED
Intended use: Added in M05 after wave-1 review: upper-arm armor over the procedural UpperArmFrame (Shoulder joint). Rig note: Hangs along -Y from Shoulder; X-symmetric; shared by both arms
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: Generated a human-style torso vest with a neck hole; not an arm.
  - part `body_geom` size [2.355, 3.4, 1.966] mesh `rbxassetid://140174616110470` texture `rbxassetid://100194076772440`
- Attempt 2: REJECTED; model `-`; error: none
  - Evaluation: A 1.1-stud-wide tube lying along Z; far too thin for the 2-stud arm frame. Budget spent; the upper arm reuses MEC_015.
  - part `body_geom` size [1.085, 1.081, 3.0] mesh `rbxassetid://138357831137801` texture `rbxassetid://115751012665687`

## MEC_017 ForearmGauntlet - ACCEPTED
Intended use: Added in M05 after wave-1 review: forearm armor over the procedural ForearmFrame/Gauntlet (Elbow joint). Rig note: Hangs along -Y from Elbow; X-symmetric; shared by both arms
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Forearm casing with visible spring piston, side shield plate and a block fist at the bottom; thin (1.7 wide), so it is scaled 1.3x in X. The fist sits inside the weapon sleeve.
  - part `body_geom` size [1.693, 3.8, 1.795] mesh `rbxassetid://132890788763855` texture `rbxassetid://112696406654292`

## WPN_010 AutocannonVisual - ACCEPTED
Intended use: Visual for logical weapon W_MACHINE_GUN (MG-9). Rig note: Barrel toward -Z, breech at origin after fit
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Barrel with perforated shroud, receiver, ammo belt drum and a turret-style pedestal; mesh came out 2 studs long and is scaled up.
  - part `body_geom` size [0.934, 1.8, 2.035] mesh `rbxassetid://109772887065211` texture `rbxassetid://133527392638673`

## WPN_011 LaserRifleVisual - ACCEPTED
Intended use: Visual for logical weapon W_LASER_RIFLE (LR-12). Rig note: Emitter toward -Z
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Rifle with ring lenses, heat-sink fins, power cells, blue emitter and a pistol grip underneath.
  - part `body_geom` size [0.669, 1.6, 3.427] mesh `rbxassetid://96392572459424` texture `rbxassetid://72857362516336`

## WPN_012 PlasmaCannonVisual - ACCEPTED
Intended use: Visual for logical weapon W_PLASMA_CANNON (PC-40). Rig note: Muzzle toward -Z
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Containment housing, radiator barrel, flared muzzle with visible cyan chamber, and support legs at the base.
  - part `body_geom` size [2.4, 2.236, 4.139] mesh `rbxassetid://81041503629663` texture `rbxassetid://110067930651555`

## WPN_013 MissilePodVisual - ACCEPTED
Intended use: Visual for logical weapon W_MISSILE_POD (MR-6). Rig note: Tubes toward -Z
- Attempt 1: ACCEPTED; model `-`; error: none
  - Evaluation: Rectangular armored pod with a 2x3 tube face and rear exhaust ports. Reads clearly as a launcher.
  - part `body_geom` size [1.988, 2.2, 1.483] mesh `rbxassetid://135711252277823` texture `rbxassetid://82226125932330`

