#!/usr/bin/env python3
"""Ruya Input spike probes on the Dell (RUY-2 / T-366). Run as root on the console.

  scp scripts/dell-input-spike.py root@<dell>:/var/tmp/
  python3 /var/tmp/dell-input-spike.py pad --acl ruya-p1 --seconds 120
      Creates a virtual Xbox 360-style pad (uinput, 045e:028e) the way the input service
      would, gives its event node one ACL entry for the user, prints the node and waits.
  python3 /var/tmp/dell-input-spike.py latency --runs 200
      Creates the same pad, waits until ruya-inputd opens it, then presses D-pad left/right
      (focus moves on the shell) and measures, per press, the time from the write on the
      source pad to the read of (a) the source node itself and (b) the key ruya-inputd
      emits on "RuyaOS Navigation". (b) - (a) is what the service adds.

Nothing is changed on the machine: the pad disappears when the script ends.
"""
import argparse
import fcntl
import glob
import os
import select
import statistics
import struct
import subprocess
import sys
import time

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN = {"south": 0x130, "east": 0x131, "north": 0x133, "west": 0x134, "tl": 0x136, "tr": 0x137,
       "select": 0x13A, "start": 0x13B, "mode": 0x13C, "thumbl": 0x13D, "thumbr": 0x13E}
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y = 0, 1, 2, 3, 4, 5, 0x10, 0x11
KEY_LEFT, KEY_RIGHT = 105, 106

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_DEV_SETUP = 0x405C5503
UI_ABS_SETUP = 0x401C5504
UI_SET_PHYS = 0x4008556C
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_GET_SYSNAME_64 = 0x8040552C  # _IOC(_IOC_READ, 'U', 44, 64)
EVIOCSCLOCKID = 0x400445A0
CLOCK_MONOTONIC = 1
EVENT = struct.Struct("llHHi")
NAME = "Ruya Spike Xbox 360 Pad"


def make_pad(phys=None):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    if phys:
        fcntl.ioctl(fd, UI_SET_PHYS, phys.encode() + b"\0")
    for ev in (EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for code in BTN.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    axes = [(ABS_X, -32768, 32767, 16, 128), (ABS_Y, -32768, 32767, 16, 128),
            (ABS_RX, -32768, 32767, 16, 128), (ABS_RY, -32768, 32767, 16, 128),
            (ABS_Z, 0, 255, 0, 0), (ABS_RZ, 0, 255, 0, 0),
            (ABS_HAT0X, -1, 1, 0, 0), (ABS_HAT0Y, -1, 1, 0, 0)]
    for code, lo, hi, fuzz, flat in axes:
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
        # struct uinput_abs_setup { __u16 code; struct input_absinfo { value, min, max, fuzz, flat, res } }
        fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("HxxiiiiiI", code, 0, lo, hi, fuzz, flat, 0))
    # struct uinput_setup { struct input_id { bustype, vendor, product, version }; char name[80]; __u32 ff_effects_max }
    setup = struct.pack("HHHH80sI", 0x03, 0x045E, 0x028E, 0x0114, NAME.encode(), 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    buf = bytearray(64)
    fcntl.ioctl(fd, UI_GET_SYSNAME_64, buf)
    sysname = buf.split(b"\0", 1)[0].decode()
    node = None
    for _ in range(100):
        found = glob.glob(f"/sys/devices/virtual/input/{sysname}/event*")
        if found:
            node = "/dev/input/" + os.path.basename(found[0])
            if os.path.exists(node):
                break
        time.sleep(0.02)
    return fd, node


def emit(fd, etype, code, value):
    os.write(fd, EVENT.pack(0, 0, etype, code, value) + EVENT.pack(0, 0, EV_SYN, 0, 0))


def open_reader(path):
    rfd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    fcntl.ioctl(rfd, EVIOCSCLOCKID, struct.pack("i", CLOCK_MONOTONIC))
    return rfd


def wait_for(rfd, etype, code, value, timeout=0.5):
    end = time.monotonic() + timeout
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return None
        r, _, _ = select.select([rfd], [], [], left)
        if not r:
            return None
        data = os.read(rfd, EVENT.size * 64)
        now = time.monotonic()
        for i in range(0, len(data), EVENT.size):
            _, _, t, c, v = EVENT.unpack_from(data, i)
            if t == etype and c == code and v == value:
                return now


def nav_node():
    for d in glob.glob("/sys/class/input/event*"):
        try:
            if open(d + "/device/name").read().strip() == "RuyaOS Navigation":
                return "/dev/input/" + os.path.basename(d)
        except OSError:
            pass
    return None


def cmd_pad(args):
    fd, node = make_pad(args.phys)
    print(f"pad: {NAME} at {node} (uid {os.getuid()}, phys {args.phys})")
    if args.acl:
        time.sleep(1.0)  # let udev finish the add event: its uaccess builtin flushes the ACL
        subprocess.run(["setfacl", "-m", f"u:{args.acl}:rw", node], check=True)
        print(subprocess.run(["getfacl", "-p", node], capture_output=True, text=True).stdout.strip())
    sys.stdout.flush()
    try:
        time.sleep(args.seconds)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        print("pad: destroyed")


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))]


def cmd_latency(args):
    nav = nav_node()
    if not nav:
        sys.exit("no RuyaOS Navigation device: is ruya-inputd running?")
    fd, node = make_pad()
    src = open_reader(node)
    dst = open_reader(nav)
    time.sleep(3.0)  # ruya-inputd rescans every 2 s
    direct, routed, misses = [], [], 0
    for i in range(args.runs):
        hat, key = (-1, KEY_LEFT) if i % 2 == 0 else (1, KEY_RIGHT)
        t0 = time.monotonic()
        emit(fd, EV_ABS, ABS_HAT0X, hat)
        a = wait_for(src, EV_ABS, ABS_HAT0X, hat)
        b = wait_for(dst, EV_KEY, key, 1)
        emit(fd, EV_ABS, ABS_HAT0X, 0)
        wait_for(dst, EV_KEY, key, 0)
        if a is None or b is None:
            misses += 1
        else:
            direct.append((a - t0) * 1e6)
            routed.append((b - t0) * 1e6)
        time.sleep(args.gap)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    if not routed:
        sys.exit(f"no routed key seen in {args.runs} presses (misses {misses})")
    added = [r - d for r, d in zip(routed, direct)]
    for label, vals in (("source node", direct), ("via ruya-inputd", routed), ("added by ruya-inputd", added)):
        print(f"{label:22s} n={len(vals)} median={statistics.median(vals):7.0f} us "
              f"p90={pct(vals, 0.9):7.0f} us max={max(vals):7.0f} us")
    print(f"misses={misses}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pad")
    p.add_argument("--acl")
    p.add_argument("--phys", help="e.g. ruya-input/p1: what a udev rule matches to hand the node to the service")
    p.add_argument("--seconds", type=float, default=60)
    lat = sub.add_parser("latency")
    lat.add_argument("--runs", type=int, default=200)
    lat.add_argument("--gap", type=float, default=0.05)
    args = ap.parse_args()
    {"pad": cmd_pad, "latency": cmd_latency}[args.cmd](args)


if __name__ == "__main__":
    main()
