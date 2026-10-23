#!/usr/bin/env python3
"""Lists the sounds in a wav that QEMU recorded from the VM (smoke-test.ps1 -Audio -AudioBackend wav).

QEMU's wav backend leaves the RIFF sizes at zero, so the standard `wave` module refuses the file;
this reads the format from the header and the samples after it. A burst is a run of samples above
the threshold, split by silences of more than --gap seconds.

  python scripts/vm-audio-bursts.py [output/vm-audio.wav] [--threshold 50] [--gap 0.2]
"""
import argparse
import struct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default="output/vm-audio.wav")
    ap.add_argument("--threshold", type=int, default=50)
    ap.add_argument("--gap", type=float, default=0.2)
    args = ap.parse_args()

    data = open(args.path, "rb").read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE" or data[12:16] != b"fmt ":
        raise SystemExit("not a wav file")
    channels, rate, bits = struct.unpack_from("<H I 4x H", data, 22)[0], struct.unpack_from("<I", data, 24)[0], struct.unpack_from("<H", data, 34)[0]
    if bits != 16:
        raise SystemExit(f"expected 16-bit samples, got {bits}")
    pos = data.index(b"data", 36) + 8
    count = (len(data) - pos) // 2
    samples = struct.unpack_from("<%dh" % count, data, pos)
    per_second = rate * channels

    loud = [i for i, v in enumerate(samples) if abs(v) > args.threshold]
    print(f"{channels} ch, {rate} Hz, {count / per_second:.1f} s, peak {max(map(abs, samples), default=0)}, "
          f"{len(loud)} samples above {args.threshold}")
    if not loud:
        print("silence")
        return
    bursts = []
    start = last = loud[0]
    for i in loud[1:]:
        if i - last > per_second * args.gap:
            bursts.append((start, last))
            start = i
        last = i
    bursts.append((start, last))
    print(f"{len(bursts)} bursts (start s - end s):")
    for a, b in bursts:
        print(f"  {a / per_second:7.2f} - {b / per_second:7.2f}  ({(b - a) / per_second * 1000:.0f} ms)")


if __name__ == "__main__":
    main()
