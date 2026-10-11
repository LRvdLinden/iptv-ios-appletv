#!/usr/bin/env python3
"""Maakt de Bingr-intro-tune (±3,3 s), synchroon met de splash:
0–1,4 s  zachte 'whoosh' terwijl de covers vallen
1,5 s    diepe 'boem' + vijf heldere tonen, één per letter B-I-N-G-R (90 ms uit elkaar)
2,1 s    glanzend akkoord met sprankel (de glimveeg), uitsterven tot 3,3 s
Schrijft Shared/Resources/bingr_tune.m4a (via ffmpeg)."""
import numpy as np, subprocess, pathlib, wave
SR = 44100
T = 3.4
n = int(SR * T)
t = np.arange(n) / SR
L = np.zeros(n); R = np.zeros(n)

def env(start, attack, decay, length=None):
    e = np.zeros(n)
    s = int(start * SR)
    a = max(1, int(attack * SR))
    tail = int((length or decay * 6) * SR)
    idx = np.arange(min(n - s, a + tail))
    e[s:s + len(idx)] = np.where(idx < a, idx / a, np.exp(-(idx - a) / (decay * SR)))
    return e

def tone(freq, start, attack, decay, amp, harmonics=((1, 1.0), (2, 0.35), (3, 0.12)), detune=0.0):
    e = env(start, attack, decay)
    sig = sum(w * np.sin(2 * np.pi * freq * h * (1 + detune) * t) for h, w in harmonics)
    return amp * e * sig

rng = np.random.default_rng(7)
# 1. whoosh: gefilterde ruis die aanzwelt
noise = rng.standard_normal(n)
k = 400
smooth = np.convolve(noise, np.ones(k) / k, mode='same')
swell = np.clip((t - 0.1) / 1.3, 0, 1) ** 2 * (t < 1.55) + (t >= 1.55) * np.exp(-(t - 1.55) / 0.08)
wh = 2.2 * smooth * swell
L += wh * 0.9; R += wh * 1.1

# 2. boem (sinus die in toonhoogte zakt) op 1,50 s
s = 1.50
bt = np.clip(t - s, 0, None)
boom_f = 55 + 70 * np.exp(-bt / 0.06)
phase = 2 * np.pi * np.cumsum(boom_f) / SR
boom = np.sin(phase) * (t >= s) * np.exp(-bt / 0.45) * 0.9
L += boom; R += boom

# vijf letters: D5 F#5 A5 D6 E6 (eigen, opgewekt motief)
notes = [587.33, 739.99, 880.0, 1174.66, 1318.51]
for i, f in enumerate(notes):
    st = 1.52 + i * 0.09
    pan = 0.3 + 0.1 * i
    x = tone(f, st, 0.004, 0.16, 0.28, harmonics=((1, 1.0), (2, 0.25), (4, 0.08)))
    L += x * (1 - pan) * 1.4; R += x * pan * 1.4

# 3. akkoord (Dmaj9) met lichte detune = breed, op 2,08 s
chord = [146.83, 293.66, 369.99, 440.0, 554.37, 659.25]
for j, f in enumerate(chord):
    for d, side in ((-0.003, 'L'), (0.003, 'R')):
        x = tone(f, 2.08, 0.03, 0.55, 0.11 if f > 200 else 0.18, harmonics=((1, 1.0), (2, 0.4), (3, 0.15)), detune=d)
        if side == 'L': L += x
        else: R += x
# sprankel: korte hoge pingetjes tijdens de glimveeg
for i in range(14):
    st = 2.1 + i * 0.05 + rng.uniform(0, 0.02)
    f = rng.choice([2349.3, 2637.0, 2959.9, 3520.0])
    x = tone(f, st, 0.002, 0.07, 0.05 * (1 - i / 16), harmonics=((1, 1.0),))
    p = rng.uniform(0, 1)
    L += x * (1 - p); R += x * p

# uitfaden en normaliseren
fade = np.clip((T - t) / 0.5, 0, 1)
L *= fade; R *= fade
peak = max(np.abs(L).max(), np.abs(R).max())
L = np.tanh(L / peak * 1.2) * 0.85; R = np.tanh(R / peak * 1.2) * 0.85
pcm = (np.stack([L, R], axis=1) * 32767).astype('<i2')
root = pathlib.Path(__file__).resolve().parent.parent
wav = root / "tools" / "bingr_tune.wav"
with wave.open(str(wav), 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
out = root / "Shared" / "Resources" / "bingr_tune.m4a"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "aac", "-b:a", "160k", str(out)], check=True)
wav.unlink()
print(out, out.stat().st_size)
