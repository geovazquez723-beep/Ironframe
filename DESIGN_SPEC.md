# IRONFRAME — Foundational Game Design (v0.1)

## Vision

A visually distinctive, military-industrial mech engineering and combat experience. The **mech is the hero**, the garage is the main attraction, and the battlefield validates player designs. Priorities: **mechs/customization first**, **weapons second**, **environments third**. Long-term: expansive maps, selective building destruction, deformable-looking armor, energy/ballistic/missile combat, immersive cockpit telemetry and responsive third-person presentation.

## Non-negotiables

1. Every pilot **always ejects successfully** before terminal mech destruction; no injury/death systems, pilot targeting, gore, or NPC civilian harms.
2. Mechanical destruction may be spectacular, but avoid overly graphic effects. Aim for broad age accessibility; Roblox maturity rating is determined by Roblox's questionnaire and content standards, not promised by this design.
3. Deep chassis modularity is fundamental, not cosmetic theater. Loadout choices alter weapon mounts, tonnage, power, thermal budget, movement, protection, silhouette, and combat.
4. Visual cosmetics should not grant combat advantages. The initial release provides free personalization, with a future optional cosmetic economy.
5. Build original sci-fi IP; MechWarrior and Armored Core are only inspiration, not an asset/design source.

## First chassis — IF-42 Bastion

Fictional medium-weight bipedal frame, dry mass 19.5 units, maximum loaded mass 42 units, base integrity 1000, 6 independently selectable weapon sockets. Arms accept sizes 1–3. Shoulder sockets accept sizes 1–2. Torso auxiliary sockets accept sizes 1 and only energy/ballistic (no missiles). Separate reactor, cooler, and armor equipment. Feet, armature, torso, sensor/cockpit, and armor become independent visual modules once the art pipeline is in place.

## First three archetypes

- `BALANCED`: lasers + ballistics + missile pod; versatile.
- `ENERGY`: plasma + multiple lasers; high burst, thermal stress.
- `MISSILE`: paired missile launchers, machine guns; ammunition/lock-on tactics to be built later.

## Core architectural contracts

- `ChassisRegistry`: chassis definitions and explicit socket compatibility.
- `ComponentRegistry`: data-driven equipment with immutable internal IDs.
- `LoadoutCompiler.Compile`: deterministic validation and stat derivation; no automatic clamping of illegal builds.
- `MechFactory`: visuals from resolved chassis + loadout; replaceable without changing compiler contracts.
- Future `MechMovement`: kinematic movement model separated from animation and weapon systems.
- Future `ComponentDamage`: severable/disableable component states; reactor damage => safe evacuation first.
- Future `CockpitTelemetry`: read-only projection of server-resolved values + client effects.

## Milestone gates

- **M01 Garage**: visually inspect one mech; switch three valid presets; socket/weight/power checks operate; guaranteed pilot ejection animation; diagnostic prints.
- **M02 Mech rig**: replace primitives with original modular imported meshes; mechanical articulation; believable movement, locomotion/torso rotation; measured client performance.
- **M03 Combat range**: energy, ballistic, plasma, guided missile + heat/cooling + ballistic ammo + server-authoritative target damage.
- **M04 Component damage and cockpit**: arms/legs/weapons/sensors/cooler disable independently; rich telemetry and successful auto-eject.
- **M05 Worlds + multiplayer**: staged selective destruction, streamed maps, replicated combat with fair anti-exploit validation; scoped game modes.

## Acceptance for first coding session

1. No existing `roblox_dev` or Elonzo game sources modified.
2. `rojo serve` can sync a new blank place; no purchased third-party assets needed.
3. Presets compile and swap with visible differences; illegal presets rejected by server.
4. In-game stats display mass, power, heat, cooling, durability and nominal DPS.
5. Test evacuation visually produces a protected capsule before disabling the machine; player cannot be damaged.
6. Performance remains reasonable in a single-player Studio play session, with no silent errors in Output.
