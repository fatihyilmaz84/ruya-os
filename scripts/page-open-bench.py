#!/usr/bin/env python3
"""Times page opens on a real console (T-349): drives the shell with a throw-away uinput keyboard and
summarises the shell's own probe lines from the journal,

  ruya-shell: page-open <key> create=<ms> firstSwap=<ms> afterAnim=<ms> frames=<n> maxFrame=<ms>

(milliseconds from the key press; maxFrame is the longest gap between two frames of the transition,
docs/specs/02-shell.md section 1). Run it as root on the console (the Dell), with a profile signed in,
on Home, nothing open:

  scp -i ~/.ssh/<key> scripts/page-open-bench.py root@<dell>:/root/
  ssh -i ~/.ssh/<key> root@<dell> python3 /root/page-open-bench.py --runs 10 --label "0.0.56 high"

Scenarios (each run starts and ends on Home; --scenario picks one, default all three). Each first goes
to the nav's Home pill (Up x3, Left x4), then:
  home-settings   Right x4, Accept: Home -> Settings, then Back
  store-settings  Right x3, Accept (Store), RB: Store -> Settings, then Back
  store-games     Right x3, Accept (Store), Up x3 (the nav), Left x2, Accept: Store -> Games, then Back

The first run of a scenario is printed apart from the rest (the first open builds more: the QML
types, the singletons, the shader pipelines). For "first open after boot", reboot, sign in and run
with --runs 1. The effects tier is the owner's setting: switch it in Settings -> Display & motion
between two runs and give each a --label. The A/B of T-349 is this script on the image before the
change and on the image after it, both tiers. With QSG_RENDER_TIMING=1 in a drop-in of the
compositor unit (systemctl edit ruya-compositor@tty1; restart it; remove the drop-in afterwards) the
journal also carries Qt's per-frame render times, which --raw prints next to the probe lines.
"""
import argparse
import fcntl
import os
import re
import statistics
import struct
import subprocess
import sys
import time

KEY = {"up": 103, "down": 108, "left": 105, "right": 106, "accept": 28, "back": 1,
       "lb": 104, "rb": 109}

# From Play, the Recent row or any pill: Up until the nav (Up there is swallowed), then the Home pill.
TO_NAV = ["up", "up", "up", "left", "left", "left", "left"]
SCENARIOS = {
    "home-settings": (TO_NAV + ["right"] * 4 + ["accept"], "settings", ["settings"]),
    "store-settings": (TO_NAV + ["right"] * 3 + ["accept", "!settle", "rb"], "settings", ["store", "settings"]),
    "store-games": (TO_NAV + ["right"] * 3 + ["accept", "!settle", "up", "up", "up", "left", "left", "accept"],
                    "games", ["store", "games"]),
}

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
LINE = re.compile(r"ruya-shell: page-open (\S+) create=(\d+) firstSwap=(\d+) afterAnim=(\d+)"
                  r" frames=(\d+) maxFrame=(\d+)")
FIELDS = ["create", "firstSwap", "afterAnim", "maxFrame"]


class Keyboard:
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in KEY.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        name = b"ruya-bench-keyboard".ljust(80, b"\0")
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1209, 0x0002, 1, name, 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(1.5)  # let udev and the compositor adopt the new device

    def emit(self, etype, code, value):
        os.write(self.fd, struct.pack("llHHi", 0, 0, etype, code, value))

    def press(self, name, gap):
        self.emit(EV_KEY, KEY[name], 1)
        self.emit(EV_SYN, 0, 0)
        time.sleep(0.03)
        self.emit(EV_KEY, KEY[name], 0)
        self.emit(EV_SYN, 0, 0)
        time.sleep(gap)

    def close(self):
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def shell_uid():
    return subprocess.run(["id", "-u", "ruya-shell"], check=True, capture_output=True, text=True).stdout.strip()


def journal_since(uid, since):
    out = subprocess.run(["journalctl", "-b", "-q", "-o", "cat", "--no-pager", "_UID=" + uid,
                          "--since", "@%.3f" % since], capture_output=True, text=True).stdout
    return out.splitlines()


def run_once(kb, uid, name, gap, settle):
    keys, want, expected = SCENARIOS[name]
    since = time.time()
    for k in keys:
        if k == "!settle":
            time.sleep(settle)
        else:
            kb.press(k, gap)
    time.sleep(settle)
    lines = journal_since(uid, since - 0.5)
    probes = [m for m in (LINE.search(l) for l in lines) if m]
    keys_seen = [m.group(1) for m in probes]
    kb.press("back", gap)
    time.sleep(settle)
    if keys_seen[-len(expected):] != expected:
        raise RuntimeError("%s: expected page-open lines for %s, saw %s (is the shell on Home, nothing open?)"
                           % (name, expected, keys_seen or "none"))
    m = probes[-1]
    assert m.group(1) == want
    row = {"create": int(m.group(2)), "firstSwap": int(m.group(3)), "afterAnim": int(m.group(4)),
           "frames": int(m.group(5)), "maxFrame": int(m.group(6))}
    return row, lines


def summary(rows):
    out = []
    for f in FIELDS:
        vals = sorted(r[f] for r in rows)
        p90 = vals[min(len(vals) - 1, int(round(0.9 * (len(vals) - 1))))]
        out.append("%s med %d p90 %d max %d" % (f, statistics.median(vals), p90, vals[-1]))
    return " | ".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--scenario", choices=sorted(SCENARIOS) + ["all"], default="all")
    ap.add_argument("--label", default="", help="printed with the results (image version, tier)")
    ap.add_argument("--gap", type=float, default=0.35, help="seconds after each key")
    ap.add_argument("--settle", type=float, default=1.2, help="seconds for a page to open or close")
    ap.add_argument("--raw", action="store_true", help="print every journal line of each run")
    args = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("run as root (it opens /dev/uinput and reads the shell's journal)")

    uid = shell_uid()
    names = sorted(SCENARIOS) if args.scenario == "all" else [args.scenario]
    kb = Keyboard()
    try:
        results = {}
        for name in names:
            rows = []
            for i in range(args.runs):
                row, lines = run_once(kb, uid, name, args.gap, args.settle)
                rows.append(row)
                if args.raw:
                    print("--- %s run %d" % (name, i + 1))
                    for l in lines:
                        print("   ", l)
                print("%s run %d: create=%d firstSwap=%d afterAnim=%d frames=%d maxFrame=%d"
                      % (name, i + 1, row["create"], row["firstSwap"], row["afterAnim"], row["frames"], row["maxFrame"]))
            results[name] = rows
    finally:
        kb.close()

    print()
    print("page-open bench %s, %d run(s) per scenario (ms)" % (args.label, args.runs))
    for name in names:
        rows = results[name]
        first = rows[0]
        print("%-15s first: create %d firstSwap %d afterAnim %d maxFrame %d"
              % (name, first["create"], first["firstSwap"], first["afterAnim"], first["maxFrame"]))
        if len(rows) > 1:
            print("%-15s rest:  %s" % ("", summary(rows[1:])))
            over = sum(1 for r in rows[1:] if r["maxFrame"] > 33)
            print("%-15s        runs with a frame over 33 ms: %d of %d" % ("", over, len(rows) - 1))


if __name__ == "__main__":
    main()
