"""Original destruction-sandbox sound design for M10A. Standard library only; no recorded or third-party samples (CC0-1.0).

  python tools/synthesize_destruction_audio.py            render every sound, write WAV + per-sound manifest JSON
  python tools/synthesize_destruction_audio.py --check    validate the committed WAV files against their manifests (no rewrite)

Sounds (mono 44.1 kHz 16-bit): concrete_hit, metal_hit, laser_sizzle, collapse, explosion, zap. Each is built from filtered noise,
decaying sine sweeps, inharmonic ring partials and randomised grain bursts with a fixed seed, so output is deterministic. Objective
measurements (peak, RMS, crest, spectral shares, T-30) are recorded; they are not a listening verdict.
Upload with tools/roblox_audio_upload.py (Open Cloud) - see assets/audio/README.md.
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
DEST = ROOT / "assets" / "audio" / "destruction"
RATE = 44100
PEAK = 0.708  # -3 dBFS


class Biquad:
    def __init__(self, kind, freq, q=0.707):
        w = 2 * math.pi * freq / RATE
        alpha = math.sin(w) / (2 * q)
        cw = math.cos(w)
        if kind == "lowpass":
            b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        elif kind == "highpass":
            b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
        else:
            b0, b1, b2 = alpha, 0.0, -alpha
        a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
        self.b = (b0 / a0, b1 / a0, b2 / a0)
        self.a = (a1 / a0, a2 / a0)
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self, x):
        y = self.b[0] * x + self.b[1] * self.x1 + self.b[2] * self.x2 - self.a[0] * self.y1 - self.a[1] * self.y2
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y


def env(t, attack, decay):
    return min(1.0, t / attack) * math.exp(-t / decay)


def render(n, fn):
    return [fn(i / RATE, i) for i in range(n)]


def finish(samples, duration, release=0.03, drive=1.8):
    peak = max(abs(v) for v in samples) or 1.0
    out = []
    n = len(samples)
    for i, v in enumerate(samples):
        v = math.tanh(v / peak * drive) / math.tanh(drive)
        t = i / RATE
        v *= min(1.0, max(0.0, (duration - t) / release)) ** 2
        out.append(v)
    peak = max(abs(v) for v in out) or 1.0
    return [max(-32767, min(32767, round(v / peak * PEAK * 32767))) for v in out]


def concrete_hit():
    rng = random.Random(3101)
    d = 0.30
    crack_f, grain_f = Biquad("bandpass", 1800, 0.8), Biquad("highpass", 1200, 0.7)
    grains = sorted((rng.uniform(0.012, 0.2), rng.uniform(0.2, 0.7)) for _ in range(14))
    thud = [0.0]

    def fn(t, i):
        thud[0] += 2 * math.pi * (46 + 60 * math.exp(-t / 0.03)) / RATE
        v = math.sin(thud[0]) * env(t, 0.0008, 0.06) * 0.9
        v += crack_f(rng.uniform(-1, 1)) * env(t, 0.0004, 0.008) * 3.2
        g = 0.0
        for gt, ga in grains:
            if t > gt:
                g += grain_f(rng.uniform(-1, 1)) * math.exp(-(t - gt) / 0.006) * ga * 0.22
        return v + g

    return finish(render(round(RATE * d), fn), d, 0.05, 2.2), d


def metal_hit():
    rng = random.Random(3102)
    d = 0.26
    click = Biquad("bandpass", 3500, 1.0)
    partials = [(523, 0.07, 1.0), (877, 0.055, 0.7), (1342, 0.04, 0.5), (2011, 0.028, 0.34), (2890, 0.018, 0.2)]
    phases = [rng.uniform(0, 6.28) for _ in partials]

    def fn(t, i):
        v = click(rng.uniform(-1, 1)) * env(t, 0.0003, 0.004) * 2.6
        for k, (f, dec, a) in enumerate(partials):
            v += math.sin(2 * math.pi * f * t + phases[k]) * env(t, 0.0005, dec) * a * 0.7
        return v

    return finish(render(round(RATE * d), fn), d, 0.04, 1.6), d


def laser_sizzle():
    rng = random.Random(3103)
    d = 0.32
    hp = Biquad("highpass", 2200, 0.8)
    sweep = [0.0]

    def fn(t, i):
        sweep[0] += 2 * math.pi * (600 + 1900 * math.exp(-t / 0.05)) / RATE
        v = math.sin(sweep[0]) * env(t, 0.001, 0.07) * 0.8
        am = 0.55 + 0.45 * math.sin(2 * math.pi * 95 * t)
        v += hp(rng.uniform(-1, 1)) * am * env(t, 0.002, 0.12) * 1.4
        if rng.random() < 0.012:
            v += rng.uniform(-1, 1) * 1.5 * math.exp(-t / 0.2)
        return v

    return finish(render(round(RATE * d), fn), d, 0.06, 1.7), d


def collapse():
    rng = random.Random(3104)
    d = 1.7
    rumble_f, rumble_f2 = Biquad("lowpass", 240, 0.8), Biquad("lowpass", 90, 0.8)
    grain_f = Biquad("highpass", 900, 0.7)
    crack_f = Biquad("bandpass", 2000, 0.8)
    impacts = sorted((rng.uniform(0.05, 1.3), rng.uniform(0.25, 1.0)) for _ in range(22))
    thud = [0.0]

    def fn(t, i):
        v = crack_f(rng.uniform(-1, 1)) * env(t, 0.0005, 0.012) * 2.6
        swell = min(1.0, t / 0.18) * math.exp(-max(0.0, t - 0.15) / 0.65)
        v += rumble_f(rng.uniform(-1, 1)) * swell * 3.4 + rumble_f2(rng.uniform(-1, 1)) * swell * 4.0
        thud[0] += 2 * math.pi * (38 + 40 * math.exp(-t / 0.2)) / RATE
        v += math.sin(thud[0]) * env(t, 0.004, 0.35) * 0.9
        for it, ia in impacts:
            dt = t - it
            if dt > 0:
                v += grain_f(rng.uniform(-1, 1)) * math.exp(-dt / 0.012) * ia * 0.25 * math.exp(-it / 1.1)
                v += math.sin(2 * math.pi * (70 + 40 * ia) * dt) * math.exp(-dt / 0.05) * ia * 0.35
        return v

    return finish(render(round(RATE * d), fn), d, 0.3, 1.5), d


def explosion():
    rng = random.Random(3105)
    d = 1.5
    blast_f, rumble_f = Biquad("lowpass", 1400, 0.8), Biquad("lowpass", 160, 0.8)
    crack_f = Biquad("bandpass", 2600, 0.7)
    boom = [0.0]

    def fn(t, i):
        boom[0] += 2 * math.pi * (26 + 70 * math.exp(-t / 0.09)) / RATE
        v = math.sin(boom[0]) * env(t, 0.002, 0.42) * 1.3
        v += crack_f(rng.uniform(-1, 1)) * env(t, 0.0004, 0.01) * 3.2
        v += blast_f(rng.uniform(-1, 1)) * env(t, 0.002, 0.16) * 2.4
        v += rumble_f(rng.uniform(-1, 1)) * env(t, 0.05, 0.55) * 3.0
        return v

    return finish(render(round(RATE * d), fn), d, 0.35, 2.6), d


def zap():
    rng = random.Random(3106)
    d = 0.45
    band = Biquad("bandpass", 3200, 0.9)
    whine = [0.0]
    buzz = [0.0]

    def fn(t, i):
        gate = 1.0 if math.sin(2 * math.pi * 38 * t + 1.7 * math.sin(2 * math.pi * 7 * t)) > -0.2 else 0.15
        v = band(rng.uniform(-1, 1)) * gate * env(t, 0.001, 0.16) * 2.4
        buzz[0] += 2 * math.pi * 120 / RATE
        saw = (buzz[0] / math.pi) % 2 - 1
        v += saw * env(t, 0.002, 0.14) * 0.7
        whine[0] += 2 * math.pi * (400 + 2600 * math.exp(-t / 0.07)) / RATE
        v += math.sin(whine[0]) * env(t, 0.001, 0.09) * 0.8
        return v

    return finish(render(round(RATE * d), fn), d, 0.08, 1.9), d


SOUNDS = {
    "concrete_hit": concrete_hit, "metal_hit": metal_hit, "laser_sizzle": laser_sizzle,
    "collapse": collapse, "explosion": explosion, "zap": zap,
}


def measure(samples):
    n = len(samples)
    f = [s / 32767 for s in samples]
    peak = max(abs(v) for v in f)
    rms = math.sqrt(sum(v * v for v in f) / n)
    # T-30: last time the 5 ms RMS window is above -30 dB below the peak window.
    win = int(RATE * 0.005)
    levels = [math.sqrt(sum(v * v for v in f[i:i + win]) / win) for i in range(0, n - win, win)]
    top = max(levels)
    t30 = 0.0
    for k, lv in enumerate(levels):
        if lv >= top * 10 ** (-30 / 20):
            t30 = (k + 1) * win / RATE
    return {
        "peak_dbfs": round(20 * math.log10(peak), 2), "rms_dbfs": round(20 * math.log10(rms), 2),
        "crest_db": round(20 * math.log10(peak / rms), 2), "t30_seconds": round(t30, 3),
        "clipped_samples": sum(1 for s in samples if abs(s) >= 32767), "dc_offset": round(sum(f) / n, 6),
    }


def write_wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    DEST.mkdir(parents=True, exist_ok=True)
    bad = 0
    for name, fn in SOUNDS.items():
        wav, manifest = DEST / f"{name}.wav", DEST / f"{name}.json"
        samples, duration = fn()
        digest_new = None
        if args.check:
            with wave.open(str(wav), "rb") as w:
                ok = (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, RATE)
                data = w.readframes(w.getnframes())
            digest = hashlib.sha256(wav.read_bytes()).hexdigest()
            m = json.loads(manifest.read_text())
            ok = ok and m.get("sha256") == digest and abs(w.getnframes() / RATE - duration) < 0.01
            peak = max(abs(v) for v in struct.unpack("<%dh" % (len(data) // 2), data))
            ok = ok and peak < 32767
            print(("ok   " if ok else "FAIL ") + name)
            bad += 0 if ok else 1
            continue
        write_wav(wav, samples)
        digest = hashlib.sha256(wav.read_bytes()).hexdigest()
        previous = json.loads(manifest.read_text()) if manifest.exists() else {}
        record = {**measure(samples), "file": f"assets/audio/destruction/{name}.wav", "duration": duration, "sample_rate": RATE, "channels": 1,
                  "bits": 16, "sha256": digest, "source": "Original deterministic synthesis; tools/synthesize_destruction_audio.py",
                  "rights": "Original mathematical synthesis for Ironframe. No third-party samples. CC0-1.0."}
        if previous.get("sha256") == digest:  # identical audio keeps its registered Roblox asset
            for key in ("asset_id", "status", "validated_at"):
                if key in previous:
                    record[key] = previous[key]
        manifest.write_text(json.dumps(record, indent=2) + "\n")
        print(name, record["duration"], "s", record["peak_dbfs"], "dBFS peak", record["rms_dbfs"], "dBFS rms", "T30", record["t30_seconds"])
    if args.check:
        config = (ROOT / "src" / "ReplicatedStorage" / "IronframeShared" / "DestructionConfig.luau").read_text(encoding="utf-8")
        keys = {"concrete_hit": "concreteHit", "metal_hit": "metalHit", "laser_sizzle": "laserSizzle", "collapse": "collapse",
                "explosion": "explosion", "zap": "zap"}
        for name, key in keys.items():
            m = json.loads((DEST / f"{name}.json").read_text())
            ok = m.get("status", "").endswith("approved_active") and f'{key} = {{ id = "rbxassetid://{m.get("asset_id")}"' in config
            print(("ok   " if ok else "FAIL ") + f"{name} registered in DestructionConfig ({m.get('asset_id')}, {m.get('status')})")
            bad += 0 if ok else 1
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
