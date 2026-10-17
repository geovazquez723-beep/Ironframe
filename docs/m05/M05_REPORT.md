# M05 report: IF-42 Bastion visual overhaul

Branch `feature/m05-bastion-overhaul`, from M04B `0e70cac`. Not pushed. Screenshots are in this folder.

## What changed

The Bastion's armor shells, cockpit bezel, forearms and all four weapon visuals are now AI-generated meshes
(Roblox `generate_mesh` through the M04A factory). The procedural frame, joints, collars, hydraulics, reactor,
head and mounts are unchanged and sit underneath. The procedural parts the meshes replace are removed, and each
one is rebuilt automatically if its asset fails to load.

Untouched: `RigSpec.luau` (14 joints, 6 sockets, 10 hydraulic links), `MechRig`, the loadout compiler and
registries, the three presets, the ejection sequence, and the hangar. No joint position, hardpoint or parent was
changed, so no rig-impact validation was needed.

| Area | Change |
| --- | --- |
| `PartKit:mesh` | New. Places a multipart asset from `AssetLibrary` as ordinary rigged parts (`Joint`, `LocalCF`, `Group`). Single-MeshPart overrides in `ServerStorage/IronframeAssets` still work. |
| `BastionBuilder` | `FIT` table maps asset ids to joints and transforms. Meshes replace the procedural plates; each has a procedural fallback. Palette retuned. |
| `WeaponModules` | `Meshes` table picks a visual per logical weapon id (`WPN_010..013`). Cost, stats and socket rules still come only from `ComponentRegistry` and the compiler. |
| `ArmorGrade.client` | New. Graded copy of each mesh texture on the client (see "Materials"). |
| `GarageCamera` | Camera is kept at least 1 stud clear of the mech's own parts. |
| `MechFactory` | `options.useAssets=false` builds the all-procedural mech (used by tests and as the fallback). |
| `SelfTest` | 3 new tests. 18/18 pass. |
| Asset tooling | `assets/specs/batch_002.json`, manifest, catalog, 17-entry `AssetRegistry`. `tools/check.sh` and `tools/studio_cycle.ps1` fixes. |

## Assets

Generation limits observed: prompts up to about 400 characters were fine, one transient "Failed to fetch image"
error (retried successfully), no rate-limit errors with 2 concurrent jobs. Retries were bounded to about 4 per
component. Full attempt history, ids and triangle counts are in `assets/catalog/batch_002.md` and
`assets/manifests/batch_002.json`.

| ID | Component | Result | Notes |
| --- | --- | --- | --- |
| MEC_010 | Chest armor | Accepted, 3rd attempt | Attempts 1-2 rejected: a wearable vest, then a literal tank. 7,700 tris. |
| MEC_011 | Pauldron | Accepted, 3rd attempt | One mesh serves both sides. 5,959 tris. |
| MEC_012 | Shin | Accepted, 4th attempt | Earlier attempts gave trousers and a mini torso. 4,842 tris. |
| MEC_013 | Foot | Accepted, 2nd attempt | First came out as a human boot at 1 stud wide. 5,018 tris. |
| MEC_014 | Cockpit bezel | Accepted, 2nd attempt | First attempt came out as a helmet. 3,862 tris. |
| MEC_015 | Thigh | Accepted, 1st attempt | Also reused (turned 90 degrees) as the outer side guards on thigh and upper arm. 5,368 tris. |
| MEC_016 | Upper arm | **Rejected** (2 attempts) | A vest, then a 1.1-stud tube. Not retried further; MEC_015 covers the upper arm. |
| MEC_017 | Forearm | Accepted, 1st attempt | Thin, scaled 1.3x in X. 5,584 tris. |
| WPN_010 | Autocannon | Accepted | 6,690 tris. |
| WPN_011 | Laser rifle | Accepted | 6,210 tris. |
| WPN_012 | Plasma cannon | Accepted | 7,102 tris. |
| WPN_013 | Missile pod | Accepted | 6,816 tris. |

All accepted assets are single-mesh. Segmented generation (`explicit` partNames) returned a good main part plus
sub-millimetre fragments every time, so it was dropped. Because of this, "multipart" support exists in
`PartKit:mesh` but no production asset currently uses it.

Left/right: one mesh per pair. Pauldron, thigh, shin and foot meshes are close to X-symmetric, so both sides
reuse the same mesh and size (asserted by a test). No negative scaling anywhere.

Cloud persistence: all 17 assets (6 hangar + 11 new) load from their cloud model ids at game start in a place
built from the repo by Rojo, with the asset-staging place not involved: `[IF-ASSET] Loaded 17/17`. Only ids are in Git.

## Materials and presentation

- Generated textures are pale mint and `MeshPart.Color` does not tint a baked texture. Scripts also cannot write
  `SurfaceAppearance` maps. The server therefore stamps each mesh with a `TintColor` attribute and
  `ArmorGrade.client` multiplies it into an `EditableImage` copy of the texture. Parts are hidden for a few frames
  while the grade is made so they never flash pale. If `EditableImage` is unavailable, armor shows ungraded
  and a warning is logged.
- Observed Studio behaviour that shaped the code: an `EditableImage` whose previous users were all destroyed
  renders black when reused. Images are therefore created per (texture, tint), shared by live parts and destroyed
  with the last one.
- Procedural armor, frame, ring and steel colors were darkened or desaturated. Hangar lighting is unchanged.
- Joint-ball and ring diameters on shoulders, elbows, knees and hips were reduced so joints read as mechanisms and
  do not bulge past the new armor.

## Measurements (BALANCED, Studio Play)

| | M04B baseline | M05 |
| --- | --- | --- |
| Mech instances | 511 | 308 |
| BaseParts | 509 | 306 |
| MeshParts | 0 | 22 |
| Mesh triangles (EditableMesh face counts) | 0 | about 102,000 |
| Primitive triangles (estimate: 12 per box, 96 per cylinder, an assumption) | about 22,000 | about 15,000 |
| Whole-scene triangle count (`Stats.SceneTriangleCount`) | 70,652 | 166,958 |
| Moving primitives | 528 | 323 |
| Client CPU / GPU frame time (`PerformanceStats`) | 16.69 ms / 1.29 ms | 16.57 ms / 1.75 ms |
| Client memory | 2,972 MB | 3,052 MB |

ENERGY and MISSILE show the same shape (314 and 317 instances, versus 518 and 523 before).

Studio frame time sits at 16.6 ms in both cases, which looks like a 60 fps cap, so this does not show headroom. Triangle
count rose about 2.4x because the meshes are denser than the boxes they replace. Each mesh is 4-8k triangles, in line with ASSET_PIPELINE.md's per-assembly budget, but there are 22 of them:
**the full Bastion is about 102k mesh triangles, over that document's 25k-per-mech target.** That is the main open
performance risk for a multi-mech scene; Roblox's automatic mesh LOD was not measured. Measured on one desktop Studio session only.

## Verification

- `tools/check.sh` (Luau compile and analyze): clean. Self-test: 18/18 in Play. Console: no errors from game code.
  Remaining console noise is Roblox core UI warnings and `ContentId rbxassetid://203785492` (pre-existing).
- New tests: AI armor keeps the rig contract and falls back cleanly (also checks AI armor reduces the part count);
  L/R share one mesh and weapon visuals keep logical ids; armor clearance through a 60-second idle sweep
  (pauldron vs head, chest, upper arm; chest vs upper arm; thigh vs thigh and shin).
- Loadouts: all three presets built and screenshotted in Play, using the real UI buttons for ENERGY and MISSILE.
- Idle animation and weapon attachment: the existing "weapons stay attached while torso turns" test passes with
  mesh weapons (relaxed from 30+ parts to 6+, since each weapon is now one part).
- Safe ejection, destruction, rebuild: triggered through the real UI button and sampled on the server:
  `PILOT_EVACUATED` with capsule at t=0, mech destroyed at t=1.0 s, rebuilt `OPERATIONAL` with 18 AI meshes at
  t=4.0 s, capsule cleaned up.
- Camera: a sweep of 720 orbit samples at minimum zoom found 34 cases with the lens inside geometry before the fix
  and none after (minimum clearance 1.0 stud), measured on the BALANCED mech.
- The camera test uses the model's own parts only, so clearance against hangar structure is the existing raycast.

## Known limitations

1. **The mech still reads as a robot-in-armor in places.** Torso/leg silhouette is much stronger than before, but
   the procedural frame is visible as dark slabs (`ChestFrame`, `ThighFrame`, `ForearmFrame`, pelvis plates) and the chest looks like a shallow front shell on a block, not a built-in volume.
2. **Side profile is the weakest view.** The chest mesh is 2.5 studs deep over a 4.2-stud frame, so the flanks
   and back are still procedural boxes (visible as the dark flat panels and yellow-edged slabs in `03_side.jpg`).
3. **Cockpit:** the bezel works as a surround for the existing canopy glass. It does not look deeply recessed.
4. **Upper arm** has no dedicated mesh (MEC_016 rejected); it uses the thigh mesh as a front guard plus side guard.
5. **Weapons** are placed by eye from the generator's output. Several meshes include their own pedestal or grip, which
   overlaps the procedural socket mounts; this was not tuned per weapon beyond the position and scale in `WeaponModules.Meshes`.
6. **Reinforced armor** (`ARMOR_REINFORCED`) is still the procedural chest/pauldron overlay and was not checked against the
   AI pauldron.
7. **`ArmorGrade` depends on `EditableImage`** which is a newer API; behaviour outside Studio was not tested.
8. Only the ENERGY screenshots show the plasma cannon; side/rear/low-angle shots are BALANCED only.
9. Triangle budget (above) and the Studio-only performance measurement.
10. Roblox core UI/bloom was not tuned. Hangar lighting is as in M04B.
