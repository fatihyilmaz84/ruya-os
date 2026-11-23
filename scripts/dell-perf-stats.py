#!/usr/bin/env python3
"""The numbers side of scripts/dell-perf-bench.sh (RUY-842), run on the host (python3 or python).

  dell-perf-stats.py frames <journal> <t1> <t2> <launch>
      <journal>: `journalctl -o short-unix` lines of the Dell. Prints "key=value ..." for the window
      t1..t2 (epoch seconds) of the shell's perf-frames lines (RUYA_PERF_LOG=1, the compositor's frame
      meter, RUY-347) and the cold start after <launch>. Prints nothing when the window has no frame.
  dell-perf-stats.py build <runs.tsv> <label> <image> <host> <date> <out.json>
      <runs.tsv>: one line per run, `item<TAB>key=value<TAB>key=value...` (an item that did not run:
      `item<TAB>skipped=<reason>`). Writes the JSON and prints the summary (at most 15 lines).
  dell-perf-stats.py compare <a.json> <b.json>
      The difference of every number with its noise band.

The frame meter logs, four times a second, the last second's frame count, mean and p99 frame time
(the p99 of fewer than 100 frames is the slowest frame of that second). Windows a second apart do not
overlap, so the script keeps one line per second and works from those:
  fps         mean frames per second
  ft_p50_ms   median of the seconds' mean frame times (the typical frame)
  ft_slow_ms  mean of the seconds' slowest frame
  ft_worst_ms the slowest frame of the window
  stutter     seconds that held a frame over twice ft_p50_ms
  cold_start_s  the launch ("Starting ruya-app-*.service") to the first presented frame
  steady_s      the launch to the first full second at 90 % of fps
The raw frame times are not in the log: a true p99 and p99.9 over all frames need the shell to log them.
"""
import json
import re
import statistics
import sys

FRAMES = re.compile(r"^(\d+\.\d+) .*perf-frames fps=(\d+) full=(\d) commits=(\d+) meanMs=([\d.]+) p99Ms=([\d.]+)")
STARTING = re.compile(r"^(\d+\.\d+) .*Starting ruya-app-")

# metric -> (label, unit, better): better is "high" or "low"
METRICS = {
    "fps": ("FPS", "", "high"),
    "ft_p50_ms": ("frame p50", "ms", "low"),
    "ft_slow_ms": ("frame slowest/s", "ms", "low"),
    "ft_worst_ms": ("frame worst", "ms", "low"),
    "stutter": ("stutter seconds", "", "low"),
    "cold_start_s": ("cold start", "s", "low"),
    "steady_s": ("full speed after", "s", "low"),
    "shell_cpu_pct": ("shell CPU", "% core", "low"),
    "shell_gpu_pct": ("shell GPU", "%", "low"),
    "power_w": ("package power", "W", "low"),
    "temp_c": ("package temp", "C", "low"),
    "relay_p50_ms": ("relay p50", "ms", "low"),
    "relay_p99_ms": ("relay p99", "ms", "low"),
}


def frames(text, t1, t2, launch):
    rows = []
    start = None
    for line in text.splitlines():
        m = STARTING.match(line)
        if m and start is None and float(m.group(1)) >= launch:
            start = float(m.group(1))
        m = FRAMES.match(line)
        if m:
            rows.append((float(m.group(1)), int(m.group(2)), int(m.group(3)), float(m.group(5)), float(m.group(6))))
    out = {}
    if start is not None:
        first = next((r[0] for r in rows if r[0] > start and r[1] > 0), None)
        if first is not None:
            out["cold_start_s"] = round(first - start, 2)
    kept = []   # one line per second: the windows then do not overlap
    for r in rows:
        if t1 <= r[0] < t2 and r[2] == 1 and (not kept or r[0] - kept[-1][0] >= 1.0):
            kept.append(r)
    if not kept:
        return out
    p50 = statistics.median(r[3] for r in kept)
    out["fps"] = round(statistics.mean(r[1] for r in kept), 1)
    out["ft_p50_ms"] = round(p50, 1)
    out["ft_slow_ms"] = round(statistics.mean(r[4] for r in kept), 1)
    out["ft_worst_ms"] = round(max(r[4] for r in kept), 1)
    out["stutter"] = sum(1 for r in kept if r[4] > 2 * p50)
    out["seconds"] = len(kept)
    if start is not None:
        steady = next((r[0] for r in rows if r[0] > start and r[2] == 1 and r[1] >= 0.9 * out["fps"]), None)
        if steady is not None:
            out["steady_s"] = round(steady - start, 2)
    return out


def parse_runs(text):
    items = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        item, *fields = line.rstrip("\n").split("\t")
        entry = items.setdefault(item, {"runs": []})
        kv = dict(f.split("=", 1) for f in fields if "=" in f)
        if "skipped" in kv:
            entry["skipped"] = kv["skipped"]
            continue
        entry["runs"].append({k: num(v) for k, v in kv.items()})
    return items


def num(v):
    try:
        return float(v) if "." in v else int(v)
    except ValueError:
        return v


def values(item, metric):
    return [r[metric] for r in item.get("runs", []) if isinstance(r.get(metric), (int, float))]


def fmt(vals):
    """median (min-max) of a metric's runs."""
    if not vals:
        return "-"
    med = statistics.median(vals)
    return f"{med:g} ({min(vals):g}-{max(vals):g})" if len(vals) > 1 else f"{med:g}"


def with_unit(metric, vals):
    unit = METRICS[metric][1]
    return f"{fmt(vals)}{(' ' + unit) if unit else ''}"


def summary(doc):
    lines = [f"{doc['label']}  {doc['date']}  image {doc['image']}  host {doc['host']}  (median (min-max) of the runs)"]
    for name, item in doc["items"].items():
        if "skipped" in item and not item["runs"]:
            lines.append(f"{name}: SKIPPED ({item['skipped'].replace('_', ' ')})")
            continue
        groups = [("fps", "ft_p50_ms", "ft_slow_ms", "ft_worst_ms", "stutter"),
                  ("cold_start_s", "steady_s", "shell_cpu_pct", "shell_gpu_pct", "power_w", "temp_c"),
                  ("relay_p50_ms", "relay_p99_ms")]
        first = True
        for group in groups:
            parts = [f"{METRICS[m][0]} {with_unit(m, values(item, m))}" for m in group if values(item, m)]
            if parts:
                lines.append(f"{name + ' (' + str(len(item['runs'])) + ' runs)' if first else '':<22}" + ", ".join(parts))
                first = False
        reasons = sorted({r["relay_skipped"] for r in item["runs"] if "relay_skipped" in r})
        if reasons:
            count = sum(1 for r in item["runs"] if "relay_skipped" in r)
            lines.append(f"{'':<22}relay latency SKIPPED in {count} of {len(item['runs'])} runs ({reasons[0].replace('_', ' ')})")
    return lines[:15]


def build(args):
    runs, label, image, host, date, out = args
    items = parse_runs(open(runs, encoding="utf-8").read())
    doc = {"schema": 1, "label": label, "date": date, "image": image, "host": host, "items": items}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print("\n".join(summary(doc)))


def judge(metric, a, b):
    """Verdict of b against a: inside the noise band (the larger run-to-run spread of the two) or not."""
    band = max(max(a) - min(a), max(b) - min(b))
    delta = statistics.median(b) - statistics.median(a)
    if abs(delta) <= band:
        return delta, band, "within noise"
    good = (delta > 0) == (METRICS[metric][2] == "high")
    return delta, band, "better" if good else "WORSE"


def compare(args):
    a, b = (json.load(open(p, encoding="utf-8")) for p in args)
    print(f"{a['label']} {a['date']} (image {a['image']})  ->  {b['label']} {b['date']} (image {b['image']}); "
          "noise band = the larger run-to-run spread")
    for name in a["items"]:
        ia, ib = a["items"][name], b["items"].get(name)
        if ib is None or not ia["runs"] or not ib["runs"]:
            print(f"{name}: not in both")
            continue
        for m in METRICS:
            va, vb = values(ia, m), values(ib, m)
            if not va or not vb:
                continue
            delta, band, verdict = judge(m, va, vb)
            print(f"{name:<14}{METRICS[m][0]:<18}{fmt(va):<22} -> {fmt(vb):<22} {delta:+.2f} (band {band:.2f})  {verdict}")


def main(argv):
    if len(argv) >= 6 and argv[1] == "frames":
        out = frames(open(argv[2], encoding="utf-8", errors="replace").read(), float(argv[3]), float(argv[4]), float(argv[5]))
        print(" ".join(f"{k}={v}" for k, v in out.items()))
    elif len(argv) == 8 and argv[1] == "build":
        build(argv[2:])
    elif len(argv) == 4 and argv[1] == "compare":
        compare(argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
