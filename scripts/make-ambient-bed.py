#!/usr/bin/env python3
"""Synthesize a seamless ambient bed for Looper (no samples, no licensing).

Every layer is built to be exactly periodic over the bed's length:
  - noise is shaped in the frequency domain (circular filtering), so its end
    flows into its start like any other point in the file;
  - slow modulations are low-passed noise made the same way;
  - one-shot events (drops, crackles) that run past the end wrap to the start.
So the file loops sample-exactly without any crossfade. Looper's wrap crossfade
still applies on top and is harmless.

Rain is built from individual drops, not filtered noise: steady filtered noise
on its own reads as "white noise". Fire crackles are snaps with a short noisy
tail, long enough to be heard over the rain.

Usage:
  python3 scripts/make-ambient-bed.py cabin-rain-fire beds/cabin-rain-fire.wav
  python3 scripts/make-ambient-bed.py cabin-rain-fire out.wav --duration 600 --fire-db 3 --report

Output: 48 kHz stereo, 24-bit WAV (or FLAC by extension), loudness-normalised
with ffmpeg. Needs numpy and ffmpeg. --report prints how far each kind of event
stands out from the rest of the mix, as a check on whether it will be heard.
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
    return 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-9)) ** (2 * order))


def circular_filter(x, shape):
    """Filter a whole periodic signal by `shape(freqs) -> gain`."""
    spec = np.fft.rfft(x)
    spec *= shape(np.fft.rfftfreq(len(x), 1.0 / SR))
    spec[0] = 0.0
    return np.fft.irfft(spec, len(x))


def shaped_noise(rng, n, shape):
    """White noise filtered circularly; unit RMS."""
    return unit_rms(circular_filter(rng.standard_normal(n), shape))


def slow_noise(rng, n, fc):
    """A smooth random modulation (unit std) wandering at roughly `fc` Hz."""
    return shaped_noise(rng, n, lambda f: lowpass(f, fc, order=4))


def unit_rms(x):
    return x / np.sqrt(np.mean(x**2))


def db(x):
    return 10.0 ** (x / 20.0)


def stereo_rms(ch):
    return np.sqrt(0.5 * (np.mean(ch[0] ** 2) + np.mean(ch[1] ** 2)))


def add_event(buf, start, kernel):
    """Add `kernel` at `start`, wrapping past the end back to the beginning."""
    n = len(buf)
    end = start + len(kernel)
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
    # Darker tail: a wooden room full of soft furnishings absorbs the highs.
    ir_spec = np.fft.rfft(ir, n) * lowpass(np.fft.rfftfreq(n, 1.0 / SR), 3500)
    tail = np.fft.irfft(np.fft.rfft(x) * ir_spec, n)
    tail *= np.sqrt(np.mean(x**2)) / max(np.sqrt(np.mean(tail**2)), 1e-12)
    return x + wet * tail


# --- Event sounds (short kernels) --------------------------------------------

def band_burst(rng, fc, q, tau):
    """A decaying noise burst band-limited around `fc` (bandwidth fc/q)."""
    length = max(int(tau * 7 * SR), 16)
    t = np.arange(length) / SR
    noise = rng.standard_normal(length) * np.exp(-t / tau)
    size = 1 << int(np.ceil(np.log2(length * 2)))
    f = np.fft.rfftfreq(size, 1.0 / SR)
    gain = np.exp(-0.5 * ((f - fc) / (fc / q / 2)) ** 2)
    k = np.fft.irfft(np.fft.rfft(noise, size) * gain, size)[:length]
    return k / max(np.abs(k).max(), 1e-12)


def damped_sine(rng, f0, tau, chirp=1.0, attack=0.0003):
    """A ringing tone; `chirp` > 1 glides the pitch up (the 'plink' of a drop)."""
    length = int(tau * 7 * SR)
    t = np.arange(length) / SR
    freq = f0 * chirp ** (t / (tau * 3))
    phase = 2 * np.pi * np.cumsum(freq) / SR + rng.uniform(0, 2 * np.pi)
    env = np.exp(-t / tau) * np.minimum(t / attack, 1.0)
    return np.sin(phase) * env


def small_drop(rng):
    """One of many raindrops outside, heard through glass: a short soft tick."""
    return band_burst(rng, rng.uniform(900, 4200), rng.uniform(1.2, 2.5),
                      rng.uniform(0.6e-3, 2.5e-3))


def glass_tap(rng):
    """A drop striking the window: a sharp click with a brief glassy ring."""
    click = band_burst(rng, rng.uniform(3000, 7000), 0.8, rng.uniform(0.15e-3, 0.4e-3))
    ring = damped_sine(rng, rng.uniform(2200, 5500), rng.uniform(1.0e-3, 3.0e-3))
    body = band_burst(rng, rng.uniform(1200, 3000), 1.5, rng.uniform(1.5e-3, 4e-3))
    k = np.zeros(max(len(click), len(ring), len(body)))
    k[: len(click)] += click
    k[: len(ring)] += 0.45 * ring
    k[: len(body)] += 0.35 * body
    return k


def plink(rng):
    """A drop landing in water: a short upward-gliding tone (bubble resonance)."""
    return damped_sine(rng, rng.uniform(1400, 3200), rng.uniform(4e-3, 9e-3),
                       chirp=rng.uniform(1.15, 1.5), attack=0.001)


def crackle(rng):
    """A snap of burning wood: a sharp spike then a short fizzing tail."""
    spike = band_burst(rng, rng.uniform(2500, 6000), 0.7, rng.uniform(0.1e-3, 0.35e-3))
    tail = band_burst(rng, rng.uniform(1200, 4500), rng.uniform(0.8, 1.6),
                      rng.uniform(2e-3, 12e-3))
    k = np.zeros(max(len(spike), len(tail)))
    k[: len(spike)] += spike
    k[: len(tail)] += rng.uniform(0.3, 0.6) * tail
    return k


def micro_snap(rng):
    """The tiny fizzing ticks between crackles."""
    return band_burst(rng, rng.uniform(2000, 7000), 1.0, rng.uniform(0.1e-3, 0.6e-3))


def pop(rng):
    """An occasional bigger pop: snap plus a soft low thump."""
    snap = crackle(rng)
    thump = damped_sine(rng, rng.uniform(110, 240), rng.uniform(8e-3, 18e-3), attack=0.0008)
    k = np.zeros(max(len(snap), len(thump)))
    k[: len(snap)] += snap
    k[: len(thump)] += 0.7 * thump
    return k


def kernel_bank(rng, make, count=64):
    return [make(rng) for _ in range(count)]


def scatter(rng, n, bank, starts, amps, pans=None):
    """Place kernels from `bank` at `starts`; returns stereo channels."""
    left, right = np.zeros(n), np.zeros(n)
    picks = rng.integers(0, len(bank), len(starts))
    if pans is None:
        pans = np.full(len(starts), 0.5)
    for s, a, k, p in zip(starts, amps, picks, pans):
        kernel = a * bank[k]
        add_event(left, int(s), np.cos(p * np.pi / 2) * kernel)
        add_event(right, int(s), np.sin(p * np.pi / 2) * kernel)
    return [left, right]


def poisson_starts(rng, n, rate, envelope=None):
    """Random event times at `rate`/s, thinned by an optional envelope (shape >= 0)."""
    if envelope is None:
        return rng.integers(0, n, rng.poisson(rate * n / SR))
    peak = envelope.max()
    starts = rng.integers(0, n, rng.poisson(rate * peak * n / SR))
    return starts[rng.uniform(0, peak, len(starts)) < envelope[starts]]


# --- Layers: each returns (stereo channels, event starts or None) ------------

def distant_rain(rng, n, env):
    """Far rain as a soft, dark wash: only a backdrop for the drops."""
    def shape(f):
        return highpass(f, 200, 2) * lowpass(f, 2200, 2) / np.sqrt(np.maximum(f, 20.0))
    return [shaped_noise(rng, n, shape) * env for _ in range(2)], None


def roof_drumming(rng, n, env):
    """Low drumming of rain on the roof and skylights."""
    def shape(f):
        return highpass(f, 40, 2) * lowpass(f, 300, 3)
    common = shaped_noise(rng, n, shape)
    return [unit_rms(0.8 * common + 0.6 * shaped_noise(rng, n, shape)) * env
            for _ in range(2)], None


def drop_patter(rng, n, env, rate=700.0):
    """Hundreds of small drops per second: the grainy texture that says 'rain'."""
    starts = poisson_starts(rng, n, rate, env)
    amps = rng.lognormal(0.0, 0.7, len(starts))
    pans = rng.uniform(0.0, 1.0, len(starts))
    return scatter(rng, n, kernel_bank(rng, small_drop), starts, amps, pans), None


def window_taps(rng, n, env, rate=35.0):
    """Distinct drops hitting the windows on both sides of the room."""
    starts = poisson_starts(rng, n, rate, env)
    amps = np.minimum(rng.lognormal(0.0, 0.5, len(starts)), 3.0)
    pans = np.where(rng.uniform(size=len(starts)) < 0.5,
                    rng.uniform(0.0, 0.3, len(starts)), rng.uniform(0.7, 1.0, len(starts)))
    return scatter(rng, n, kernel_bank(rng, glass_tap), starts, amps, pans), starts


def water_plinks(rng, n, env, rate=5.0):
    """Drops falling into puddles and gutters outside."""
    starts = poisson_starts(rng, n, rate, env)
    amps = rng.uniform(0.3, 1.0, len(starts))
    pans = rng.uniform(0.1, 0.9, len(starts))
    return scatter(rng, n, kernel_bank(rng, plink), starts, amps, pans), starts


def fire_rumble(rng, n, flicker):
    """The fire's soft low roar, breathing with the flicker."""
    def shape(f):
        return highpass(f, 25, 2) * lowpass(f, 180, 4)
    common = shaped_noise(rng, n, shape)
    return [unit_rms(0.9 * common + 0.3 * shaped_noise(rng, n, shape)) * flicker
            for _ in range(2)], None


def fire_crackles(rng, n, activity, rate=5.0):
    """Snaps that come in clusters, with quick follow-ups."""
    first = poisson_starts(rng, n, rate, activity)
    starts, amps = [], []
    for s in first:
        amp = min(rng.pareto(3.0) + 0.4, 2.0)
        starts.append(int(s))
        amps.append(amp)
        if rng.uniform() < 0.35:  # a quick run of follow-up snaps
            t = int(s)
            for _ in range(rng.integers(1, 5)):
                t = (t + int(rng.uniform(0.01, 0.09) * SR)) % n
                starts.append(t)
                amps.append(rng.uniform(0.3, 0.8) * amp)
    starts, amps = np.array(starts), np.array(amps)
    pans = np.clip(0.5 + rng.normal(0, 0.1, len(starts)), 0, 1)
    return scatter(rng, n, kernel_bank(rng, crackle), starts, amps, pans), starts


def fire_fizz(rng, n, activity, rate=18.0):
    """Tiny ticks, busiest when the fire is most active."""
    starts = poisson_starts(rng, n, rate, activity**2)
    amps = rng.uniform(0.2, 1.0, len(starts))
    pans = np.clip(0.5 + rng.normal(0, 0.1, len(starts)), 0, 1)
    return scatter(rng, n, kernel_bank(rng, micro_snap), starts, amps, pans), None


def fire_pops(rng, n, rate=0.15):
    starts = poisson_starts(rng, n, rate)
    amps = rng.uniform(0.7, 1.0, len(starts))
    pans = np.clip(0.5 + rng.normal(0, 0.1, len(starts)), 0, 1)
    return scatter(rng, n, kernel_bank(rng, pop, 16), starts, amps, pans), starts


# --- Presets -----------------------------------------------------------------

def cabin_rain_fire(rng, n, args):
    """Cosy cabin: heavy rain on panoramic windows, gentle fire in the hearth.

    Returns {layer name: (stereo, event starts, group)} with levels applied.
    """
    # The weather swells and eases slowly; shared by every rain layer.
    rain_env = np.clip(1.0 + 0.15 * slow_noise(rng, n, 0.03)
                       + 0.07 * slow_noise(rng, n, 0.4), 0.3, None)
    flicker = np.clip(1.0 + 0.35 * slow_noise(rng, n, 0.8)
                      + 0.2 * slow_noise(rng, n, 3.0), 0.25, None)
    activity = np.exp(0.7 * slow_noise(rng, n, 0.12))

    # Levels: dB of each layer's RMS against the drop patter's RMS.
    plan = [
        ("drop patter", "rain", 0.0, drop_patter(rng, n, rain_env)),
        ("window taps", "rain", -1.0, window_taps(rng, n, rain_env)),
        ("water plinks", "rain", -10.0, water_plinks(rng, n, rain_env)),
        ("distant rain", "rain", -9.0, distant_rain(rng, n, rain_env)),
        ("roof drumming", "rain", -9.0, roof_drumming(rng, n, rain_env)),
        ("fire rumble", "fire", -11.0, fire_rumble(rng, n, flicker)),
        ("crackles", "fire", 1.0, fire_crackles(rng, n, activity)),
        ("fizz", "fire", -20.0, fire_fizz(rng, n, activity)),
        ("pops", "fire", -9.0, fire_pops(rng, n)),
    ]
    group_db = {"rain": args.rain_db, "fire": args.fire_db}
    layers = {}
    for name, group, level, (channels, starts) in plan:
        scale = db(level + group_db[group]) / stereo_rms(channels)
        layers[name] = ([c * scale for c in channels], starts, group)
    # The fire sits across the room: give it some of the room's reverb.
    rr = np.random.default_rng(rng.integers(1 << 32))
    for name, (channels, starts, group) in layers.items():
        if group == "fire":
            layers[name] = ([circular_reverb(rr, c, wet=0.2) for c in channels], starts, group)
    return layers


PRESETS = {"cabin-rain-fire": cabin_rain_fire}


# --- Mixing, checks and output -----------------------------------------------

def soft_clip(x, knee=0.35, ceiling=0.8):
    """Round off the rare loud transient instead of turning the whole bed down."""
    y = x.copy()
    over = np.abs(x) > knee
    excess = (np.abs(x[over]) - knee) / (ceiling - knee)
    y[over] = np.sign(x[over]) * (knee + (ceiling - knee) * np.tanh(excess))
    return y


def prominence_report(layers, mix):
    """How far events stand out: energy with the event vs without, in 8 ms."""
    def hp(x):
        return circular_filter(x, lambda f: highpass(f, 500, 2))
    mono_mix = hp(0.5 * (mix[0] + mix[1]))
    win = int(0.008 * SR)
    print("event prominence over the rest of the mix (8 ms windows, above 500 Hz):")
    for name, (channels, starts, _) in layers.items():
        if starts is None or len(starts) == 0:
            continue
        mono_layer = hp(0.5 * (channels[0] + channels[1]))
        rest = mono_mix - mono_layer
        rng = np.random.default_rng(0)
        sample = rng.choice(starts, min(len(starts), 3000), replace=False)
        gains = []
        for s in sample:
            idx = (np.arange(win) + s) % len(rest)
            gains.append(10 * np.log10(np.sum(mono_mix[idx] ** 2)
                                       / max(np.sum(rest[idx] ** 2), 1e-20)))
        g = np.array(gains)
        print(f"  {name:13s} median {np.median(g):4.1f} dB, "
              f"{100 * np.mean(g > 3):3.0f}% over 3 dB, {100 * np.mean(g > 6):3.0f}% over 6 dB")


def measure_loudness(raw_path):
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(SR),
           "-ac", "2", "-i", raw_path, "-af", "loudnorm=print_format=json",
           "-f", "null", "-"]
    err = subprocess.run(cmd, capture_output=True, text=True, check=True).stderr
    stats = json.loads(err[err.rindex("{"): err.rindex("}") + 1])
    return float(stats["input_i"]), float(stats["input_tp"])


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("preset", choices=sorted(PRESETS))
    p.add_argument("output", help=".wav (recommended) or .flac")
    p.add_argument("--duration", type=float, default=300.0, help="seconds (default 300)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--lufs", type=float, default=-20.0, help="integrated loudness target")
    p.add_argument("--rain-db", type=float, default=0.0, help="rain group level")
    p.add_argument("--fire-db", type=float, default=0.0, help="fire group level")
    p.add_argument("--report", action="store_true", help="print event prominence")
    args = p.parse_args()

    n = int(round(args.duration * SR))
    rng = np.random.default_rng(args.seed)
    layers = PRESETS[args.preset](rng, n, args)
    mix = [sum(ch[i] for ch, _, _ in layers.values()) for i in range(2)]
    if args.report:
        prominence_report(layers, mix)
    del layers

    # Bring the mix to a working level (about -23 dBFS RMS), then soften peaks.
    scale = db(-23.0) / stereo_rms(mix)
    stereo = np.stack([soft_clip(c * scale) for c in mix], axis=1).astype(np.float32)
    del mix

    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, "bed.f32")
        stereo.tofile(raw)
        loudness, true_peak = measure_loudness(raw)
        gain = args.lufs - loudness
        if true_peak + gain > -1.0:  # never let normalisation push peaks past -1 dBTP
            gain = -1.0 - true_peak
            print(f"note: limited by peaks, bed will be {loudness + gain:.1f} LUFS",
                  file=sys.stderr)
        if args.output.endswith(".flac"):
            codec = ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        else:
            codec = ["-c:a", "pcm_s24le"]
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", raw,
                        "-af", f"volume={gain:.3f}dB", *codec, args.output], check=True)
    print(f"{args.output}: {args.preset}, {args.duration:g} s, seed {args.seed}, "
          f"{loudness + gain:.1f} LUFS")


if __name__ == "__main__":
    main()
