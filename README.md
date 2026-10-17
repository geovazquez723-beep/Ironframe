# PROJECT IRONFRAME — Milestone 02 (mech rig + hard-surface blockout)

A self-contained **Rojo v7** starter for an original, mech-first Roblox game. This is a functional, deliberately primitive **garage demonstration**, not the finished visual target or a combat simulator.

## Included today

- A server-authored IF-42 Bastion chassis with **six hardpoints** (arms ×2, shoulders ×2, torso ×2).
- 6 weapons, 2 reactors, 2 cooling systems, and 2 armor systems defined as data.
- Loadout compiler: socket compatibility, tonnage, power draw, cooling, derived DPS/integrity.
- Three validated, demonstrably distinct preset loadouts.
- Primitive 3D mech and industrial hangar composed of Studio Parts at runtime.
- Orbital inspection camera; right-drag to orbit, mouse wheel to zoom.
- Screen UI to swap loadouts and see derived statistics update.
- **Safe-ejection demonstration**: pilot flagged safe before the invulnerable capsule animation; disabled mech despawns, then rebuilds.
- Debug logs with step labels and compilation details.
- Per-player assembly positions and server-side preset allowlist.

## Not included

- Walking locomotion, articulated animation, combat weapons firing, damageable parts, PvP, progression, actual high-quality meshes, multiplayer balance, DataStores, payment systems, or finished responsive mobile UX.
- The numerical tonnage and combat values are **fictional prototype units** and will require iteration.

## Setup (Windows)

1. Create an independent local folder such as `C:\repo\ironframe`. Don't put this into `roblox_dev`.
2. Extract these files at repository root, then `git init` (or create a matching private GitHub repository if desired).
3. Install/confirm Rojo v7 and its Roblox Studio plugin are working.
4. From this folder, run `rojo serve default.project.json`.
5. In a new blank Roblox Studio Baseplate place, connect the Rojo plugin to the running server.
6. Press **Play**. Garage models are runtime-generated on the server, so they won't appear in edit mode.
7. Use the left panel to switch presets and test ejection; right-drag / scroll to inspect.
8. Inspect Studio **Output** for `[IF-STEP-01]` through `[IF-STEP-05]` and `[IF-CLIENT]` logs.

### Expected results

- Server validates **3 / 3** presets with no assertion failures.
- Garage contains a dark gantry and a 3D primitive Bastion model.
- All three preset buttons reassemble the mech with changing weapon geometry and updated telemetry.
- Ejection spawns a rising escape pod **before** the machine disappears, then rebuilds it.
- No pilot damage, pilot kill logic, player-vs-person weapon system, or monetization system exists.

## Future art pipeline

Studio primitives are temporary. Author **original** high-fidelity modular models in Blender; export `.fbx` or `.gltf` and import via Studio. Name and maintain six common weapon socket attachments and independent armor/leg/core attachment contracts. Preserve deterministic asset naming for reimport. Material studies: worn military alloys, large silhouette shapes, hydraulic joints, purposeful vents, PBR trim sheets, meaningful emissive light accents. Don't copy third-party game meshes or protected designs.

## Architecture constraints

The authoritative compiler and preset selection run server-side. Real PvP will require validating any client input (fire events, positions, loadout modifications). We intentionally have not implemented character collision/movement/network ownership in this garage stage.

**Permanent invariant:** Mechs may be disabled; pilots never die. On terminal damage, set `pilotSafe = true` and transition to safe evacuation **before** mech destruction VFX. Pilots/capsules are never targetable. Avoid kills/deaths language in final stats.

**Performance:** For the future, use meshes and a kinematic/animatable rig, not hundreds of unconstrained simulated parts; adopt LOD/streaming for large maps. This first garage uses anchored parts and cannot walk.

## Milestone 02 additions

- **Rig contract** (`RigSpec.luau`): 14 joints (hip, torso yaw, head, 2x shoulder/elbow, 2x thigh/knee/ankle), 6 weapon
  sockets bound to joints, 10 hydraulic links, documented axes (mech faces -Z, +X is right). `MechRig` solves/applies
  poses to anchored parts only - no physics constraints.
- **Procedural Bastion** (`BastionBuilder`, `WeaponModules`, `PartKit`): layered armor panels, recessed cockpit, reactor
  and exhaust stacks, joint collars, per-preset paint/variants, five distinct weapon modules. Drop a MeshPart named like a
  procedural part into `ServerStorage/IronframeAssets/IF42_BASTION/` and it replaces it with the same joint/LocalCF.
- **Showroom animation** (`Showroom` + client `ShowroomAnimator`): deterministic idle sway/torso turn/head scan.
- **Garage camera/avatar**: `GarageCamera` (smooth orbit/zoom/reset), `AvatarHider` (client-only, non-destructive).
- **Safety**: `EjectionSequence` guarantees `pilotSafe` before any mech hook runs.
- **Tests**: `SelfTest` (13 cases, runs on server start, shown in UI); `tools/check.sh` runs Luau syntax/lint offline.
  See `STUDIO_CHECKLIST.md` for manual checks.

## Milestone 03 additions

- Bastion rebuilt with layered standoff-mounted armor, shoulder/hip lames, seated weapon mounts, ribbed exhaust,
  vents, fasteners and clamp-collar hydraulics (~510 parts). Material language documented in `BastionBuilder.luau`.
- Showroom lighting (key/fill/rim spots, low ambient, subtle bloom); template SpawnLocation hidden at runtime.
- Garage camera view keys `1`-`5`; fixed an animator bind race that could leave a late-streamed mech static.
- `ASSET_PIPELINE.md`: Blender -> Roblox workflow (no mesh authored; Blender not available here).

## Milestone 04B: Hangar 2.0 and runtime asset integration

- `HangarArchitecture` (floor, trenches, platform, walls, armored doors, columns, trusses, gantry crane, catwalks),
  `HangarDressing` (pipes, ducts, cable trays, transformers, storage, signs, ALL lights, AI-asset placement rows),
  `HangarKit` (part helpers). `WorldBuilder` only orchestrates (lighting, atmosphere, asset load, per-bay build).
- AI assets: `IronframeShared/AssetRegistry` (generated by `python tools/assetfactory.py registry <spec>`; ACCEPTED only)
  -> `AssetLibrary` loads cloud model ids with `InsertService:LoadAsset` at server start, caches them in
  `ServerStorage/IronframeAssetCache` (not Rojo-mapped), and `AssetLibrary.Place(id, cf, {scale, grounded, parent})`
  clones/scales/anchors them. Add a batch: record+accept in the manifest, run `registry`, add rows to `PLACEMENTS`.
- Persistence: geometry lives in Roblox cloud assets (ids in Git); no staging place is needed at runtime.
  If a load fails the asset is skipped with an `[IF-ASSET]` warning, never substituted. Fix for permission errors:
  the asset owner must match the experience owner (or share the assets with it).
- Camera: orbit camera now raycasts against CanQuery hangar structure and is capped under the roof trusses; keys 6-8
  give overview / east maintenance / crane views.
- `tools/studio_cycle.ps1` rebuilds `build/Ironframe.rbxl` (git-ignored) and opens it in a new Studio instance.
