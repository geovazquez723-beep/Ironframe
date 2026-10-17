"""Original LR-12 PCM sound design. Standard library only; no recorded/third-party samples.
Run python tools/synthesize_weapon_audio.py, or --check to validate the committed WAV.
"""
import argparse
import hashlib
import json
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets" / "audio"
RATE = 44100
DURATION = 0.32
SEED = 1209


def synthesize():
    rng = random.Random(SEED)
    phase = mod = bass = 0.0
    samples = []
    low1 = low2 = dc = 0.0
    # Two cascaded gentle low-pass sections soften >4 kHz energy.
    alpha = 1 - math.exp(-2 * math.pi * 3900 / RATE)
    for i in range(round(RATE * DURATION)):
        t = i / RATE
        attack = min(1, t / 0.0018)
        release = min(1, max(0, (DURATION - t) / 0.028)) ** 2
        frequency = 330 + 1450 * math.exp(-t / 0.052)
        phase += 2 * math.pi * frequency / RATE
        mod += 2 * math.pi * (120 + 410 * math.exp(-t / 0.04)) / RATE
        bass += 2 * math.pi * (120 + 130 * math.exp(-t / 0.035)) / RATE
        electronic = (math.sin(phase + 1.4 * math.exp(-t / 0.045) * math.sin(mod))
                      + 0.22 * math.sin(phase * 2.01)) * math.exp(-t / 0.064)
        sharp_attack = rng.uniform(-1, 1) * 0.22 * math.exp(-t / 0.006)
        resonance = 0.42 * (math.sin(bass) + 0.18 * math.sin(bass * 1.99)) * math.exp(-t / 0.082)
        discharge_texture = rng.uniform(-1, 1) * 0.075 * math.exp(-t / 0.045)
        value = (electronic + sharp_attack + resonance + discharge_texture) * attack * release
        low1 += alpha * (value - low1)
        low2 += alpha * (low1 - low2)
        dc += (1 - math.exp(-2 * math.pi * 35 / RATE)) * (low2 - dc)
        samples.append(low2 - dc)
    peak = max(abs(v) for v in samples)
    # -3 dBFS headroom before runtime attenuation; mono spatial sound, no piercing ultrasonics.
    return [max(-32767, min(32767, round(v / peak * 0.707 * 32767))) for v in samples]


def check(path):
    with wave.open(str(path), "rb") as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == RATE
        assert wav.getcomptype() == "NONE"
        values = struct.unpack("<" + "h" * wav.getnframes(), wav.readframes(wav.getnframes()))
    assert len(values) == round(RATE * DURATION)
    peak = max(abs(v) for v in values) / 32768
    rms = math.sqrt(sum(v*v for v in values)/len(values)) / 32768
    assert 0.65 < peak < 0.75 and 0.03 < rms < 0.3
    assert abs(sum(values)/len(values)/32768) < 0.005
    assert abs(values[0]) < 10 and max(abs(v) for v in values[-44:]) < 100
    return {"file": str(path.relative_to(ROOT)).replace("\\", "/"), "duration": len(values)/RATE,
            "sample_rate": RATE, "channels": 1, "bits": 16, "peak_dbfs": round(20*math.log10(peak), 2),
            "rms_dbfs": round(20*math.log10(rms), 2), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = DEST / "lr12_discharge.wav"
    if not args.check:
        DEST.mkdir(parents=True, exist_ok=True)
        values = synthesize()
        with wave.open(str(path), "wb") as wav:
            wav.setparams((1, 2, RATE, len(values), "NONE", "not compressed"))
            wav.writeframes(struct.pack("<" + "h"*len(values), *values))
    info = check(path)
    if not args.check:
        info.update({"asset_id": None, "status": "awaiting_manual_upload_and_experience_permission_check",
                     "source": "Original deterministic synthesis; tools/synthesize_weapon_audio.py; seed 1209",
                     "rights": "Original mathematical synthesis for Ironframe. No third-party samples. CC0-1.0."})
        (DEST / "manifest.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
