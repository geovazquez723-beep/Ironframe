# Ironframe original weapon audio

All weapon sounds below are original deterministic mathematical synthesis (Python standard library only, no recorded
or third-party samples), mono 44.1 kHz 16-bit PCM, CC0-1.0.

| Weapon | WAV | Generator | Manifest | Roblox asset | Status |
| --- | --- | --- | --- | --- | --- |
| LR-12 laser | `lr12_discharge.wav` (0.32 s) | `tools/synthesize_weapon_audio.py` | `manifest.json` | `123083870222487` | registered, Approved/Active (uploaded manually by the project owner) |
| HMG-20 Mauler | `mauler_discharge.wav` (0.62 s) | `tools/synthesize_mauler_audio.py` | `mauler_discharge.json` | `75916048000769` | uploaded by `tools/roblox_audio_upload.py`, Approved/Active |

MG-9 discharge, receiver and casing detail still use the bundled client files `rbxasset://sounds/impact_explosion_03.mp3`
and `rbxasset://sounds/action_footsteps_plastic.mp3` (cropped/pitched); they have no uploaded asset. The Mauler's
receiver slam and casing bounce details use the same bundled mechanism sample at lower pitch.

## Automated upload pipeline (Open Cloud)

`tools/roblox_audio_upload.py` (stdlib only) reads the key from the `ROBLOX_OPEN_CLOUD_API_KEY` environment variable
(process env, or the Windows User/Machine variable) and never prints or stores it. Needed key scopes: `asset:read`,
`asset:write`. Uploads need a creator: `IRONFRAME_CREATOR=user:<id>` (or `group:<id>`) or `--creator`.

```
python tools/roblox_audio_upload.py upload   --wav assets/audio/X.wav --manifest assets/audio/X.json --name ironframe_x
python tools/roblox_audio_upload.py register --manifest assets/audio/manifest.json --asset-id <id>   # adopt an existing upload
python tools/roblox_audio_upload.py validate --manifest assets/audio/X.json     # asset type Audio + Active + moderation Approved
python tools/roblox_audio_upload.py grant    --manifest assets/audio/X.json --universe-id <id>   # optional experience grant
```

* `upload` skips the network when the manifest already holds an `asset_id` for the same SHA-256 (`--force` overrides),
  submits the multipart request, polls the long-running operation, then polls validation (moderation can lag a minute
  or more). Exit status is non-zero until the asset is `Approved` and `Active`; rerun `validate` later and it records the
  result in the manifest (`status`, `validated_at`).
* Then set the returned id in `src/ReplicatedStorage/IronframeShared/WeaponPresentation.luau` (`audio.*AssetId`, as
  `rbxassetid://<id>`) and run `tools/verify_weapon_audio_studio.luau` on **Client** during Play to confirm the sound
  loads, has the expected duration and decodes a signal.
* The two generators are deterministic. Regenerating keeps a recorded `asset_id` when the new WAV has the same SHA-256;
  a changed WAV resets the registration so the new file must be uploaded again.
* `grant` uses the asset-permissions API (needs that scope; not exercised). Assets stay private to the creator account
  by default and play in that account's own experiences. The local test place is unpublished (universe id 0), so no
  experience grant has been made or tested; add the real universe id before shipping to another experience or group.

Official references: [Roblox audio assets](https://create.roblox.com/docs/audio/assets),
[asset permissions](https://create.roblox.com/docs/projects/assets/privacy),
[Assets Open Cloud API](https://create.roblox.com/docs/cloud/reference/features/assets).

## HMG-20 generation and candidate selection

`python tools/synthesize_mauler_audio.py` renders three candidates (A, B, C: body/crack balance and seed), measures
each, scores it against a heavy-cannon target profile and writes the winner plus the full candidate report into
`mauler_discharge.json`. Layers: 2 ms filtered-noise crack (2.8 kHz + 1.4 kHz bands), falling-sine receiver slam
(240 -> 66 Hz), low pressure body sweep (98 -> 44 Hz, 38 Hz high-pass so no sub-bass flood), four inharmonic steel ring
partials (412/709/1163/1688 Hz), a mid blast tail, a quiet bolt-return tick at 0.19 s, tanh soft saturation (never
hard clipping), 7.8 kHz low-pass and a 60 ms release. `--check` validates the committed file only.

Objective measurements are not a listening verdict (no audio loopback exists in this environment). Candidate scores
(lower is better): A 2.58, B 3.74, **C 1.67 (selected)**. C: peak -3.00 dBFS, RMS -17.18 dBFS (LR-12 is -18.44), crest
14.2 dB, zero clipped samples, DC ~0, sub-40 Hz energy 0.01 percent, 87 percent of raw power in 40-200 Hz with an
A-weighted centroid near 1.37 kHz and 10.6 percent A-weighted energy above 2 kHz, -30 dB envelope decay 0.29 s. Shots
arrive every 0.333 s, so each tail has decayed below -30 dB before the next transient.

## Playback behavior

Fixed pool: eight discharge and four detail voices (no per-shot allocation). Distance attenuation 12..220 studs
(Mauler rolloff starts at 22). Cockpit mix uses the existing `CockpitAudio` state at 62 percent of exterior volume;
MG-9/LR-12 keep low 0 / mid -2 dB / high -14 dB, the Mauler uses low +3 / mid -4 / high -20 dB so the cockpit keeps
structural thump but loses bite. Voices stop on swap, recall and ejection. A weapon whose asset id is empty stays
silent (no substitute sample, no invented id).

## Destruction audio (M10A)
Six more original synthesized sounds in `assets/audio/destruction/` (`tools/synthesize_destruction_audio.py`, deterministic, CC0):
`concrete_hit`, `metal_hit`, `laser_sizzle`, `collapse`, `explosion`, `zap`. Uploaded with `tools/roblox_audio_upload.py upload
--creator user:3611602826` (moderation lagged a minute or two; `validate` recorded Approved / Active for all six) and registered in
`IronframeShared/DestructionConfig.audio`. `python tools/synthesize_destruction_audio.py --check` verifies WAV hashes against the
manifests and the Luau ids against the manifests. Playback: `DestructionFx` voice pool (10 voices, InverseTapered 30..420 studs);
an empty id stays silent. Not verified: listening judgement, playback in other experiences.

