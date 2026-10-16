# Blender -> Roblox asset pipeline (IF-42 Bastion)

Status: **workflow only.** Blender is not installed in the authorised environment, so no mesh has been
authored or imported, and no asset IDs exist. Everything below is the contract the procedural parts already
follow, so a mesh can be dropped in without touching the rig, sockets or loadouts.

## How the override works today (`PartKit.add`)

For every part it creates, `PartKit` looks for `ServerStorage/IronframeAssets/<ChassisId>/<PartName>`.
If a `BasePart` (normally a `MeshPart`) with that exact name exists it is **cloned instead of the procedural
part** and receives the same `Joint`, `LocalCF` and `Group` attributes, so `MechRig` poses it like any other part.
Consequences you must design around:

- The mesh's own `Size` is kept - **procedural size is ignored**, only the **LocalCF** is reused.
- The imported part's **pivot** becomes the position that `LocalCF` places, so author pivots where the procedural
  part's centre is (see below).
- Material/colour on the clone are overwritten by the kit (`Color`, `Material`). To keep baked textures set
  `UsePartColor = true` and rely on the MeshPart's `TextureID`/SurfaceAppearance, or extend `PartKit` to skip the
  colour/material overwrite when a template has a `SurfaceAppearance`. (Not done yet - nothing needs it.)
- Hydraulic link parts (`Hyd_<id>_<Role>`) are cylinders positioned by two joints and must stay procedural, or be
  replaced by meshes whose **long axis is local X** (Roblox cylinders run along X).
- Weapon parts are `Weapon_<socket>_<Part>`; a single imported weapon mesh should replace one of those and the
  rest of that weapon should be removed by overriding with an empty/tiny part (a future "ReplaceGroup" helper).

## Naming

| Item | Name |
| --- | --- |
| Chassis folder | `IF42_BASTION` (the `ChassisId`) |
| Armor / frame parts | exactly the procedural names, e.g. `PauldronShellL`, `ChestLowerPlate`, `ThighFrontR` |
| Left / right | `L` / `R` suffix; **left = -X** (mech's left hand) |
| Weapons | `Weapon_<socket>_<Part>`; sockets: `left_arm right_arm left_shoulder right_shoulder left_torso right_torso` |
| Mount structures | `Mount_<socket>_<Part>` |
| Blender objects | same names; export one FBX per Roblox part or one FBX with named children |

`Factory.Describe` counts sockets by the `Weapon_<socket>_` prefix, and `SelfTest` asserts 6 sockets, 14 joints
and 10 hydraulics, so keep those prefixes.

## Coordinate conventions

- Roblox: **Y up, -Z forward (front)**, +X right, 1 stud = 0.28 m. Blender: Z up, **-Y forward**.
- Export FBX with **Forward = -Z, Up = Y** (Blender FBX exporter: Forward `-Z Forward`, Up `Y Up`), apply
  transforms (Ctrl+A -> All Transforms) and set **Scale 1.0, Apply Scalings = FBX Units Scale**; model in studs
  (use 1 Blender unit = 1 stud and the unit scale at 1.0) so no re-scaling happens in Studio.
- **Pivot = the joint-local centre** used by the procedural part. Easiest workflow: build the mesh around the
  origin at the same size as the procedural stand-in (see `BastionBuilder.luau`, `size`) and keep it centred.
  Example: `PauldronShellL` is a 3.8 x 0.8 x 5.0 stud plate centred at `(-5.3, 5.95, 0.1)` in the **Torso** frame
  with a 0.2 rad roll. Model it centred at the origin, already rolled if you want the same silhouette; the roll in
  `LocalCF` is applied again, so **model it unrolled**.
- Joint frames and axes are in `RigSpec.luau` (pitch about X, yaw about Y, roll about Z, rest angles included).
  Model limbs in the **rest pose** frame of their joint: arms/legs hang along -Y from their joint origin.

## Socket and attachment alignment

- Weapon modules grow along **-Z from the socket origin**; `RigSpec.SocketLocalCF` already cancels the arm rest
  pitch so an arm weapon points forward at rest. Keep a weapon's muzzle on -Z and its breech at the origin.
- Mount structures are built in the same socket frame. A new mesh for `Mount_left_arm_Sleeve` must keep the
  weapon pivot (origin) at its centre, 0.2 stud behind the ring.
- Put a Blender empty at each socket with the exact name above for reference; Roblox attachments are not used by
  the rig (it works from `RigSpec` numbers), so the empty is only an authoring aid.

## Scaling and silhouette budget

- Bastion is ~17 studs tall (to pod tops) and ~16 wide with pauldrons. Keep new parts within +-5% of the
  stand-in bounding box so gaps with neighbouring parts stay valid; the layered-armor standoffs assume a 0.1-0.3
  stud air gap.
- Keep armor on `SmoothPlastic`-like finishes (paint) and structure on metal; supply a trim sheet with metal vs
  paint separated rather than baking lighting.

## Mesh complexity and performance

- A single Bastion currently has ~500 anchored parts moved with one `BulkMoveTo` per frame by the client
  animator. Replace clusters of small parts with one mesh per region (e.g. whole pauldron = 1 MeshPart) - this
  is where fidelity gains and part-count reduction coincide.
- Roblox has a per-mesh triangle cap (20k at time of writing - verify against current docs); target **<= 3-5k per armor assembly, <= 25k for the whole mech** for the
  showroom, and plan LOD (`RenderFidelity = Automatic`) for later multiplayer use.
- Prefer one material/texture per MeshPart, power-of-two textures (<= 1024 for armor), no internal faces,
  no n-gons, hard-edge normals for panels.
- Keep `CanCollide=false, CanQuery=false, CanTouch=false, Anchored=true` (the kit sets these) and
  `CastShadow=false` on tiny details.

## Import steps (Studio)

1. Export FBX per part from Blender (settings above).
2. Studio: Avatar -> Import 3D, drop the FBX (or Asset Manager -> Bulk Import); choose "Import as MeshPart".
3. Rename each MeshPart exactly as the procedural part and place under `ServerStorage/IronframeAssets/IF42_BASTION`.
4. Press Play: the part is cloned in place of the procedural one for every preset. Run `SelfTest` and
   `STUDIO_CHECKLIST.md`.
5. For production, publish the meshes and reference by `MeshId` in a template folder checked into the place
   file (Rojo does not carry binary meshes in this project yet - add `.rbxm` models under `assets/` and map them
   in `default.project.json` when the first asset exists).

## Replacement-compatibility checklist

- [ ] Name matches procedural part, spelled and cased exactly.
- [ ] Modelled centred at origin, unrotated relative to `LocalCF`, in studs.
- [ ] Bounding box within +-5% of stand-in; no overlap with neighbouring standoffs beyond 0.1 stud.
- [ ] Mirrored L/R parts are separate meshes (or one mesh with `Size.X` negative is **not** allowed - flip in Blender).
- [ ] Tri count within budget; SelfTest 13/13 still passes; side/rear/front views checked with keys `1`-`5`.

## Recommended first asset

`PauldronShellL/R` + `PauldronCapL/R` + `PauldronBaseL/R` as one shoulder-armor MeshPart per side (replace
the three procedural parts and their standoffs by overriding the shell and shrinking the others), authored
around origin at `3.8 x 0.8 x 5.0` studs.
