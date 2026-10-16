# NEXT AGENT SESSION — IMPLEMENT M02, FOCUS ON QUALITY

Work in an independent `C:\repo\ironframe` repository initialized from the supplied starter. Do NOT touch the existing `C:\repo\roblox_dev` repository or Elonzo's games.

Project vision: IRONFRAME is an original, mech-first Roblox military-industrial engineering and combat game. The player bonds with a customizable robot. The priority is sophisticated, visually impressive, modular mechs, not maps or progression. **Human pilots never die; every pilot ejects successfully and cannot be damaged or targeted.** The starter already provides server-side registries, a compiler, three loadouts, an anchored primitive garage mech, runtime hangar, GUI, and safe-ejection demonstration.

First: inspect the repository and report its actual structure and what currently works. Confirm `LoadoutCompiler` behavior and named sockets. Find and fix any Luau/Roblox runtime errors; do not claim Roblox Studio testing if you couldn't launch or observe it. Do not rewrite valid architecture gratuitously.

Then deliver one scoped M02 iteration:

1. Establish an explicit **modular mechanical rig contract**: core root, rotating torso, hip assembly, two articulated legs, two articulated arms, head/sensor mount, separate armor panels, six weapon sockets. Attachment positions and axis conventions are documented and mechanically coherent. Preserve original custom meshes as swappable model resources when imported later.
2. Replace the current static box-only presentation with a substantially more intentional **procedural hard-surface blockout**: layered armor plates, visible mechanical joints, pistons or hydraulic cues, recessed cockpit, exhaust/reactor assemblies, and purposeful silhouettes. This is still a blockout; do NOT claim Blender-level visual fidelity, and do NOT generate fake asset IDs.
3. Implement a safe, deterministic **showroom animation** (idle sway, torso turn, subtle hydraulic motion) separate from placement and loadout statistics. Don't build a physically unstable ragdoll of welded dynamic parts.
4. Make each preset visibly different and keep weapon sockets consistent. A weapon must remain correctly attached while the torso turns.
5. Keep the existing safe-ejection transition; it must mark the pilot safe before any destruction visual. No fatalities, pilot hitboxes, or targeting ejected capsules.
6. Add focused tests for loadout compatibility, overweight builds, invalid component IDs, power overdraw, and guaranteed pilot-safe state. Add visible diagnostics and a concise Studio test checklist.

Keep the scope **M02 only**. No open-world map, shooting PvP, persistence system, purchase flow, giant CI/governance layer, or unrelated tooling. Prefer small reversible commits; preserve progress. Present files changed, tests run and limitations, screenshots/Studio evidence if actually available, and next most valuable step.
