# LR-12 original audio — import required

`lr12_discharge.wav` is original mathematical synthesis for Ironframe: 0.32 seconds, mono, 44.1 kHz, 16-bit PCM; peak -3.01 dBFS. It contains a short filtered-noise/electronic attack, an FM-modulated falling discharge, restrained low-frequency resonance and a controlled decay. No external recording or third-party sample was used. Source: `tools/synthesize_weapon_audio.py`, fixed seed 1209. License: CC0-1.0 (dedicated to the public domain to the extent permitted by law).

**No Roblox asset ID exists yet.** `manifest.json` records `asset_id: null`. The available Studio tools can search/insert existing audio but cannot upload a local WAV. User inventory search found no existing laser audio. Community search results were inspected but not selected as substitutes for the original sound. The LR-12 audio path intentionally remains silent until import; it does not use the former UI slider beep or an invented ID. Laser visuals and gameplay still function.

## Import and register

1. Open the intended Ironframe experience in Studio using the creator account/group that owns it. The local M08C test place reports itself as unpublished, so it does not establish a destination experience's audio permissions.
2. Open **Asset Manager**, choose **Import**, and select `C:\repo\ironframe\assets\audio\lr12_discharge.wav`. Confirm the import and wait for completion/moderation. Alternatively, upload the same file through the Creator Dashboard's audio asset upload flow.
3. Copy the numeric ID Roblox actually returns for this audio. In the Creator Dashboard choose **Development Items > Audio**, select the uploaded asset, then **Permissions > Experiences > Add experiences**. Enter the intended Ironframe universe ID, click **Add**, then **Done** if a grant is needed. Use its **universe/experience ID**, not its start-place ID. Keep the asset private unless you intentionally want public distribution.
4. Edit `src/ReplicatedStorage/IronframeShared/WeaponPresentation.luau`: set `audio.laserAssetId` to `rbxassetid://` followed by the real returned ID. Update `assets/audio/manifest.json` with that numeric `asset_id` and the verified destination universe ID. Do not alter the weapon component's costs or timing.
5. Rebuild with Rojo and restart Studio Play so both the client configuration and its module cache refresh.
6. Run `tools/verify_weapon_audio_studio.luau` on **Client** in the intended experience. It checks loading, duration and decoded playback, then cleans up the temporary verification Sound. Inspect Output for access/moderation failures. Success in an unpublished owner Studio session alone is not proof of permission for another experience or player.
7. Fire repeated LR-12 pulses in cockpit and exterior views. Listen at normal device volume for the electronic attack, falling body and brief resonance. Confirm the tail ends within about 0.32 seconds, pitch variation is modest, cockpit highs are softened, and repeated shots do not stack excessively. Also test from a second player account/session with access to the actual experience.
8. Record the asset ID, destination permission check and listening result in `docs/M08C_WEAPON_POLISH.md`. Until this is done, the audible laser success criterion remains unverified.

## Existing MG audio

The prototype MG discharge still uses the already-established Roblox client sample `rbxasset://sounds/impact_explosion_03.mp3`, cropped to 0.13 seconds of playback and pitched slightly higher. Receiver and casing transients use the existing `rbxasset://sounds/action_footsteps_plastic.mp3`, cropped to 0.055/0.09 seconds and brightened by pitch. These are bundled Roblox files, not newly uploaded numeric assets; no new asset ID is claimed for them. Their mechanical/metallic character still needs a human listening review.

The fixed pool has eight discharge and four detail voices. Distance attenuation uses 12..220 studs. Cockpit mix reads the existing `CockpitAudio` state: volume 62% of exterior, high band -14 dB, mid band -2 dB, low band retained. The generated laser plays as one clip with all four layers pre-mixed, varying speed by at most 2.5% per shot. No per-shot audio graph or unbounded Sound allocation is created.

## Reproduce / validate

```
python tools/synthesize_weapon_audio.py
python tools/synthesize_weapon_audio.py --check
```

Regeneration is deterministic and resets the generated manifest's upload status; preserve a registered manifest before deliberately regenerating after upload. `--check` only validates the WAV and does not rewrite it or its registration metadata. Objective signal/format validation is not a listening-quality verdict.

Official references: [Roblox audio assets and import requirements](https://create.roblox.com/docs/audio/assets), [asset privacy and permissions](https://create.roblox.com/docs/projects/assets/privacy), [Sound playback regions](https://create.roblox.com/docs/reference/engine/classes/Sound#PlaybackRegion).
