"""Soundtrack for the Shift release film: a 120 BPM track plus sound design on the cues the film exports.

python3 audio.py cues.json out.wav
"""
import json
import struct
import sys

import numpy as np

SR = 48000
LENGTH = 60.0
N = int(SR * LENGTH)
BEAT = 0.5
rng = np.random.default_rng(11)

mix = np.zeros((N, 2))
music = np.zeros((N, 2))  # pads, bass and plucks: ducked under the kick
verb_send = np.zeros((N, 2))
delay_send = np.zeros((N, 2))
duck = np.ones(N)  # sidechain gain for pads and bass


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(dur):
    return np.arange(int(dur * SR)) / SR


def place(buf, start, sig, pan=0.0, gain=1.0, send=0.0, dsend=0.0):
    """Adds a mono or stereo signal at time start, with equal-power pan and reverb/delay sends."""
    i = int(round(start * SR))
    if i >= N or len(sig) == 0:
        return
    if sig.ndim == 1:
        a = (pan + 1) * np.pi / 4
        sig = np.stack([sig * np.cos(a), sig * np.sin(a)], axis=1) * np.sqrt(2)
    j = min(N, i + len(sig))
    if i < 0:
        sig, i = sig[-i:], 0
    seg = sig[: j - i] * gain
    buf[i:j] += seg
    if send:
        verb_send[i:j] += seg * send
    if dsend:
        delay_send[i:j] += seg * dsend


def fft_filter(x, lo=None, hi=None, order=2):
    """Zero-phase Butterworth-shaped filter in the frequency domain."""
    n = len(x)
    X = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(n, 1 / SR)
    H = np.ones_like(f)
    if hi:
        H *= 1 / np.sqrt(1 + (f / hi) ** (2 * order))
    if lo:
        H *= 1 / np.sqrt(1 + (lo / np.maximum(f, 1e-3)) ** (2 * order))
    if x.ndim == 2:
        H = H[:, None]
    return np.fft.irfft(X * H, n=n, axis=0)


def sweep_filter(x, lo_curve=None, hi_curve=None, block=2048):
    """Time-varying filter: overlap-added blocks, each filtered with the cutoff at its centre."""
    out = np.zeros_like(x)
    win = np.hanning(block)
    hop = block // 2
    for s in range(0, len(x) - block + 1, hop):
        c = (s + hop) / len(x)
        y = fft_filter(x[s:s + block] * win, lo=lo_curve(c) if lo_curve else None, hi=hi_curve(c) if hi_curve else None)
        out[s:s + block] += y
    return out


def env(n, attack=0.005, decay=0.2, sustain=0.0, release=0.05, hold=None):
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = sustain + (1 - sustain) * np.exp(-np.maximum(t - attack, 0) / max(decay, 1e-4))
    e = a * d
    if hold is not None:
        r = np.clip(1 - (t - hold) / release, 0, 1)
        e *= np.where(t > hold, r, 1)
    return e


def saw(freq, dur, fc=4000, detune=0.0, bright_decay=0.0, phase=0.0):
    """Band-limited saw by additive synthesis; harmonics above fc roll off, optionally decaying faster (pluck)."""
    t = tt(dur)
    f = freq * 2 ** (detune / 1200)
    out = np.zeros_like(t)
    k = 1
    while k * f < min(fc * 3, SR / 2 - 1000):
        w = 1 / k / np.sqrt(1 + (k * f / fc) ** 4)
        h = np.sin(2 * np.pi * k * f * t + phase * k) * w
        if bright_decay:
            h *= np.exp(-t * bright_decay * (k - 1) * 0.35)
        out += h
        k += 1
    return out * 0.6


def noise(dur):
    return rng.standard_normal(int(dur * SR))


# ---------- instruments ----------
def kick(t0, gain=1.0, dur=0.5):
    t = tt(dur)
    f = 44 + 120 * np.exp(-t * 30)
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t * 6.5)
    click = fft_filter(noise(0.008), lo=2500) * 0.7
    body[: len(click)] += click
    sig = np.tanh(body * 1.8) * 0.9
    place(mix, t0, sig, gain=gain * 0.72)
    i = int(t0 * SR)
    j = min(N, i + int(0.35 * SR))
    dt = np.arange(j - i) / SR
    duck[i:j] = np.minimum(duck[i:j], 1 - 0.62 * np.exp(-dt / 0.11))


def clap(t0, gain=1.0):
    n = noise(0.25)
    e = np.zeros_like(n)
    for k, off in enumerate([0, 0.011, 0.023]):
        i = int(off * SR)
        e[i:] += np.exp(-np.arange(len(n) - i) / SR / (0.012 if k < 2 else 0.09))
    sig = fft_filter(n * e, lo=900, hi=5000) * 0.45
    body = np.sin(2 * np.pi * 185 * tt(0.25)) * np.exp(-tt(0.25) * 30) * 0.3
    place(mix, t0, sig + body, pan=0.05, gain=gain * 1.4, send=0.25)


def hat(t0, gain=1.0, open_=False, pan=0.25):
    d = 0.22 if open_ else 0.05
    n = fft_filter(noise(d + 0.02), lo=7000)
    sig = n * env(len(n), 0.001, d / 2.5)
    place(mix, t0, sig * 0.36, pan=pan, gain=gain, send=0.05)


def bass(t0, note, dur, gain=1.0):
    s = saw(midi(note), dur + 0.03, fc=520) + np.sin(2 * np.pi * midi(note) * tt(dur + 0.03)) * 0.7
    e = env(len(s), 0.004, 0.25, 0.55, 0.03, hold=dur)
    place(music, t0, np.tanh(s * e * 1.4) * 0.5, gain=gain * 0.62)


def pad(t0, notes, dur, gain=1.0, fc=1800, attack=0.5):
    total = None
    for m in notes:
        for det, ph in [(-7, 0.3), (0, 1.1), (7, 2.0)]:
            s = saw(midi(m), dur + 1.0, fc=fc, detune=det, phase=ph)
            total = s if total is None else total + s
    e = env(len(total), attack, 10, 1, 0.9, hold=dur)
    sig = total * e / (len(notes) * 3) * 0.9
    stereo = np.stack([sig, np.roll(sig, 240)], axis=1)
    place(music, t0, stereo, gain=gain * 1.7, send=0.35)


def pluck(t0, note, gain=1.0, pan=0.0, dsend=0.3, send=0.25):
    s = saw(midi(note), 0.6, fc=3200, bright_decay=9)
    s = s * env(len(s), 0.002, 0.16)
    place(music, t0, s * 0.5, pan=pan, gain=gain * 1.5, send=send, dsend=dsend)


def bell(t0, note, gain=1.0):
    t = tt(2.5)
    f = midi(note)
    mod = np.sin(2 * np.pi * f * 3.5 * t) * 2.2 * np.exp(-t * 3)
    s = np.sin(2 * np.pi * f * t + mod) * np.exp(-t * 1.6) * 0.35
    place(mix, t0, s, gain=gain, send=0.7)


# ---------- sound design ----------
def sfx_hit(t0, gain=1.0, heavy=False):
    t = tt(0.6)
    f = 55 + 90 * np.exp(-t * 18)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * (5 if heavy else 8))
    crack = fft_filter(noise(0.6), lo=300, hi=6000) * np.exp(-t * 22) * 0.6
    sig = np.tanh((boom + crack) * (2.4 if heavy else 1.8)) * 0.6
    place(mix, t0, sig, gain=gain, send=0.2)


def sfx_glitch(t0, gain=1.0):
    d = 0.09
    t = tt(d)
    sq = np.sign(np.sin(2 * np.pi * rng.uniform(300, 1800) * t * (1 + 4 * t)))
    n = noise(d)
    crushed = np.round((sq * 0.5 + n * 0.5) * 4) / 4
    gate = (np.floor(t * rng.uniform(60, 140)) % 2 == 0).astype(float)
    sig = fft_filter(crushed * gate, lo=500, hi=7000) * env(len(t), 0.001, 0.05) * 0.22
    place(mix, t0, sig, pan=rng.uniform(-0.7, 0.7), gain=gain)


def sfx_riser(t0, dur, gain=1.0):
    n = noise(dur)
    sig = sweep_filter(n, lo_curve=lambda c: 200 + 2500 * c ** 2, hi_curve=lambda c: 800 + 9000 * c ** 2)
    t = tt(dur)
    tone = np.sin(2 * np.pi * np.cumsum(180 * 2 ** (t * 2.6 / dur)) / SR) * 0.25
    e = (t / dur) ** 2.2
    place(mix, t0, (sig * 0.35 + tone) * e, gain=gain, send=0.3)


def sfx_whoosh(t0, dur=0.6, gain=1.0, up=False):
    n = noise(dur)
    lo = (lambda c: 300 + 2500 * c) if up else (lambda c: 400 + 2200 * np.sin(np.pi * c))
    sig = sweep_filter(n, lo_curve=lo, hi_curve=lambda c: lo(c) * 3 + 500)
    t = tt(dur)
    e = (t / dur) ** 2 if up else np.sin(np.pi * t / dur) ** 2
    s = sig * e * 0.5
    stereo = np.stack([s * np.linspace(1.2, 0.4, len(s)), s * np.linspace(0.4, 1.2, len(s))], axis=1)
    place(mix, t0, stereo, gain=gain, send=0.3)


def sfx_impact(t0, gain=1.0):
    t = tt(3.0)
    f = 52 * np.exp(-t * 0.9) + 26
    sub = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 1.4)
    crash = fft_filter(noise(3.0), lo=200, hi=7000) * np.exp(-t * 2.6) * 0.45
    thump = np.tanh(np.sin(2 * np.pi * np.cumsum(60 + 140 * np.exp(-t * 25)) / SR) * np.exp(-t * 7) * 3) * 0.6
    place(mix, t0, (sub * 0.55 + crash * 1.3 + thump) * 0.8, gain=gain, send=0.55)


def sfx_click(t0, gain=1.0):
    d = 0.03
    s = fft_filter(noise(d), lo=2000, hi=9000) * env(int(d * SR), 0.0005, 0.004) * 0.5
    s += np.sin(2 * np.pi * 2300 * tt(d)) * np.exp(-tt(d) * 300) * 0.25
    place(mix, t0, s, pan=0.1, gain=gain * 0.8)


def sfx_key(t0, gain=1.0):
    d = 0.09
    s = fft_filter(noise(d), lo=500, hi=3500) * env(int(d * SR), 0.0008, 0.012) * 0.7
    s += np.sin(2 * np.pi * 140 * tt(d)) * np.exp(-tt(d) * 45) * 0.5
    place(mix, t0, s, gain=gain * 0.9, send=0.1)


def sfx_tick(t0, gain=1.0):
    d = 0.04
    s = np.sin(2 * np.pi * 3100 * tt(d)) * np.exp(-tt(d) * 120) * 0.2
    place(mix, t0, s, pan=-0.1, gain=gain, send=0.15)


def sfx_drop(t0, gain=1.0):
    d = 0.25
    t = tt(d)
    s = np.sin(2 * np.pi * np.cumsum(520 + 500 * (1 - np.exp(-t * 30))) / SR) * np.exp(-t * 22) * 0.3
    s += np.sin(2 * np.pi * np.cumsum(120 * np.exp(-t * 10) + 60) / SR) * np.exp(-t * 18) * 0.5
    place(mix, t0, s, gain=gain, send=0.25)


def sfx_done(t0, gain=1.0):
    for k, (note, off) in enumerate([(88, 0), (95, 0.09)]):
        t = tt(1.0)
        s = np.sin(2 * np.pi * midi(note) * t) * np.exp(-t * 5) * 0.16
        place(mix, t0 + off, s, pan=-0.2 + 0.4 * k, gain=gain, send=0.5)


def sfx_pop(t0, gain=1.0):
    d = 0.12
    t = tt(d)
    s = np.sin(2 * np.pi * np.cumsum(380 + 900 * (1 - np.exp(-t * 60))) / SR) * np.exp(-t * 38) * 0.32
    place(mix, t0, s, pan=rng.uniform(-0.3, 0.3), gain=gain, send=0.2)


def sfx_type(t0, gain=1.0):
    d = 0.03
    s = fft_filter(noise(d), lo=rng.uniform(1500, 3000), hi=8000) * env(int(d * SR), 0.0004, 0.005) * 0.4
    place(mix, t0, s, pan=rng.uniform(-0.3, 0.3), gain=gain)


def sfx_count(t0, gain=1.0):
    ts, x = [], 0.0
    while x < 1.0:
        ts.append(x)
        x += 0.03 + 0.12 * x ** 2
    for x in ts:
        sfx_tick(t0 + x, gain * 0.5 * (1 - x * 0.5))


def sfx_hit_soft(t0, gain=1.0):
    kick(t0, gain * 0.9)
    t = tt(1.4)
    swish = fft_filter(noise(1.4), lo=3000, hi=12000) * np.exp(-t * 3.2) * 0.12
    place(mix, t0, swish, gain=gain, send=0.4)


# ---------- arrangement ----------
CHORDS = {
    'D': ([50, 54, 57, 61, 64], 38),
    'Bm': ([47, 50, 54, 57, 61], 35),
    'G': ([43, 47, 50, 54, 57], 31),
    'A': ([45, 52, 57, 59, 64], 33),
}
PROG = ['D', 'Bm', 'G', 'A']
ARP = [0, 2, 1, 3, 2, 4, 3, 1]

# A: the grind (0 to 6.5)
for i in range(13):
    t = 0.5 + i * BEAT
    bass(t, 26, 0.22, gain=0.5 + i * 0.04)
x = 0.5
while x < 6.45:
    step = 0.25 if x < 2.5 else 0.125 if x < 4.5 else 0.0625
    hat(x, gain=0.5 + 0.6 * (x / 6.5), pan=0.3 if int(x / step) % 2 else -0.3)
    x += step
drone_t = tt(6.5)
drone = (saw(midi(38), 6.5, fc=900) + saw(midi(39), 6.5, fc=900) * 0.6) * np.clip(drone_t / 2, 0, 1) * 0.14
place(mix, 0, drone, gain=1.0)

# B: the turn (6.5 to 12)
pad(7.0, CHORDS['D'][0], 1.9, gain=0.35, fc=700, attack=1.2)
pad(9.0, [38] + CHORDS['D'][0] + [69], 3.0, gain=0.8, fc=2400, attack=0.05)
bass(9.0, 26, 2.8, gain=0.7)

# C/D: groove (12 to 49.75), break at 28.5 to 30
for b in range(19):
    t0 = 12.0 + b * 2.0
    if t0 >= 49.75:
        break
    name = PROG[b % 4]
    notes, root = CHORDS[name]
    in_break = 28.5 <= t0 < 30.0
    pad(t0, notes, 2.0, gain=0.55 if t0 < 30 else 0.6, fc=2400 if t0 < 30 else 3200, attack=0.08)
    for k in range(16):
        t = t0 + k * 0.125
        if t >= 49.75 or 28.5 <= t < 30.0:
            continue
        beat = k % 4 == 0
        if beat:
            kick(t, 1.0)
            if (k // 4) % 2 == 1:
                clap(t, 0.8)
        if k % 4 == 2:
            hat(t, 0.9, open_=(k == 14), pan=0.25)
        elif k % 2 == 1:
            hat(t, 0.35, pan=-0.2)
        if k % 2 == 0 and not beat:
            bass(t, root + (12 if k % 8 == 6 else 0), 0.2, gain=0.9)
        elif k % 2 == 0:
            bass(t, root, 0.2, gain=0.9)
        if t >= 16.0:
            arp_gain = 0.32 if t < 30 else 0.45
            pluck(t, notes[ARP[k % 8] % len(notes)] + 24, gain=arp_gain, pan=-0.35 if k % 2 else 0.35)
    if in_break:
        pass

# E: build (49.75 to 54)
pad(49.75, CHORDS['G'][0], 2.25, gain=0.5, fc=1400, attack=0.3)
pad(52.0, CHORDS['A'][0], 1.9, gain=0.55, fc=3000, attack=0.6)
x = 51.0
while x < 53.85:
    step = 0.25 if x < 52.0 else 0.125 if x < 53.0 else 0.0625
    clap(x, 0.25 + 0.5 * (x - 51) / 3)
    x += step
for k in range(4):
    kick(50.0 + k * 0.5, 0.7)

# F: end card (54 to 60)
pad(54.0, [38, 50] + CHORDS['D'][0] + [66, 69], 4.6, gain=0.9, fc=2600, attack=0.03)
bass(54.0, 26, 4.0, gain=0.8)
for k, note in enumerate([74, 78, 81, 85, 86, 81, 78, 74]):
    pluck(54.5 + k * 0.375, note, gain=0.35, pan=-0.4 + 0.1 * k, dsend=0.4)

# ---------- cues from the film ----------
cues = json.load(open(sys.argv[1]))
plucks = iter([74, 78, 81, 81, 85, 86, 90])
for c in cues:
    t, kind, g = c['t'], c['type'], c.get('gain', 1)
    if kind == 'hit':
        sfx_hit(t, g)
    elif kind == 'hit2':
        sfx_hit(t, g, heavy=True)
    elif kind == 'glitch':
        sfx_glitch(t, g)
    elif kind == 'riser':
        sfx_riser(t, (6.47 if t < 10 else 53.95) - t, g)
    elif kind == 'bell':
        bell(t, 81, g)
        bell(t + 0.02, 74, g * 0.6)
    elif kind == 'whooshUp':
        sfx_whoosh(t, 0.95 if t < 20 else 0.1, g, up=True)
    elif kind == 'impact':
        sfx_impact(t, g)
    elif kind == 'pluck':
        pluck(t, next(plucks), gain=0.7 * g, dsend=0.45, send=0.4)
    elif kind == 'whoosh':
        sfx_whoosh(t, 0.55, g)
    elif kind == 'slide':
        sfx_whoosh(t - 0.05, 0.35, 0.6 * g)
    elif kind == 'click':
        sfx_click(t, g)
    elif kind == 'key':
        sfx_key(t, g)
    elif kind == 'tick':
        sfx_tick(t, g)
    elif kind == 'drop':
        sfx_drop(t, g)
    elif kind == 'done':
        sfx_done(t, g)
    elif kind == 'pop':
        sfx_pop(t, g)
    elif kind == 'count':
        sfx_count(t, g)
    elif kind == 'type':
        sfx_type(t, g)
    elif kind == 'hitSoft':
        sfx_hit_soft(t, g)

# ---------- effects and master ----------
# pads and bass breathe with the kick
mix += music * (0.45 + 0.55 * duck)[:, None]

# ping-pong delay, dotted eighth
d = int(0.375 * SR)
dl = np.zeros_like(delay_send)
src = delay_send.copy()
for k in range(1, 6):
    g = 0.42 ** k
    shifted = np.zeros_like(src)
    shifted[d * k:] = src[: N - d * k]
    if k % 2:
        shifted = shifted[:, ::-1]
    dl += shifted * g
dl = fft_filter(dl, lo=300, hi=5000)
mix += dl * 0.6
verb_send += dl * 0.3

# convolution reverb
ir_len = int(2.6 * SR)
ti = np.arange(ir_len) / SR
ir = np.stack([rng.standard_normal(ir_len), rng.standard_normal(ir_len)], axis=1) * np.exp(-ti / 0.55)[:, None]
ir[: int(0.015 * SR)] = 0
ir = fft_filter(ir, lo=200, hi=6500)
ir /= np.sqrt((ir ** 2).sum(axis=0))
size = 1 << int(np.ceil(np.log2(N + ir_len)))
wet = np.fft.irfft(np.fft.rfft(verb_send, size, axis=0) * np.fft.rfft(ir, size, axis=0), size, axis=0)[:N]
mix += wet * 0.55

# the grind ends in a hard cut to silence
cut0, cut1 = int(6.5 * SR), int(6.62 * SR)
mix[cut0 - 240:cut0] *= np.linspace(1, 0, 240)[:, None]
quiet = np.zeros(cut1 - cut0)
mix[cut0:cut1] *= quiet[:, None]

# gentle low cut and a tilt towards the highs, then glue and limit
mix = fft_filter(mix, lo=30, order=2)
_X = np.fft.rfft(mix, axis=0)
_f = np.fft.rfftfreq(N, 1 / SR)
mix = np.fft.irfft(_X * np.clip((np.maximum(_f, 1) / 1000) ** 0.13, 0.6, 1.5)[:, None], n=N, axis=0)
fade_in = np.clip(np.arange(N) / (0.05 * SR), 0, 1)
fade_out = np.clip((LENGTH - np.arange(N) / SR) / 1.2, 0, 1) ** 1.5
mix *= (fade_in * fade_out)[:, None]
mix /= np.max(np.abs(mix)) + 1e-9
mix = np.tanh(mix * 1.15) / np.tanh(1.15)
mix *= 0.93 / (np.max(np.abs(mix)) + 1e-9)

pcm = (mix * 32767).astype('<i2')
with open(sys.argv[2], 'wb') as f:
    data = pcm.tobytes()
    f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
    f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 2, SR, SR * 4, 4, 16))
    f.write(b'data' + struct.pack('<I', len(data)) + data)
print('wrote', sys.argv[2])
