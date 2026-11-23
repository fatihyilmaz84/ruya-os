#!/usr/bin/env python3
"""Host test of scripts/dell-perf-stats.py (RUY-842): the perf-frames journal lines to numbers, the runs
file to JSON and summary, and --compare with its noise band. Run by scripts/test-vm-checks.sh. Prints
"    ok   ..." and "    FAIL ..." lines like that script; exit 1 on a failure."""
import importlib.util
import json
import os
import sys
import tempfile

sys.dont_write_bytecode = True
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dell_perf_stats", os.path.join(here, "dell-perf-stats.py"))
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)

failed = 0


def check(name, ok, detail=""):
    global failed
    print(f"    {'ok  ' if ok else 'FAIL'} {name}{'' if ok else ': ' + str(detail)}")
    failed += 0 if ok else 1


def line(ts, fps, full, mean, p99):
    return (f"{ts:.6f} dell ruya-shell[1]: ruya-shell: perf-frames fps={fps} full={full} commits={fps} "
            f"meanMs={mean} p99Ms={p99}")


# A launch at 100.0, the game's first frame at 100.5, full speed at 102, then 10 s at 60 FPS with one
# slow second (a 40 ms frame); the meter logs four times a second, so only one line in four is a new second.
journal = ["99.000000 dell systemd[1]: Starting ruya-app-ruya-p1-old.service - [systemd-run] flatpak run old...",
           "100.100000 dell systemd[1]: Starting ruya-app-ruya-p1-net.supertuxkart.SuperTuxKart.service - run...",
           line(100.2, 0, 0, -1.0, -1.0),
           line(100.5, 3, 0, 65.9, 100.1),
           line(101.0, 30, 0, 30.0, 90.0),
           line(102.0, 58, 1, 17.0, 20.0)]
t = 110.0
for i in range(41):
    ts = t + i * 0.25
    journal.append(line(ts, 60, 1, 16.7, 17.0))
for i in range(12):   # one perf-frame-intervals line a second; the one at 115.5 holds a 40 ms frame
    vals = ["16.70"] * 60
    if i == 5:
        vals[10] = "40.00"
    journal.append(f"{110.5 + i:.6f} dell ruya-shell[1]: ruya-shell: perf-frame-intervals {','.join(vals)}")
text = "\n".join(journal)

out = stats.frames(text, 110.0, 120.0, 100.0)
check("frames: cold start is the launch to the first frame", out.get("cold_start_s") == 0.4, out)
check("frames: full speed is the first full second at 90 % of fps", out.get("steady_s") == 1.9, out)
check("frames: one line per second", out.get("seconds") == 10, out)
check("frames: fps is the mean", out.get("fps") == 60.0, out)
check("frames: p50 is the median interval", out.get("ft_p50_ms") == 16.7, out)
check("frames: p99 of 600 intervals is the 594th", out.get("ft_p99_ms") == 16.7, out)
check("frames: p99.9 of 600 intervals is the 600th, the slow frame", out.get("ft_p999_ms") == 40.0, out)
check("frames: worst frame", out.get("ft_worst_ms") == 40.0, out)
check("frames: a frame over twice the median is a stutter frame", out.get("stutter") == 1, out)
check("frames: only the lines inside the window count", out.get("ft_lines") == 10, out)
old_image = stats.frames(chr(10).join(l for l in journal if "intervals" not in l), 110.0, 120.0, 100.0)
check("frames: an image without the intervals line has fps but no frame times",
      old_image.get("fps") == 60.0 and "ft_p99_ms" not in old_image, old_image)
check("rank: nearest rank on a short list", stats.rank([1.0, 2.0, 3.0, 4.0], 0.99) == 4.0 and stats.rank([1.0, 2.0, 3.0, 4.0], 0.5) == 2.0)
check("frames: lines outside the window are ignored", stats.frames(text, 200.0, 210.0, 100.0).get("fps") is None)
check("frames: lines of a window that is not full are ignored",
      stats.frames("\n".join(journal[:4]), 100.0, 101.0, 100.0).get("fps") is None)
check("frames: an earlier launch line is not the start",
      stats.frames("\n".join(journal[:1] + journal[3:]), 99.5, 110.0, 99.5).get("cold_start_s") is None)

runs = "\n".join([
    "supertuxkart\tfps=60.0\tft_p50_ms=16.7\tshell_cpu_pct=12.5\trelay_p50_ms=0.1",
    "supertuxkart\tfps=59.0\tft_p50_ms=16.9\tshell_cpu_pct=13.5\trelay_skipped=no_virtual_pad",
    "supertuxkart\tfps=60.0\tft_p50_ms=16.7\tshell_cpu_pct=12.0",
    "play\tskipped=play.x_is_not_installed",
    "home\tshell_cpu_pct=20.0\tpower_w=3.5", ""])
items = stats.parse_runs(runs)
check("parse_runs: three runs of an item", len(items["supertuxkart"]["runs"]) == 3)
check("parse_runs: numbers are numbers, text stays text",
      items["supertuxkart"]["runs"][1]["fps"] == 59.0 and items["supertuxkart"]["runs"][1]["relay_skipped"] == "no_virtual_pad")
check("parse_runs: a skipped item has no runs", items["play"] == {"runs": [], "skipped": "play.x_is_not_installed"})

with tempfile.TemporaryDirectory() as tmp:
    tsv = os.path.join(tmp, "runs.tsv")
    open(tsv, "w", encoding="utf-8").write(runs)
    outs = []
    for label, fps_bump in (("a", 0.0), ("b", 0.0), ("c", -9.0)):
        path = os.path.join(tmp, label + ".json")
        text_runs = runs if not fps_bump else runs.replace("fps=60.0", "fps=51.0").replace("fps=59.0", "fps=50.0")
        open(tsv, "w", encoding="utf-8").write(text_runs)
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            stats.build([tsv, label, "0.0.105", "dell", "2026-11-23", path])
        outs.append((path, buf.getvalue()))
    doc = json.load(open(outs[0][0], encoding="utf-8"))
    check("build: the JSON has the label, the image and the items",
          doc["label"] == "a" and doc["image"] == "0.0.105" and set(doc["items"]) == {"supertuxkart", "play", "home"})
    summary = outs[0][1].splitlines()
    check("build: the summary is at most 15 lines", 0 < len(summary) <= 15, len(summary))
    check("build: the summary shows median and spread", any("FPS 60 (59-60)" in s for s in summary), summary)
    check("build: a skipped item and a skipped relay say so",
          any("play: SKIPPED" in s for s in summary) and any("relay latency SKIPPED" in s for s in summary), summary)

    def compare(a, b):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            stats.compare([a, b])
        return buf.getvalue()
    same = compare(outs[0][0], outs[1][0])
    check("compare: equal runs are within noise", "WORSE" not in same and "better" not in same and "within noise" in same, same)
    worse = compare(outs[0][0], outs[2][0])
    fps_line = next(s for s in worse.splitlines() if "FPS" in s)
    check("compare: a drop beyond the spread is WORSE for FPS", fps_line.rstrip().endswith("WORSE"), fps_line)
    better = compare(outs[2][0], outs[0][0])
    check("compare: a rise is better for FPS", next(s for s in better.splitlines() if "FPS" in s).rstrip().endswith("better"))
    check("compare: an item that was skipped is named", "play: not in both" in worse, worse)

sys.exit(1 if failed else 0)
