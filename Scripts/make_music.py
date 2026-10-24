#!/usr/bin/env python3
"""Writes the soundtrack of the promotional video (Scripts/make_promo.swift runs it).

    python3 Scripts/make_music.py build/promo/cues.json build/promo/music.wav

An original, gentle track synthesized from scratch with numpy (no samples, nothing to license),
in the manner of a product film: a soft electric piano, a warm pad, a round bass, mallets with
an echo, and a quiet half-time beat, all in a large room. It follows the cut in cues.json: the
title over pad and piano, the beat entering when the window lands, a soft swell and a bell into
each chapter, a breath in the middle, and the closing resolving on the icon. Clicks, typed keys,
shortcuts and menu commands from the recording get faint interface sounds at their exact times.

D major at the cut's tempo (80 BPM): Gmaj9 A6/9 under the title, then the loop Dmaj9 Bm9 Gmaj9
A6/9 (every other time F#m7 in place of Bm9), and Gmaj9 A6/9 Dmaj9 at the end.
"""
import json
import sys
import wave

import numpy as np

SR = 48000
rng = np.random.default_rng(80)

cues = json.load(open(sys.argv[1]))
BEAT = 60 / cues["bpm"]
BAR = 4 * BEAT
EIGHTH = BEAT / 2
DUR = cues["duration"]
N = int(DUR * SR) + SR
DROP, OUTRO, FINALE = cues["drop"], cues["outro"], cues["finale"]
# Loudness of the main part, kept low: the music sits under the pictures.
TARGET_RMS_DB = -20.0


def midi(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def times(n):
    return np.arange(n) / SR


# MARK: Filters (zero-phase, in the frequency domain)

def response(f, kind, f1, f2=None, order=2):
    f = np.maximum(f, 1e-3)
    lp = lambda c: 1 / np.sqrt(1 + (f / c) ** (2 * order))
    hp = lambda c: 1 / np.sqrt(1 + (c / f) ** (2 * order))
    if kind == "lp":
        return lp(f1)
    if kind == "hp":
        return hp(f1)
    return hp(f1) * lp(f2)


def filtered(x, kind, f1, f2=None, order=2):
    n = x.shape[-1]
    size = 1 << int(np.ceil(np.log2(n + SR // 4)))
    spectrum = np.fft.rfft(x, size)
    spectrum *= response(np.fft.rfftfreq(size, 1 / SR), kind, f1, f2, order)
    return np.fft.irfft(spectrum, size)[..., :n]


def swept(x, kind, f1, f2=None, order=2, size=2048, hop=512):
    """Filters with cutoffs that change over time: f1 and f2 map times (s) to frequencies."""
    if x.ndim == 2:
        return np.vstack([swept(c, kind, f1, f2, order, size, hop) for c in x])
    padded = np.concatenate([np.zeros(size), x, np.zeros(size)])
    window = np.hanning(size + 1)[:-1]
    starts = np.arange(0, len(padded) - size, hop)
    frames = np.lib.stride_tricks.sliding_window_view(padded, size)[::hop][: len(starts)] * window
    centers = (starts + size / 2 - size) / SR
    freqs = np.fft.rfftfreq(size, 1 / SR)[None, :]
    gains = response(freqs, kind, f1(centers)[:, None], None if f2 is None else f2(centers)[:, None], order)
    out_frames = np.fft.irfft(np.fft.rfft(frames, axis=1) * gains, size, axis=1)
    out = np.zeros(len(padded))
    for start, frame in zip(starts, out_frames):
        out[start:start + size] += frame
    return out[size:size + len(x)] / (size / (2 * hop))


# MARK: Mixing

class Bus:
    def __init__(self):
        self.x = np.zeros((2, N))

    def add(self, signal, t, gain=1.0, pan=0.0):
        """Adds a mono or stereo signal starting at time t (s); pan from -1 (left) to 1 (right)."""
        if signal.ndim == 1:
            angle = (pan + 1) * np.pi / 4
            signal = np.vstack([signal * np.cos(angle), signal * np.sin(angle)]) * np.sqrt(2)
        i = int(round(t * SR))
        if i < 0:
            signal, i = signal[:, -i:], 0
        n = min(signal.shape[1], N - i)
        if n > 0:
            self.x[:, i:i + n] += gain * signal[:, :n]


def automation(points):
    """Piecewise-linear automation through (time, value) points, as a function of time arrays."""
    ts, vs = zip(*points)
    return lambda t: np.interp(t, ts, vs)


def exp_automation(points):
    """Like automation, but interpolated on a log scale (for cutoff frequencies)."""
    ts, vs = zip(*points)
    logs = np.log(vs)
    return lambda t: np.exp(np.interp(t, ts, logs))


def reverb_ir(seconds, predelay=0.035, damping=5000):
    n = int(seconds * SR)
    t = times(n)
    noise = rng.standard_normal((2, n)) * np.exp(-6.9 * t / seconds)
    # The tail darkens as it decays, like a real room.
    ir = filtered(noise, "lp", damping, order=1) * (1 - 0.6 * t / seconds) + filtered(noise, "lp", damping / 4, order=1) * 0.6 * t / seconds
    ir[:, : int(0.01 * SR)] *= np.linspace(0, 1, int(0.01 * SR))
    ir = np.concatenate([np.zeros((2, int(predelay * SR))), ir], axis=1)
    return ir / np.sqrt((ir ** 2).sum(axis=1, keepdims=True))


def convolve(x, ir):
    size = 1 << int(np.ceil(np.log2(x.shape[1] + ir.shape[1])))
    return np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[:, : x.shape[1]]


# MARK: Instruments

def electric_piano(note, velocity, length=3.6):
    """A soft FM electric piano: brighter as it is struck harder, mellowing as it rings."""
    n = int(length * SR)
    t = times(n)
    f = midi(note)
    out = np.zeros((2, n))
    for side, detune in ((0, 0.9993), (1, 1.0007)):
        ph = 2 * np.pi * f * detune * t
        index = velocity * (1.9 * np.exp(-t / 0.25) + 0.45)
        out[side] = np.sin(ph + index * np.sin(ph)) + 0.2 * velocity * np.sin(2 * ph) * np.exp(-t / 0.5)
    decay = 1.9 if f < 260 else 1.4 if f < 520 else 1.0
    envelope = (1 - np.exp(-t / 0.005)) * np.exp(-t / decay)
    envelope[-int(0.2 * SR):] *= np.linspace(1, 0, int(0.2 * SR))
    return out * envelope * velocity


def mallet(note, velocity):
    n = int(1.8 * SR)
    t = times(n)
    f = midi(note)
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.6)
    if 3.98 * f < 16000:
        y += 0.28 * np.sin(2 * np.pi * 3.98 * f * t) * np.exp(-t / 0.08)
    if 9.1 * f < 16000:
        y += 0.06 * np.sin(2 * np.pi * 9.1 * f * t) * np.exp(-t / 0.025)
    return y * (1 - np.exp(-t / 0.0015)) * velocity


def bell(note, length=3.0):
    n = int(length * SR)
    t = times(n)
    f = midi(note)
    partials = ((1, 1, 1.6), (2.0, 0.25, 0.9), (3.01, 0.12, 0.5), (4.16, 0.06, 0.3))
    y = sum(a * np.sin(2 * np.pi * f * m * t) * np.exp(-t / d) for m, a, d in partials if f * m < 16000)
    return y * (1 - np.exp(-t / 0.002))


def pad_chord(notes, length, attack=1.6, release=2.6):
    """Four slowly drifting sawtooth voices per note, low-passed to a warm haze."""
    n = int((length + release) * SR)
    t = times(n)
    out = np.zeros((2, n))
    for note in notes:
        for j, cents in enumerate([-9, -3, 3, 9]):
            drift = 1 + 0.0012 * np.sin(2 * np.pi * (0.17 + 0.05 * j) * t + j)
            phase = np.cumsum(midi(note) * 2 ** (cents / 1200) * drift) / SR + rng.random()
            voice = 2 * (phase % 1) - 1
            angle = (0.9 * (j - 1.5) / 1.5 + 1) * np.pi / 4
            out[0] += voice * np.cos(angle)
            out[1] += voice * np.sin(angle)
    out = filtered(out, "lp", 2600, order=2)
    envelope = (1 - np.exp(-t / (attack / 3))) * np.where(t < length, 1, np.exp(-(t - length) / (release / 5)))
    return out * envelope / (len(notes) * 4)


def bass_note(note, length):
    n = int((length + 0.35) * SR)
    t = times(n)
    f = midi(note)
    y = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
    held = np.where(t < length, np.exp(-t / 3), np.exp(-length / 3) * np.exp(-(t - length) / 0.07))
    return np.tanh(1.2 * y * (1 - np.exp(-t / 0.025)) * held) * 0.8


def kick_sound():
    n = int(0.45 * SR)
    t = times(n)
    f = 48 + 62 * np.exp(-t / 0.04)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.22)
    return filtered(np.tanh(1.2 * body), "hp", 30)


def snap_sound():
    n = int(0.3 * SR)
    t = times(n)
    noise = filtered(rng.standard_normal(n) * np.exp(-t / 0.022), "bp", 1600, 6000, order=2)
    body = np.sin(2 * np.pi * 330 * t) * np.exp(-t / 0.03) * 0.3
    return (noise / np.abs(noise).max() + body) * 0.7


def shaker_sound():
    n = int(0.18 * SR)
    t = times(n)
    y = filtered(rng.standard_normal(n), "bp", 5500, 13000, order=2) * (1 - np.exp(-t / 0.008)) * np.exp(-t / 0.045)
    return y / np.abs(y).max()


def tick(freq, decay, noise=0.3):
    n = int(0.05 * SR)
    t = times(n)
    burst = filtered(rng.standard_normal(n) * np.exp(-t / 0.0015), "bp", 1500, 5000) * noise
    return (burst + np.sin(2 * np.pi * freq * t) * np.exp(-t / decay)) * (1 - np.exp(-t / 0.0004))


def pop():
    n = int(0.12 * SR)
    t = times(n)
    f = 520 + 300 * np.minimum(1, t / 0.05)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.04) * (1 - np.exp(-t / 0.003))


def bloom(note, length=3.0):
    """A low swell that rises and settles, under a landing or the icon."""
    n = int(length * SR)
    t = times(n)
    y = np.sin(2 * np.pi * midi(note) * t) + 0.25 * np.sin(4 * np.pi * midi(note) * t)
    return y * (1 - np.exp(-t / 0.12)) * np.exp(-t / 0.9)


# MARK: Arrangement

DMAJ9 = (38, [54, 57, 61, 64])
BM9 = (35, [54, 57, 61, 62])
FSM7 = (42, [54, 57, 61, 64])
GMAJ9 = (43, [54, 57, 59, 62])
A69 = (45, [52, 54, 59, 61])
INTRO_CHORDS = [GMAJ9, A69]
LOOPS = [[DMAJ9, BM9, GMAJ9, A69], [DMAJ9, FSM7, GMAJ9, A69]]

drop_bar, outro_bar, finale_bar = round(DROP / BAR), round(OUTRO / BAR), round(FINALE / BAR)
groove = outro_bar - drop_bar
# A breath in the middle, on a phrase boundary: two bars without the beat and the bass.
breath = drop_bar + 4 * ((groove // 2) // 4) if groove >= 12 else None
in_breath = lambda b: breath is not None and breath <= b < breath + 2


def chord(b):
    if b < drop_bar:
        return INTRO_CHORDS[min(b, len(INTRO_CHORDS) - 1)]
    if b < outro_bar:
        i = b - drop_bar
        return LOOPS[(i // 4) % 2][i % 4]
    if b < finale_bar:
        return [GMAJ9, A69][min(b - outro_bar, 1)]
    return DMAJ9


def human(t, amount=0.006):
    return t + rng.uniform(-amount, amount)


pads, keys, mallets, basses, drums, fx, ui = Bus(), Bus(), Bus(), Bus(), Bus(), Bus(), Bus()

# Pad: every bar, the last chord held to the end.
for b in range(0, finale_bar):
    pads.add(pad_chord(chord(b)[1], BAR), b * BAR)
pads.add(pad_chord(DMAJ9[1] + [69], DUR - FINALE, attack=1.0, release=3.0), FINALE, gain=1.5)

# Electric piano: broken chords in eighths; sparser under the title, in the breath and at the end.
FLOWING = [(0, [0, 2], 0.5), (1.5, [3], 0.34), (2, [1], 0.32), (3, [2], 0.3), (4, [0, 3], 0.42), (5.5, [1], 0.28), (6, [2], 0.3), (7, [3], 0.26)]
SPARSE = [(0, [0, 1, 2, 3], 0.42), (4, [1, 3], 0.26), (6, [2], 0.2)]
for b in range(0, finale_bar):
    pattern = FLOWING if drop_bar <= b < outro_bar and not in_breath(b) else SPARSE
    voicing = chord(b)[1]
    for position, notes, velocity in pattern:
        for k, i in enumerate(notes):
            roll = 0.025 * k if len(notes) > 2 else 0
            keys.add(electric_piano(voicing[i] + 12, velocity * rng.uniform(0.92, 1.08)),
                     human(b * BAR + position * EIGHTH + roll), pan=-0.25 + 0.17 * i)
for k, note in enumerate(DMAJ9[1] + [69]):
    keys.add(electric_piano(note + 12, 0.6, length=6.0), FINALE + 0.04 * k, pan=-0.3 + 0.15 * k)

# Mallets with an echo, from the second phrase of the groove into the closing.
MALLET = [(1, 0), (2, 1), (3, 2), (5, 3), (6, 2), (7, 1)]
for b in range(drop_bar + 4, finale_bar):
    if in_breath(b):
        continue
    tones = [n + 24 for n in chord(b)[1]]
    for position, i in MALLET:
        mallets.add(mallet(tones[i], rng.uniform(0.75, 1.0)), human(b * BAR + position * EIGHTH), pan=0.35 if i % 2 else -0.35)

# Bass: the root on the beat and on the "and" of two, held through the breath.
for b in range(drop_bar, outro_bar):
    root = chord(b)[0]
    if in_breath(b):
        basses.add(bass_note(root, BAR * 0.95), b * BAR, gain=0.7)
        continue
    basses.add(bass_note(root, BEAT * 1.4), b * BAR)
    basses.add(bass_note(root, BEAT * 2.3), b * BAR + 3 * EIGHTH, gain=0.85)
basses.add(bass_note(38, 5.0), FINALE, gain=0.9)

# A quiet half-time beat: kick on one and the "and" of two, a snap on three, shaker eighths.
kick, snap, shaker = kick_sound(), snap_sound(), shaker_sound()
kicks = []
for b in range(drop_bar, outro_bar):
    if in_breath(b):
        continue
    start = b * BAR
    for position, gain in ((0, 0.8), (3, 0.5)):
        drums.add(kick, start + position * EIGHTH, gain=gain)
        kicks.append(start + position * EIGHTH)
    if b >= drop_bar + 2:
        drums.add(snap, human(start + 4 * EIGHTH, 0.004), gain=0.32, pan=0.1)
    for i in range(8):
        drums.add(shaker, human(start + i * EIGHTH + (0.02 if i % 2 else 0), 0.004), gain=0.28 if i % 2 else 0.15, pan=0.3)

# Moments: the icon, the landing, each chapter, the closing.
swell_ir = reverb_ir(1.6, predelay=0.0, damping=7000)


def swell(notes, end, length=1.5):
    """Reversed echoes of a chord, rising into `end`."""
    n = int(length * SR)
    dry = np.zeros((2, n))
    for k, note in enumerate(notes):
        tone = mallet(note, 0.8)[: n // 3]
        at = int(k * 0.03 * SR)
        dry[:, at:at + len(tone)] += tone
    wet = convolve(dry, swell_ir)[:, ::-1] * np.linspace(0, 1, n) ** 1.5
    fx.add(wet / (np.abs(wet).max() + 1e-9), end - length, gain=0.22)


for k, note in enumerate([74, 78, 81, 86]):
    fx.add(bell(note), cues["logo"] + 0.09 * k, gain=0.13, pan=-0.3 + 0.2 * k)
fx.add(bloom(38, 3.0), cues["logo"] - 0.05, gain=0.22)
swell([69, 74, 78], DROP)
fx.add(bloom(38, 3.5), DROP - 0.2, gain=0.3)
for k, note in enumerate([81, 85, 88]):
    fx.add(bell(note), DROP + 0.07 * k, gain=0.08, pan=0.25 - 0.25 * k)
for k, t in enumerate(cues["scenes"][1:]):
    voicing = chord(int(t / BAR))[1]
    swell([n + 24 for n in voicing[1:]], t)
    fx.add(bell(voicing[k % 4] + 24, 2.5), t, gain=0.07, pan=0.3 if k % 2 else -0.3)
swell([69, 74, 78, 81], FINALE, length=2.0)
fx.add(bloom(38, 4.0), FINALE - 0.1, gain=0.3)
for k, note in enumerate([81, 86, 90]):
    fx.add(bell(note, 4.0), FINALE + 0.4 + 0.12 * k, gain=0.07, pan=-0.2 + 0.2 * k)

# Interface sounds, faint, where the recording clicks and types.
for t in cues["clicks"]:
    ui.add(tick(1400, 0.012), t, gain=0.09, pan=0.1)
for t in cues["typing"]:
    ui.add(tick(2200, 0.006, 0.2), t, gain=0.05, pan=-0.1)
for t in cues["shortcuts"]:
    ui.add(tick(1100, 0.02), t, gain=0.07)
    ui.add(tick(1100, 0.02), t + 0.07, gain=0.05)
for t in cues["menus"]:
    ui.add(pop(), t, gain=0.07)
for t in cues["appearance"]:
    for k, note in enumerate([86, 90, 93]):
        ui.add(bell(note, 1.6), t + 0.06 * k, gain=0.035, pan=-0.3 + 0.3 * k)

# MARK: Mix

t_all = times(N)
# A light duck of the bass under each kick keeps the low end clear without pumping.
duck = np.zeros(N)
for t in sorted(kicks):
    i = int(t * SR)
    n = min(int(BEAT * SR), N - i)
    duck[i:i + n] = np.maximum(duck[i:i + n], np.exp(-np.arange(n) / SR / 0.12))

breath_points = [(breath * BAR, 2600), (breath * BAR + 1.0, 1500), ((breath + 2) * BAR - 0.5, 2600)] if breath else []
pad_cutoff = exp_automation([(0, 500), (DROP, 2600)] + breath_points + [(OUTRO, 2600), (OUTRO + BAR, 1500), (FINALE, 3200), (DUR, 1200)])
# The pad's tone drifts slowly.
pads.x = swept(pads.x, "lp", lambda t: pad_cutoff(t) * (1 + 0.15 * np.sin(2 * np.pi * t / 11)), order=1)
pads.x *= automation([(0, 0), (3.0, 1.5), (DROP, 1.5), (DROP + 0.01, 0.8), (OUTRO, 0.8), (OUTRO + BAR, 1.1), (DUR, 1.1)])(t_all)
basses.x = filtered(basses.x * (1 - 0.18 * duck), "lp", 500, order=2)
keys.x = filtered(keys.x, "lp", 9000, order=1)

# A dotted-eighth ping-pong echo on the mallets.
echo = np.zeros_like(mallets.x)
step = int(1.5 * EIGHTH * SR)
for k in range(1, 6):
    shifted = np.zeros(N)
    shifted[step * k:] = mallets.x.mean(axis=0)[: N - step * k]
    echo[k % 2] += shifted * 0.4 ** k
mallets.x += filtered(echo, "bp", 500, 6000, order=1)

hall = reverb_ir(3.6, damping=8000)
wet = convolve(0.24 * pads.x + 0.3 * keys.x + 0.45 * mallets.x + 0.5 * fx.x + 0.3 * ui.x + 0.4 * drums.x, hall)

mix = (0.55 * pads.x + 0.62 * keys.x + 0.6 * mallets.x + 0.5 * basses.x + 0.55 * drums.x
       + 0.55 * fx.x + 0.8 * ui.x + 0.42 * wet)
mix = filtered(mix, "hp", 32, order=2)
# Air above 5 kHz, a little less weight around 200 Hz.
size = 1 << int(np.ceil(np.log2(N)))
f = np.fft.rfftfreq(size, 1 / SR)
tilt = 6 * (f / 3500) ** 2 / (1 + (f / 3500) ** 2) - 2 * np.exp(-np.log(np.maximum(f, 1) / 200) ** 2 / 0.5)
mix = np.fft.irfft(np.fft.rfft(mix, size) * 10 ** (tilt / 20), size)[:, :N]

# Quiet: about -20 dBFS RMS through the chapters, gently limited, peaks at most -3 dBFS.
main = mix[:, int(DROP * SR):int(OUTRO * SR)]
mix *= 10 ** (TARGET_RMS_DB / 20) / (np.sqrt((main ** 2).mean()) + 1e-9)
mix = np.tanh(mix * 1.4) / 1.4
fade = np.clip((DUR - t_all) / 1.6, 0, 1) * np.clip(t_all / 0.05, 0, 1)
mix = (mix * fade)[:, : int(DUR * SR)]
peak = np.abs(mix).max()
if peak > 10 ** (-3 / 20):
    mix *= 10 ** (-3 / 20) / peak

pcm = (np.clip(mix.T, -1, 1) * 32767).astype("<i2")
with wave.open(sys.argv[2], "wb") as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(SR)
    out.writeframes(pcm.tobytes())
print(f"wrote {sys.argv[2]} ({DUR:.1f} s at {cues['bpm']:.0f} BPM, breath at bar {breath}, {len(cues['clicks'])} clicks)")
