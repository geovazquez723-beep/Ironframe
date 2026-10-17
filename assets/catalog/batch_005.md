# batch_005 catalog

Generated from the spec and manifest by `tools/assetfactory.py catalog`. Values are only those Studio reported.

Summary: ACCEPTED 1

| ID | Name | Status | Attempts | MeshParts | Bounding box (studs) | Persistence |
| --- | --- | --- | --- | --- | --- | --- |
| TNK_001 | TrainingTankSegmented | ACCEPTED | 3 | 4 | 11.5x9.0x17.1 | CLOUD_VERIFIED |

## TNK_001 TrainingTankSegmented - ACCEPTED
Intended use: Visual skin for the TrainingTank (hull, turret+gun, two tracks); hit geometry, welds and component rules stay procedural and deterministic. Rig note: Gun toward -Z, resting on the ground plane; part pivots are kept relative to the model bounding box
- Attempt 1: REJECTED; model `-`; error: none
  - Evaluation: The generator ignored 'turret only' and produced a complete small tank as ONE mesh (hull, tracks and turret fused), 3.6 x 5.3 studs instead of 8 x 22, and the baked texture did not load in the editor (flat grey). Cannot be split into components; rejected.
- Attempt 2: REJECTED; model `-`; error: none
  - Evaluation: Again a complete textured tank as one fused mesh (7.4 x 11 studs, far under the requested 18 x 27). Good silhouette but no separable turret or tracks, so component damage could not be shown on it. Rejected as a skin; prompt changed to request the complete vehicle with explicit parts.
- Attempt 3: ACCEPTED; model `-`; error: none
  - Evaluation: Inspected in Studio next to the proving ground: a convincing four-part tank (hull with glacis, fenders, engine deck; wide cast turret with cupola, bustle and long gun with muzzle brake; two tracks with road wheels and cleats). Came out 11.5 wide x 17.1 long (requested 16 x 28), so it is scaled 1.55x at placement. Gun faces -Z. Palette is a pale olive-grey baked texture; MeshPart.Color does not tint it (as documented in assets/README.md), so wreck states clear the texture and apply a charred colour, and intermediate damage uses server scorch discs. Accepted.
  - part `hull_geom` size [11.539, 4.333, 14.216] mesh `rbxassetid://136032002624424` texture `rbxassetid://85789488083928`
  - part `turret and gun_geom` size [8.017, 3.833, 15.377] mesh `rbxassetid://99527104702414` texture `rbxassetid://134366017962717`
  - part `left track_geom` size [2.247, 3.919, 13.223] mesh `rbxassetid://73961123198742` texture `rbxassetid://118044329024154`
  - part `right track_geom` size [2.313, 3.913, 13.227] mesh `rbxassetid://77623664745474` texture `rbxassetid://113946293468803`

