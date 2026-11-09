#!/usr/bin/env python3
"""Generates Borne's UI sounds (original, synthesized: no third-party samples).

    python3 scripts/assets/make_sounds.py ui/sounds

One folder per sound set, each with move.wav, accept.wav and back.wav (mono, 44.1 kHz, 16-bit).
The look picks a set by name (Theme.soundSet).
"""
import math, os, struct, sys, wave

RATE = 44100

def tone(freqs, ms, shape="sine", attack=4, decay=None, volume=0.35, glide=0.0):
    n = int(RATE * ms / 1000)
    decay = decay if decay is not None else ms
    out = []
    phase = [0.0] * len(freqs)
    for i in range(n):
        t = i / RATE
        env = min(1.0, t * 1000 / attack) * math.exp(-t * 1000 / decay * 3)
        s = 0.0
        for k, f in enumerate(freqs):
            f = f * (1 + glide * t * 1000 / ms)
            phase[k] += 2 * math.pi * f / RATE
            if shape == "square":
                s += 1.0 if math.sin(phase[k]) >= 0 else -1.0
            elif shape == "triangle":
                s += 2 / math.pi * math.asin(math.sin(phase[k]))
            else:
                s += math.sin(phase[k])
        out.append(s / len(freqs) * env * volume)
    # Short fade-out against clicks.
    for i in range(min(200, n)):
        out[n - 1 - i] *= i / 200
    return out

def concat(*parts):
    return [x for p in parts for x in p]

SETS = {
    # Light and quick: the sounds of the Halo look.
    "soft": {
        "move": tone([1760], 35, "sine", attack=1, decay=18, volume=0.22),
        "accept": concat(tone([1320], 45, "sine", decay=30, volume=0.25), tone([1760], 70, "sine", decay=50, volume=0.25)),
        "back": concat(tone([1320], 45, "sine", decay=30, volume=0.22), tone([990], 70, "sine", decay=50, volume=0.22)),
    },
}

def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))

root = sys.argv[1]
for name, sounds in SETS.items():
    os.makedirs(os.path.join(root, name), exist_ok=True)
    for kind, samples in sounds.items():
        write(os.path.join(root, name, f"{kind}.wav"), samples)
print("ok")
