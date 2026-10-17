"""Original HMG-20 Mauler heavy-autocannon sound design. Standard library only; no recorded or third-party samples.

  python tools/synthesize_mauler_audio.py            render candidates A/B/C, score them, write the winner
  python tools/synthesize_mauler_audio.py --check    validate the committed WAV only (no rewrite)

Layers (all mathematical): a 2 ms filtered-noise crack, a falling-sine receiver slam, a low pressure/body sweep,
inharmonic metallic ring partials, a lowpassed muzzle-blast tail and a quiet bolt-return tick at ~0.19 s. Three
candidates differ in body/crack balance and seed; the winner is the candidate whose objective signal measurements
land closest to the target profile (it is NOT a listening verdict - see docs/M08D_HEAVY_AUTOCANNON.md).
"""
import argparse
import cmath
import hashlib
import json
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets" / "audio"
WAV = DEST / "mauler_discharge.wav"
MANIFEST = DEST / "mauler_discharge.json"
RATE = 44100
DURATION = 0.62
PEAK = 0.708  # -3 dBFS

# name: (seed, crack, slam, body, ring, blast, tick, saturation)
CANDIDATES = {
    "A": dict(seed=2020, crack=0.55, slam=0.80, body=0.95, ring=0.30, blast=0.50, tick=0.10, drive=3.2),
    "B": dict(seed=2021, crack=0.45, slam=0.70, body=1.30, ring=0.26, blast=0.60, tick=0.09, drive=2.8),
    "C": dict(seed=2022, crack=0.80, slam=0.85, body=0.85, ring=0.38, blast=0.42, tick=0.12, drive=3.6),
}


class Biquad:
    """RBJ biquad; kind in lowpass/highpass/bandpass."""

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


def synthesize(p):
    rng = random.Random(p["seed"])
    n = round(RATE * DURATION)
    crack_f = Biquad("bandpass", 2800, 0.7)
    crack_f2 = Biquad("bandpass", 1400, 0.8)
    blast_f = Biquad("lowpass", 1500, 0.8)
    blast_f2 = Biquad("highpass", 160, 0.7)
    air_f = Biquad("highpass", 38, 0.7)
    soft = Biquad("lowpass", 7800, 0.7)  # keep ultrasonic/harsh air out; the sound should be heavy, not hissy
    ring_partials = [(412, 0.060), (709, 0.045), (1163, 0.030), (1688, 0.022)]  # inharmonic steel plate ring
    body_phase = slam_phase = tick_phase = 0.0
    ring_phase = [rng.uniform(0, 2 * math.pi) for _ in ring_partials]
    out = []
    for i in range(n):
        t = i / RATE
        attack = min(1.0, t / 0.0006)  # 0.6 ms de-click
        n1 = rng.uniform(-1, 1)
        crack = (crack_f(n1) * math.exp(-t / 0.0045) + 0.8 * crack_f2(n1) * math.exp(-t / 0.012)) * p["crack"] * 5.0
        slam_f = 66 + 175 * math.exp(-t / 0.018)
        slam_phase += 2 * math.pi * slam_f / RATE
        slam = math.sin(slam_phase) * math.exp(-t / 0.050) * p["slam"]
        body_f = 44 + 54 * math.exp(-t / 0.060)
        body_phase += 2 * math.pi * body_f / RATE
        body = (math.sin(body_phase) + 0.25 * math.sin(2 * body_phase)) * math.exp(-t / 0.115) * 0.5 * p["body"]
        ring = 0.0
        for k, (freq, decay) in enumerate(ring_partials):
            ring += math.sin(2 * math.pi * freq * t + ring_phase[k]) * math.exp(-t / decay) * (0.55 - 0.1 * k)
        ring *= p["ring"] * min(1.0, t / 0.002)
        blast = blast_f2(blast_f(rng.uniform(-1, 1))) * math.exp(-t / 0.075) * p["blast"] * 3.0
        tick_t = t - 0.19
        tick = 0.0
        if tick_t > 0:
            tick_phase += 2 * math.pi * 1500 / RATE
            tick = math.sin(tick_phase) * math.exp(-tick_t / 0.006) * p["tick"] * min(1.0, tick_t / 0.0004)
        value = (crack + slam + body + ring + blast + tick) * attack
        # soft knee saturation to round the crack; no hard clipping.
        value = math.tanh(value * p["drive"]) / math.tanh(p["drive"])
        value = soft(air_f(value))
        release = min(1.0, max(0.0, (DURATION - t) / 0.06)) ** 2
        out.append(value * release)
    peak = max(abs(v) for v in out)
    return [max(-32767, min(32767, round(v / peak * PEAK * 32767))) for v in out]


def fft(values):
    n = len(values)
    j = 0
    a = list(values)
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    length = 2
    while length <= n:
        w = cmath.exp(-2j * math.pi / length)
        for start in range(0, n, length):
            wn = 1
            for k in range(length // 2):
                u, v = a[start + k], a[start + k + length // 2] * wn
                a[start + k], a[start + k + length // 2] = u + v, u - v
                wn *= w
        length <<= 1
    return a


def a_weight(f):
    """Linear IEC A-weighting gain; approximates loudness rather than raw spectral power."""
    if f < 10:
        return 0.0
    f2 = f * f
    return 12194 ** 2 * f2 * f2 / ((f2 + 20.6 ** 2) * math.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2)) * (f2 + 12194 ** 2)) / 0.7943


def measure(values):
    """Objective measurements. Band shares/centroid use an A-weighted Hann-windowed FFT of the whole (zero-padded) clip."""
    n = len(values)
    peak = max(abs(v) for v in values) / 32768
    rms = math.sqrt(sum(v * v for v in values) / n) / 32768
    size = 1 << (n - 1).bit_length()
    windowed = [values[i] / 32768 * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) for i in range(n)] + [0.0] * (size - n)
    spec = fft(windowed)
    hz = RATE / size
    raw = [abs(spec[k]) ** 2 for k in range(size // 2)]
    weighted = [raw[k] * a_weight(k * hz) ** 2 for k in range(size // 2)]
    total_raw, total_a = sum(raw) or 1.0, sum(weighted) or 1.0

    def band(lo, hi, power=raw, total=total_raw):
        return sum(power[k] for k in range(int(lo / hz), min(len(power), int(hi / hz) + 1))) / total

    centroid = sum(k * hz * weighted[k] for k in range(len(weighted))) / total_a
    # Time for the short-term envelope (5 ms RMS) to fall 30 dB below its maximum, measured after the peak.
    win = int(RATE * 0.005)
    env = [math.sqrt(sum(v * v for v in values[i:i + win]) / win) / 32768 for i in range(0, n - win, win)]
    top = max(env)
    top_i = env.index(top)
    t30 = next(((i - top_i) * win / RATE for i in range(top_i, len(env)) if env[i] < top * 10 ** (-30 / 20)), DURATION)
    return {
        "peak_dbfs": round(20 * math.log10(peak), 2),
        "rms_dbfs": round(20 * math.log10(rms), 2),
        "crest_db": round(20 * math.log10(peak / rms), 2),
        "centroid_a_hz": round(centroid),
        "sub40_share": round(band(0, 40), 4),
        "low_40_200_share": round(band(40, 200), 4),
        "mid_200_2k_share": round(band(200, 2000), 4),
        "high_2k_plus_share_a": round(band(2000, RATE / 2, weighted, total_a), 4),
        "t30_seconds": round(t30, 3),
        "clipped_samples": sum(1 for v in values if abs(v) >= 32767),
        "dc_offset": round(abs(sum(values) / n) / 32768, 6),
    }


# Target profile for a heavy, controlled cannon: strong body, audible crack, no sub-bass flood, brief decay.
TARGETS = {"rms_dbfs": (-16.5, 2.5), "crest_db": (13.5, 3.0), "centroid_a_hz": (1100, 350), "sub40_share": (0.002, 0.01),
           "low_40_200_share": (0.78, 0.12), "high_2k_plus_share_a": (0.12, 0.08), "t30_seconds": (0.24, 0.10)}


def score(m):
    """Lower is better: sum of squared normalized distances to the target profile; hard fails dominate."""
    if m["clipped_samples"] or m["dc_offset"] > 0.003 or m["sub40_share"] > 0.05:
        return 1e9
    return sum(((m[k] - mid) / width) ** 2 for k, (mid, width) in TARGETS.items())


def write_wav(path, values):
    with wave.open(str(path), "wb") as wav:
        wav.setparams((1, 2, RATE, len(values), "NONE", "not compressed"))
        wav.writeframes(struct.pack("<" + "h" * len(values), *values))


def read_wav(path):
    with wave.open(str(path), "rb") as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == RATE
        assert wav.getcomptype() == "NONE"
        return list(struct.unpack("<" + "h" * wav.getnframes(), wav.readframes(wav.getnframes())))


def check(path):
    values = read_wav(path)
    assert len(values) == round(RATE * DURATION)
    m = measure(values)
    assert -3.5 < m["peak_dbfs"] < -2.5 and m["clipped_samples"] == 0 and m["dc_offset"] < 0.003
    assert abs(values[0]) < 10 and max(abs(v) for v in values[-44:]) < 100, "clean endpoints"
    assert m["sub40_share"] < 0.05, "excess sub-bass"
    assert m["rms_dbfs"] > -18.44, "must be louder in RMS than the LR-12 clip"
    m.update({"file": str(path.relative_to(ROOT)).replace("\\", "/"), "duration": len(values) / RATE, "sample_rate": RATE,
              "channels": 1, "bits": 16, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    return m


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        print(json.dumps(check(WAV), indent=2))
        return
    DEST.mkdir(parents=True, exist_ok=True)
    renders = {name: synthesize(params) for name, params in CANDIDATES.items()}
    report = {}
    for name, values in renders.items():
        m = measure(values)
        report[name] = {"score": round(score(m), 3), **m}
        write_wav(DEST / f"mauler_candidate_{name}.wav.tmp", values)  # inspection copies are not kept
        (DEST / f"mauler_candidate_{name}.wav.tmp").unlink()
    winner = min(report, key=lambda k: report[k]["score"])
    write_wav(WAV, renders[winner])
    info = check(WAV)
    existing = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {}
    keep_id = existing.get("asset_id") if existing.get("sha256") == info["sha256"] else None
    info.update({"asset_id": keep_id, "status": existing.get("status") if keep_id else "awaiting_upload",
                 "selected_candidate": winner, "candidates": report,
                 "source": "Original deterministic synthesis; tools/synthesize_mauler_audio.py; seeds 2020-2022",
                 "rights": "Original mathematical synthesis for Ironframe. No third-party samples. CC0-1.0."})
    if keep_id:
        info["validated_at"] = existing.get("validated_at")
    MANIFEST.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"winner": winner, "candidates": report}, indent=2))


if __name__ == "__main__":
    main()
