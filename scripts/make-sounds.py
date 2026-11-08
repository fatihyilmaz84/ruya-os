#!/usr/bin/env python3
"""Generate the RuyaOS sound theme "Dreamglass" (T-227) and the guide's example theme.

Everything here is computed from numbers in this file (numpy, no random numbers, no samples from
anywhere else), so the output is the same bytes on every run and the audio is our own work: CC0.

    python -I scripts/make-sounds.py              # write shell/sounds/dreamglass and samples/sound-theme-example
    python -I scripts/make-sounds.py --verify     # the check that dev.ps1 test runs (see below)
    python -I scripts/make-sounds.py --out DIR    # write the theme somewhere else (a copy to start a new theme from)

--verify generates the theme twice and demands identical bytes, checks every limit of the sound
theme format (docs/developers/sound-themes.md), checks that the ambient loop's seam is smooth, decodes
the FLAC it wrote (a decoder for the subset this file writes) and compares it with the samples, and
checks that the files in the repository are what the generator writes now (WAV within one sample
step: sine functions may differ in the last bit between machines).

To make your own theme from this: change the numbers in CUES, GLASS, PAD and AMBIENT below and run
with --out. The ambient is a FLAC written by the encoder in this file because numpy has no Ogg
Vorbis encoder; if you have one (oggenc, ffmpeg), an .ogg works as well: the loop must be a whole
number of cycles of every partial so that its end joins its start (see make_pad).
"""
import argparse
import hashlib
import json
import math
import os
import shutil
import sys
import tempfile
import wave

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FS = 48000          # cue sample rate (Hz): the format asks for 48 kHz

# ---------------------------------------------------------------------------------------------
# The cues. Each cue is a list of notes (start s, frequency Hz, length s, level 0..1) or a sweep
# ("sweep", start, f0, f1, length, level). `peak` is the loudest sample of the finished cue
# (1.0 = 0 dBFS); the format's limit is 0.708 (-3 dBFS). A glassy note is a few sine partials
# (ratio to the fundamental, level, how long it rings relative to the note) with a short rounded
# attack and an exponential tail.
# ---------------------------------------------------------------------------------------------
ATTACK = 0.006      # seconds from silence to full level
GLASS = ((1.0, 1.00, 1.0), (2.0, 0.28, 0.7), (2.76, 0.20, 0.5), (5.40, 0.07, 0.3))
SOFT = ((1.0, 1.00, 1.0), (2.0, 0.20, 0.6))

CUES = {
    # name: (peak, partials, notes)
    "navigate":     (0.30, GLASS, [(0.00, 1318.5, 0.12, 1.0)]),
    "select":       (0.42, GLASS, [(0.00, 880.0, 0.10, 0.8), (0.07, 1318.5, 0.22, 1.0)]),
    "back":         (0.40, GLASS, [(0.00, 1046.5, 0.10, 0.8), (0.07, 659.3, 0.22, 1.0)]),
    "error":        (0.45, SOFT,  [(0.00, 311.1, 0.16, 1.0), (0.13, 277.2, 0.30, 1.0)]),
    "notification": (0.45, GLASS, [(0.00, 987.8, 0.35, 0.9), (0.14, 1480.0, 0.55, 1.0)]),
    "warning":      (0.50, GLASS, [(0.00, 880.0, 0.20, 1.0), (0.20, 880.0, 0.20, 1.0), (0.40, 659.3, 0.50, 1.0)]),
    "open":         (0.40, GLASS, [("sweep", 0.00, 392.0, 784.0, 0.28, 1.0)]),
    "close":        (0.40, GLASS, [("sweep", 0.00, 784.0, 392.0, 0.28, 1.0)]),
    "page":         (0.30, GLASS, [("sweep", 0.00, 600.0, 900.0, 0.16, 1.0)]),
    "volume":       (0.25, GLASS, [(0.00, 1760.0, 0.05, 1.0)]),
    "startup":      (0.50, GLASS, [(0.00, 293.7, 1.35, 0.9), (0.06, 440.0, 1.30, 0.8), (0.12, 587.3, 1.25, 0.8),
                                   (0.18, 880.0, 1.20, 0.7), (0.26, 1174.7, 1.10, 0.6)]),
    "toggle-on":    (0.35, GLASS, [(0.00, 784.0, 0.08, 0.8), (0.05, 1174.7, 0.14, 1.0)]),
    "toggle-off":   (0.35, GLASS, [(0.00, 1174.7, 0.08, 0.8), (0.05, 784.0, 0.14, 1.0)]),
}

# ---------------------------------------------------------------------------------------------
# The ambient pad: a slow loop of detuned sine layers whose levels drift (the "filter drift": the
# upper layers swell and fade at their own slow rate). Every frequency and every drift is snapped
# to a whole number of cycles per loop, so the last sample joins the first one without a click.
# ---------------------------------------------------------------------------------------------
AMBIENT_RATE = 24000                 # Hz; the pad has nothing above a few hundred Hz
AMBIENT_BLOCKS = 440                 # loop length in FLAC blocks of 4096 samples (75.09 s)
AMBIENT_PEAK = 0.35                  # loudest sample; the manifest's gain lowers it further
AMBIENT_GAIN = 0.7
# (frequency Hz, level, drift cycles per loop, drift phase 0..1, detune): a chord of D with a
# ninth, each layer twice (one slightly above, one slightly below) for the slow beating.
PAD = (
    (73.42, 0.9, 1, 0.00, 0.0020),
    (110.00, 0.8, 2, 0.20, 0.0025),
    (146.83, 0.7, 3, 0.45, 0.0020),
    (185.00, 0.5, 2, 0.70, 0.0030),
    (220.00, 0.45, 4, 0.10, 0.0025),
    (329.63, 0.30, 3, 0.85, 0.0030),
)

THEME = {
    "name": "Dreamglass",
    "author": "The RuyaOS authors",
    "licence": "CC0-1.0",
    "version": "1.0.0",
}

README = """# Dreamglass

The sound theme RuyaOS ships. Soft glassy bells for the interface cues and a slow pad for the
ambient bed behind Home and the menus. Made by `scripts/make-sounds.py` from numbers alone (sine
partials, no recordings, no samples from anywhere else), so it is our own work: **CC0 1.0** (public
domain dedication, https://creativecommons.org/publicdomain/zero/1.0/). Do what you like with it.

- `theme.json`: the manifest (cue names to files, the ambient loop).
- `*.wav`: the cues, mono 16-bit 48 kHz, each under 1.5 s.
- `ambient.flac`: the pad, mono 24 kHz, a loop of about 75 s.

To change it, edit the numbers at the top of the script and run it with `--out <folder>`. How to
make a theme of your own is in docs/developers/sound-themes.md.
"""

EXAMPLE_README = """# Example sound theme

The smallest complete sound theme: a short tone per cue and a short ambient loop, made by
`python -I scripts/make-sounds.py` (the `--example` part). Copy this folder to a USB drive as
`RuyaOS/sounds/example/`, put the drive in a RuyaOS console and choose "Example theme" in
Settings -> Audio -> Sound theme. Replace the files with your own sounds and keep the names in
`theme.json`. The format is in docs/developers/sound-themes.md.

Licence: CC0 1.0 (public domain dedication).
"""

LICENCE_TEXT = """The sounds in this folder (the cues and the ambient pad of the Dreamglass sound theme) are
generated by scripts/make-sounds.py from numbers alone. No recordings or samples from anywhere
else are used. They are dedicated to the public domain under CC0 1.0 Universal:
https://creativecommons.org/publicdomain/zero/1.0/
"""

# Limits of the sound theme format (the C++ checker, src/sound/SoundThemeCheck.cpp, enforces the same).
CUE_MAX_SECONDS = 1.5
CUE_MAX_BYTES = 200 * 1024
CUE_PEAK_LIMIT = 10 ** (-3 / 20)
AMBIENT_MAX_BYTES = 3 * 1024 * 1024


# ---------------------------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------------------------
def _fade_out(n, tail_samples):
    """1 until the last tail_samples, then a smooth fall to 0 (so no cue ends on a step)."""
    f = np.ones(n)
    tail_samples = min(tail_samples, n)
    ramp = np.arange(tail_samples) / max(tail_samples - 1, 1)
    f[n - tail_samples:] = 0.5 + 0.5 * np.cos(np.pi * ramp)
    return f


def bell(freq, length, level, partials):
    n = int(round(length * FS))
    t = np.arange(n) / FS
    out = np.zeros(n)
    total = sum(p[1] for p in partials)
    for ratio, amp, ring in partials:
        tau = length * ring / 4.0
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / tau)
    attack = np.clip(t / ATTACK, 0, 1)
    attack = 0.5 - 0.5 * np.cos(np.pi * attack)
    return level * out / total * attack * _fade_out(n, int(0.02 * FS))


def sweep(f0, f1, length, level):
    n = int(round(length * FS))
    t = np.arange(n) / FS
    x = t / length
    glide = x * x * (3 - 2 * x)                      # smoothstep: the pitch eases in and out
    freq = f0 + (f1 - f0) * glide
    phase = 2 * np.pi * np.cumsum(freq) / FS
    out = np.sin(phase) + 0.25 * np.sin(2 * phase)
    window = np.sin(np.pi * x) ** 2                  # Hann: starts and ends in silence
    return level * out / 1.25 * window


def render_cue(spec):
    peak, partials, notes = spec
    length = 0.0
    for note in notes:
        if note[0] == "sweep":
            length = max(length, note[1] + note[4])
        else:
            length = max(length, note[0] + note[2])
    buf = np.zeros(int(round(length * FS)) + 1)
    for note in notes:
        if note[0] == "sweep":
            _, start, f0, f1, dur, level = note
            piece = sweep(f0, f1, dur, level)
        else:
            start, freq, dur, level = note
            piece = bell(freq, dur, level, partials)
        at = int(round(start * FS))
        buf[at:at + len(piece)] += piece
    buf *= peak / np.max(np.abs(buf))
    return np.round(buf * 32767).astype(np.int16)


def render_cues(table):
    return {name: render_cue(spec) for name, spec in table.items()}


def make_pad(rate, blocks, layers, peak):
    """A seamless pad: every frequency and drift is a whole number of cycles in the loop."""
    n = 4096 * blocks
    seconds = n / rate
    t = np.arange(n) / rate
    out = np.zeros(n)
    for freq, level, drift_cycles, drift_phase, detune in layers:
        for sign in (1, -1):
            cycles = round(freq * (1 + sign * detune) * seconds)     # whole cycles per loop
            f = cycles / seconds
            drift = 0.6 + 0.4 * np.sin(2 * np.pi * (drift_cycles * t / seconds + drift_phase + (0.5 if sign < 0 else 0)))
            out += level * drift * np.sin(2 * np.pi * f * t + (0.0 if sign > 0 else 1.3))
    out *= peak / np.max(np.abs(out))
    return np.round(out * 32767).astype(np.int16)


# ---------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------
def write_wav(path, samples, rate=FS):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.astype("<i2").tobytes())


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int64), w.getframerate()


def _make_crc8():
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
        table.append(c)
    return table


def _make_crc16():
    table = []
    for i in range(256):
        c = i << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x8005) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
        table.append(c)
    return table


CRC8, CRC16 = _make_crc8(), _make_crc16()


def crc8(data):
    c = 0
    for b in data:
        c = CRC8[c ^ b]
    return c


def crc16(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFF) ^ CRC16[(c >> 8) ^ b]
    return c


def _bits(value, width):
    return ((value >> np.arange(width - 1, -1, -1)) & 1).astype(np.uint8)


def _rice(u, k):
    """Rice code of the unsigned values u with parameter k, as an array of bits."""
    q = u >> k
    lengths = q + 1 + k
    starts = np.cumsum(lengths) - lengths
    bits = np.zeros(int(lengths.sum()), dtype=np.uint8)
    bits[starts + q] = 1
    for j in range(k):
        bits[starts + q + 1 + j] = (u >> (k - 1 - j)) & 1
    return bits


BLOCK = 4096
PARTITION_ORDER = 4
# The frame header's sample rate code for the rates this file writes. Every frame names its rate:
# code 0 ("see STREAMINFO") is valid FLAC, but Qt 6.11's FFmpeg player then opens its output at
# 0 Hz and never plays (T-321: "QAudioSink::start: QAudioFormat not valid" in a loop, no sound).
FLAC_RATE_CODES = {8000: 4, 16000: 5, 22050: 6, 24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11}


def _frame(index, x, rate):
    """One mono 16-bit FLAC frame: the best fixed predictor (order 0..4), Rice coded."""
    best = None
    for order in range(5):
        r = np.diff(x, n=order) if order else x
        cost = int(np.abs(r).sum())
        if best is None or cost < best[0]:
            best = (cost, order, r)
    _, order, r = best
    parts = 1 << PARTITION_ORDER
    size = BLOCK >> PARTITION_ORDER
    pieces = [_bits(0, 1), _bits(8 + order, 6), _bits(0, 1)]            # pad, FIXED<order>, no wasted bits
    for v in x[:order]:
        pieces.append(_bits(int(v) & 0xFFFF, 16))
    pieces.append(_bits(0, 2))                                          # residual coding: Rice, 4-bit parameters
    pieces.append(_bits(PARTITION_ORDER, 4))
    at = 0
    for p in range(parts):
        count = size - (order if p == 0 else 0)
        chunk = r[at:at + count]
        at += count
        u = np.where(chunk >= 0, chunk * 2, -chunk * 2 - 1).astype(np.int64)
        costs = [int((u >> k).sum()) + len(u) * (k + 1) for k in range(15)]
        k = int(np.argmin(costs))
        pieces.append(_bits(k, 4))
        pieces.append(_rice(u, k))
    body = np.concatenate(pieces)
    body = np.concatenate([body, np.zeros((-len(body)) % 8, dtype=np.uint8)])
    header = bytes([0xFF, 0xF8, (12 << 4) | FLAC_RATE_CODES[rate], (0 << 4) | (4 << 1) | 0]) + chr(index).encode("utf-8")
    header += bytes([crc8(header)])
    frame = header + np.packbits(body).tobytes()
    return frame + crc16(frame).to_bytes(2, "big")


def encode_flac(samples, rate):
    """Mono 16-bit FLAC, 4096-sample blocks (len(samples) must be a multiple of 4096)."""
    x = samples.astype(np.int64)
    assert len(x) % BLOCK == 0 and len(x) > 0
    md5 = hashlib.md5(samples.astype("<i2").tobytes()).digest()
    info = (BLOCK.to_bytes(2, "big") * 2 + bytes(6)
            + ((rate << 44) | (0 << 41) | (15 << 36) | len(x)).to_bytes(8, "big") + md5)
    out = [b"fLaC", bytes([0x80, 0, 0, 34]), info]
    for i in range(len(x) // BLOCK):
        out.append(_frame(i, x[i * BLOCK:(i + 1) * BLOCK], rate))
    return b"".join(out)


def _undo_fixed(order, warm, residual):
    """Rebuilds the samples from the warm-up samples and the residual of a fixed predictor."""
    y = np.array(residual, dtype=np.int64)            # y_order = the order-th difference of x
    if order == 0:
        return y
    w = np.array(warm, dtype=np.int64)
    for j in range(order - 1, -1, -1):
        d = np.diff(w, n=j) if j else w               # the first order-j elements of y_j come from the warm-up
        y = np.concatenate([d, d[-1] + np.cumsum(y[order - j - 1:])])
    return y


def decode_flac(data):
    """Decoder for the subset encode_flac writes (mono, 16-bit, fixed predictors, Rice). Returns (samples, rate)."""
    assert data[:4] == b"fLaC" and data[4] == 0x80
    info = data[8:42]
    packed = int.from_bytes(info[10:18], "big")
    rate, total = packed >> 44, packed & ((1 << 36) - 1)
    pos = 42
    out = np.zeros(total, dtype=np.int64)
    done = 0
    while done < total:
        start = pos
        assert data[pos:pos + 4] == bytes([0xFF, 0xF8, 0xC0 | FLAC_RATE_CODES[rate], 0x08]), "frame header (block size, rate, channels)"
        lead = data[pos + 4]
        head = 5 if lead < 0x80 else (6 if lead < 0xE0 else 7)
        assert data[pos + head] == crc8(data[pos:pos + head]), "frame header CRC"
        assert ord(data[pos + 4:pos + head].decode("utf-8")) == done // BLOCK
        pos += head + 1
        window = data[pos:pos + 12000]                 # a frame is far smaller than this
        body = int.from_bytes(window, "big")
        total_bits = len(window) * 8
        ones = np.flatnonzero(np.unpackbits(np.frombuffer(window, dtype=np.uint8))).tolist()
        at, idx = 0, 0

        def take(width):
            nonlocal at
            at += width
            return (body >> (total_bits - at)) & ((1 << width) - 1)

        assert take(1) == 0
        kind = take(6)
        assert kind & 0x38 == 0x08
        order = kind & 7
        assert take(1) == 0
        warm = []
        for _ in range(order):
            v = take(16)
            warm.append(v - 65536 if v >= 32768 else v)
        assert take(2) == 0
        partition_order = take(4)
        size = BLOCK >> partition_order
        residual = []
        for p in range(1 << partition_order):
            k = take(4)
            for _ in range(size - (order if p == 0 else 0)):
                while ones[idx] < at:
                    idx += 1
                q = ones[idx] - at
                at = ones[idx] + 1
                u = (q << k) | (take(k) if k else 0)
                residual.append((u >> 1) if u % 2 == 0 else -((u + 1) >> 1))
        at += (-at) % 8
        pos += at // 8
        assert int.from_bytes(data[pos:pos + 2], "big") == crc16(data[start:pos]), "frame CRC"
        pos += 2
        out[done:done + BLOCK] = _undo_fixed(order, warm, residual)
        done += BLOCK
    return out, rate


def theme_json(cue_files, ambient=None, extra=None):
    doc = dict(THEME)
    if extra:
        doc.update(extra)
    doc["cues"] = cue_files
    if ambient:
        doc["ambient"] = ambient
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def build_theme(out_dir):
    """Writes Dreamglass into out_dir; returns the samples (for the checks)."""
    os.makedirs(out_dir, exist_ok=True)
    cues = render_cues(CUES)
    files = {}
    for name, samples in cues.items():
        files[name] = name + ".wav"
        write_wav(os.path.join(out_dir, name + ".wav"), samples)
    pad = make_pad(AMBIENT_RATE, AMBIENT_BLOCKS, PAD, AMBIENT_PEAK)
    with open(os.path.join(out_dir, "ambient.flac"), "wb") as f:
        f.write(encode_flac(pad, AMBIENT_RATE))
    loop_end = len(pad) * 1000 // AMBIENT_RATE
    write_text(os.path.join(out_dir, "theme.json"),
               theme_json(files, {"file": "ambient.flac", "loop": {"start": 0, "end": loop_end}, "gain": AMBIENT_GAIN}))
    write_text(os.path.join(out_dir, "README.md"), README)
    write_text(os.path.join(out_dir, "LICENSE-Sounds.txt"), LICENCE_TEXT)
    return cues, pad


# The example theme: one short tone per cue and an 8-second ambient, to show the format, nothing more.
EXAMPLE_RATE = 16000
EXAMPLE_PAD = ((110.0, 1.0, 1, 0.0, 0.002), (165.0, 0.6, 2, 0.3, 0.002))


def example_cues():
    table = {}
    for i, name in enumerate(CUES):
        freq = 440.0 * 2 ** (i / 12.0)
        table[name] = (0.30, SOFT, [(0.0, freq, 0.12, 1.0)])
    return render_cues(table)


def build_example(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cues = example_cues()
    files = {}
    for name, samples in cues.items():
        files[name] = name + ".wav"
        write_wav(os.path.join(out_dir, name + ".wav"), samples)
    pad = make_pad(EXAMPLE_RATE, 32, EXAMPLE_PAD, 0.3)       # 8.19 s
    with open(os.path.join(out_dir, "ambient.flac"), "wb") as f:
        f.write(encode_flac(pad, EXAMPLE_RATE))
    loop_end = len(pad) * 1000 // EXAMPLE_RATE
    write_text(os.path.join(out_dir, "theme.json"),
               theme_json(files, {"file": "ambient.flac", "loop": {"start": 0, "end": loop_end}, "gain": 0.7},
                          {"name": "Example theme", "version": "1.0.0"}))
    write_text(os.path.join(out_dir, "README.md"), EXAMPLE_README)
    return cues, pad


# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------
def tree_bytes(directory):
    result = {}
    for name in sorted(os.listdir(directory)):
        with open(os.path.join(directory, name), "rb") as f:
            result[name] = f.read()
    return result


def seam_is_smooth(loop):
    """The step from the last sample to the first is no bigger than the biggest step inside the loop."""
    x = loop.astype(np.int64)
    inner = int(np.max(np.abs(np.diff(x))))
    return abs(int(x[0]) - int(x[-1])) <= inner, abs(int(x[0]) - int(x[-1])), inner


def check_theme_dir(directory, label, problems, ambient_pad=None):
    for name, data in tree_bytes(directory).items():
        path = os.path.join(directory, name)
        if name.endswith(".wav"):
            samples, rate = read_wav(path)
            if rate != FS:
                problems.append("%s/%s: sample rate %d" % (label, name, rate))
            if len(samples) / rate > CUE_MAX_SECONDS:
                problems.append("%s/%s: longer than %.1f s" % (label, name, CUE_MAX_SECONDS))
            if len(data) > CUE_MAX_BYTES:
                problems.append("%s/%s: %d bytes" % (label, name, len(data)))
            if np.max(np.abs(samples)) / 32768.0 > CUE_PEAK_LIMIT:
                problems.append("%s/%s: peak above -3 dBFS" % (label, name))
        elif name == "ambient.flac":
            if len(data) > AMBIENT_MAX_BYTES:
                problems.append("%s/%s: %d bytes" % (label, name, len(data)))


def verify():
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        a, b = os.path.join(tmp, "a"), os.path.join(tmp, "b")
        cues, pad = build_theme(a)
        build_theme(b)
        if tree_bytes(a) != tree_bytes(b):
            problems.append("Dreamglass: two runs give different bytes")
        ex_a, ex_b = os.path.join(tmp, "ea"), os.path.join(tmp, "eb")
        ex_cues, ex_pad = build_example(ex_a)
        build_example(ex_b)
        if tree_bytes(ex_a) != tree_bytes(ex_b):
            problems.append("example: two runs give different bytes")
        check_theme_dir(a, "dreamglass", problems)
        check_theme_dir(ex_a, "example", problems)
        for label, loop in (("dreamglass ambient", pad), ("example ambient", ex_pad)):
            smooth, seam, inner = seam_is_smooth(loop)
            if not smooth:
                problems.append("%s: seam step %d is bigger than the biggest inner step %d" % (label, seam, inner))
            print("    %s: seam step %d, biggest inner step %d" % (label, seam, inner))
        # The FLAC must decode to the samples it was made from (the encoder is ours).
        with open(os.path.join(a, "ambient.flac"), "rb") as f:
            decoded, rate = decode_flac(f.read())
        if rate != AMBIENT_RATE or not np.array_equal(decoded, pad.astype(np.int64)):
            problems.append("dreamglass ambient.flac does not decode to the pad's samples")
        with open(os.path.join(ex_a, "ambient.flac"), "rb") as f:
            decoded, rate = decode_flac(f.read())
        if not np.array_equal(decoded, ex_pad.astype(np.int64)):
            problems.append("example ambient.flac does not decode to the pad's samples")
        # The repository holds what the generator writes now.
        for label, made, kept in (("dreamglass", a, os.path.join(REPO, "shell", "sounds", "dreamglass")),
                                  ("example", ex_a, os.path.join(REPO, "samples", "sound-theme-example"))):
            if not os.path.isdir(kept):
                problems.append("%s: %s is missing (run scripts/make-sounds.py)" % (label, kept))
                continue
            want, have = tree_bytes(made), tree_bytes(kept)
            if sorted(want) != sorted(have):
                problems.append("%s: files differ from the generator's: %s" % (label, sorted(set(want) ^ set(have))))
                continue
            for name in want:
                if name.endswith(".wav"):
                    x, _ = read_wav(os.path.join(made, name))
                    y, _ = read_wav(os.path.join(kept, name))
                    same = len(x) == len(y) and int(np.max(np.abs(x - y), initial=0)) <= 1
                elif name == "ambient.flac":
                    x, _ = decode_flac(want[name])
                    y, _ = decode_flac(have[name])
                    same = len(x) == len(y) and int(np.max(np.abs(x - y), initial=0)) <= 1
                elif name == "theme.json":
                    same = json.loads(want[name]) == json.loads(have[name])
                else:
                    same = want[name].replace(b"\r\n", b"\n") == have[name].replace(b"\r\n", b"\n")
                if not same:
                    problems.append("%s/%s: differs from the generator's output" % (label, name))
    for p in problems:
        print("FAIL: " + p)
    if not problems:
        print("    sound generator: deterministic, within the limits, seams smooth, FLAC round-trips, files up to date")
    return 1 if problems else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true", help="check determinism, limits, the loop seam and the files in the repo")
    ap.add_argument("--out", help="write Dreamglass to this folder only")
    args = ap.parse_args()
    if args.verify:
        return verify()
    if args.out:
        build_theme(args.out)
        print("wrote " + args.out)
        return 0
    dreamglass = os.path.join(REPO, "shell", "sounds", "dreamglass")
    example = os.path.join(REPO, "samples", "sound-theme-example")
    for folder in (dreamglass, example):
        if os.path.isdir(folder):
            shutil.rmtree(folder)
    build_theme(dreamglass)
    build_example(example)
    print("wrote " + dreamglass)
    print("wrote " + example)
    return 0


if __name__ == "__main__":
    sys.exit(main())
