#!/usr/bin/env python3
"""Synthesize a seamless ambient bed for Looper (no samples, no licensing).

Every layer is built to be exactly periodic over the bed's length:
  - noise is shaped in the frequency domain (circular filtering), so its end
    flows into its start like any other point in the file;
  - slow modulations are low-passed noise made the same way;
  - one-shot events (droplets, crackles) that run past the end wrap to the start.
So the file loops sample-exactly without any crossfade. Looper's wrap crossfade
still applies on top and is harmless.

Usage:
  python3 scripts/make-ambient-bed.py cabin-rain-fire beds/cabin-rain-fire.flac
  python3 scripts/make-ambient-bed.py cabin-rain-fire out.wav --duration 600 --seed 7 --fire-db -3

Output: 48 kHz stereo, 24-bit WAV or FLAC (by extension), loudness-normalised
with ffmpeg (two passes, plain gain, no compression). Needs numpy and ffmpeg.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

SR = 48000


# --- Periodic building blocks ------------------------------------------------

def lowpass(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highpass(f, fc, order=2):
    with np.errstate(divide="ignore"):
        return 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-9)) ** (2 * order))


def shaped_noise(rng, n, shape):
    """White noise filtered circularly by `shape(freqs) -> gain`; unit RMS."""
    spec = np.fft.rfft(rng.standard_normal(n))
    spec *= shape(np.fft.rfftfreq(n, 1.0 / SR))
    spec[0] = 0.0
    x = np.fft.irfft(spec, n)
    return x / np.sqrt(np.mean(x**2))


def slow_noise(rng, n, fc):
    """A smooth random modulation (unit std) wandering at roughly `fc` Hz."""
    return shaped_noise(rng, n, lambda f: lowpass(f, fc, order=4))


def unit_rms(x):
    return x / np.sqrt(np.mean(x**2))


def db(x):
    return 10.0 ** (x / 20.0)


def add_event(buf, start, kernel):
    """Add `kernel` at `start`, wrapping past the end back to the beginning."""
    n = len(buf)
    k = len(kernel)
    end = start + k
    if end <= n:
        buf[start:end] += kernel
    else:
        buf[start:] += kernel[: n - start]
        buf[: end - n] += kernel[n - start:]


def circular_reverb(rng, x, t60=0.5, predelay=0.012, wet=0.25):
    """Small-room reverb by circular convolution (keeps the signal periodic)."""
    n = len(x)
    length = int(t60 * SR)
    t = np.arange(length) / SR
    ir = rng.standard_normal(length) * np.exp(-6.9 * t / t60)
    ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
    # Darker tail: absorb highs as in a wooden room full of soft furnishings.
    ir_spec = np.fft.rfft(ir, n) * lowpass(np.fft.rfftfreq(n, 1.0 / SR), 3500)
    tail = np.fft.irfft(np.fft.rfft(x) * ir_spec, n)
    tail *= np.sqrt(np.mean(x**2)) / max(np.sqrt(np.mean(tail**2)), 1e-12)
    return x + wet * tail


# --- Layers ------------------------------------------------------------------

def rain_wash(rng, n, envelope):
    """Heavy rain outside, heard through glass: broadband hiss, highs softened."""
    def shape(f):
        pink = 1.0 / np.sqrt(np.maximum(f, 20.0))
        return pink * highpass(f, 250, 2) * lowpass(f, 5500, 2)
    return [shaped_noise(rng, n, shape) * envelope for _ in range(2)]


def roof_drumming(rng, n, envelope):
    """Low drumming of rain on the roof and skylights."""
    def shape(f):
        return highpass(f, 40, 2) * lowpass(f, 350, 3)
    common = shaped_noise(rng, n, shape)
    return [unit_rms(0.8 * common + 0.6 * shaped_noise(rng, n, shape)) * envelope
            for _ in range(2)]


def droplet_kernels(rng, count=48):
    """Short ticks of drops hitting glass: a decaying ping mixed with noise."""
    kernels = []
    for _ in range(count):
        tau = rng.uniform(0.3e-3, 1.4e-3)
        length = int(tau * 7 * SR)
        t = np.arange(length) / SR
        fc = rng.uniform(1500, 5500)
        tone = np.sin(2 * np.pi * fc * t + rng.uniform(0, 2 * np.pi))
        body = 0.55 * tone + 0.45 * rng.standard_normal(length)
        kernels.append(body * np.exp(-t / tau))
    return kernels


def glass_patter(rng, n, envelope, rate=110.0):
    """Dense random drop impacts on the windows, independent per side."""
    kernels = droplet_kernels(rng)
    channels = []
    for _ in range(2):
        buf = np.zeros(n)
        count = rng.poisson(rate * n / SR)
        starts = rng.integers(0, n, count)
        amps = np.minimum(rng.lognormal(0.0, 0.5, count), 3.0)
        picks = rng.integers(0, len(kernels), count)
        for s, a, k in zip(starts, amps, picks):
            add_event(buf, int(s), a * kernels[k])
        channels.append(unit_rms(buf) * envelope)
    return channels


def fire_rumble(rng, n, flicker):
    """The fire's soft low roar, breathing with the flicker."""
    def shape(f):
        return highpass(f, 25, 2) * lowpass(f, 180, 4)
    common = shaped_noise(rng, n, shape)
    return [unit_rms(0.9 * common + 0.3 * shaped_noise(rng, n, shape)) * flicker
            for _ in range(2)]


def flame_hiss(rng, n, flicker):
    """Faint airy hiss of burning gases."""
    def shape(f):
        return highpass(f, 400, 2) * lowpass(f, 2500, 2)
    common = shaped_noise(rng, n, shape)
    return [common * flicker, common * flicker]


def crackle_kernel(rng, pop=False):
    if pop:
        tau = rng.uniform(3e-3, 8e-3)
        length = int(tau * 6 * SR)
        t = np.arange(length) / SR
        tone = np.sin(2 * np.pi * rng.uniform(350, 900) * t)
        k = (0.6 * tone + 0.4 * rng.standard_normal(length)) * np.exp(-t / tau)
        return k * 1.5
    tau = rng.uniform(0.15e-3, 1.0e-3)
    length = max(int(tau * 6 * SR), 8)
    t = np.arange(length) / SR
    k = rng.standard_normal(length) * np.exp(-t / tau)
    return np.diff(k, prepend=0.0)  # first difference: sharper, brighter click


def fire_crackles(rng, n, base_rate=4.0, pop_rate=0.12):
    """Crackles that come in clusters, plus the odd louder pop."""
    activity = np.exp(0.8 * slow_noise(rng, n, 0.15))
    peak = activity.max()
    candidates = rng.integers(0, n, rng.poisson(base_rate * peak * n / SR))
    keep = rng.uniform(0, peak, len(candidates)) < activity[candidates]
    left, right = np.zeros(n), np.zeros(n)

    def place(start, kernel):
        pan = np.clip(0.5 + rng.normal(0, 0.12), 0, 1)  # near the centre
        add_event(left, start, np.cos(pan * np.pi / 2) * kernel)
        add_event(right, start, np.sin(pan * np.pi / 2) * kernel)

    for start in candidates[keep]:
        amp = min(rng.pareto(2.5) + 0.3, 2.5)
        place(int(start), amp * crackle_kernel(rng))
        if rng.uniform() < 0.3:  # a quick burst of follow-up crackles
            t = int(start)
            for _ in range(rng.integers(2, 6)):
                t = (t + int(rng.uniform(0.005, 0.06) * SR)) % n
                place(t, rng.uniform(0.2, 0.8) * amp * crackle_kernel(rng))
    for start in rng.integers(0, n, rng.poisson(pop_rate * n / SR)):
        place(int(start), crackle_kernel(rng, pop=True))
    return [left, right]


# --- Presets -----------------------------------------------------------------

def cabin_rain_fire(rng, n, args):
    """Cosy cabin: heavy rain on panoramic windows, gentle fire in the hearth."""
    # The weather swells and eases slowly; shared by every rain layer.
    rain_env = 1.0 + 0.12 * slow_noise(rng, n, 0.03) + 0.05 * slow_noise(rng, n, 0.4)
    flicker = np.clip(1.0 + 0.35 * slow_noise(rng, n, 0.8)
                      + 0.2 * slow_noise(rng, n, 3.0), 0.25, None)

    # Levels in dB against the rain wash's RMS. Continuous layers are set by
    # RMS; sparse event layers by their loudest event, because their RMS says
    # little about how loud a drop or crackle sounds (crest factors of 35-45 dB).
    rain = [
        (rain_wash(rng, n, rain_env), 0.0, "rms"),
        (roof_drumming(rng, n, rain_env), -7.0, "rms"),
        (glass_patter(rng, n, rain_env), 6.0, "peak"),
    ]
    fire = [
        (fire_rumble(rng, n, flicker), -13.0, "rms"),
        (flame_hiss(rng, n, flicker), -26.0, "rms"),
        (fire_crackles(rng, n), 12.0, "peak"),
    ]
    out = [np.zeros(n), np.zeros(n)]
    for layers, group_db in ((rain, args.rain_db), (fire, args.fire_db)):
        group = [np.zeros(n), np.zeros(n)]
        for (l, r), level, mode in layers:
            if mode == "rms":
                ref = np.sqrt(0.5 * (np.mean(l**2) + np.mean(r**2)))
            else:
                ref = max(np.abs(l).max(), np.abs(r).max())
            scale = db(level) / ref
            group[0] += l * scale
            group[1] += r * scale
        if layers is fire:  # the fire sits across the room
            group = [circular_reverb(rng, c) for c in group]
        out[0] += group[0] * db(group_db)
        out[1] += group[1] * db(group_db)
    return out


PRESETS = {"cabin-rain-fire": cabin_rain_fire}


# --- Output ------------------------------------------------------------------

def measure_loudness(raw_path):
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(SR),
           "-ac", "2", "-i", raw_path, "-af",
           "loudnorm=print_format=json", "-f", "null", "-"]
    err = subprocess.run(cmd, capture_output=True, text=True, check=True).stderr
    stats = json.loads(err[err.rindex("{"): err.rindex("}") + 1])
    return float(stats["input_i"]), float(stats["input_tp"])


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("preset", choices=sorted(PRESETS))
    p.add_argument("output", help=".wav or .flac")
    p.add_argument("--duration", type=float, default=300.0, help="seconds (default 300)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--lufs", type=float, default=-20.0, help="integrated loudness target")
    p.add_argument("--rain-db", type=float, default=0.0, help="rain group level")
    p.add_argument("--fire-db", type=float, default=0.0, help="fire group level")
    args = p.parse_args()

    n = int(round(args.duration * SR))
    rng = np.random.default_rng(args.seed)
    left, right = PRESETS[args.preset](rng, n, args)
    stereo = np.stack([left, right], axis=1).astype(np.float32)

    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, "bed.f32")
        stereo.tofile(raw)
        loudness, true_peak = measure_loudness(raw)
        gain = args.lufs - loudness
        if true_peak + gain > -1.0:  # never let normalisation push peaks past -1 dBTP
            gain = -1.0 - true_peak
            print(f"note: limited by peaks, bed will be {loudness + gain:.1f} LUFS",
                  file=sys.stderr)
        codec = ["-c:a", "flac", "-sample_fmt", "s32"] if args.output.endswith(".flac") \
            else ["-c:a", "pcm_s24le"]
        if args.output.endswith(".flac"):
            codec += ["-bits_per_raw_sample", "24"]
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", raw,
                        "-af", f"volume={gain:.3f}dB", *codec, args.output], check=True)
    print(f"{args.output}: {args.preset}, {args.duration:g} s, seed {args.seed}, "
          f"{loudness + gain:.1f} LUFS")


if __name__ == "__main__":
    main()
