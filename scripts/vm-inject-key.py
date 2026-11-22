#!/usr/bin/env python3
"""Presses a key that QEMU's USB keyboard cannot send, from inside the guest (T-120).

`sendkey` reaches the guest as a USB keyboard, which has no consumer-page keys, so the Guide
key (KEY_HOMEPAGE, what ruya-inputd emits for the controller's Guide button) is out of reach.
This creates a throw-away uinput keyboard in the guest, so cage and the shell see the same key
event the daemon would produce. Run it as root in the VM:

  scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-inject-key.py scripts/vm_uinput_trust.py root@127.0.0.1:/root/
  ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 python3 /root/vm-inject-key.py guide [--hold 2.5]
  ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 python3 /root/vm-inject-key.py down right return

Keys: guide (KEY_HOMEPAGE), menu (KEY_COMPOSE, the key xkb turns into Qt.Key_Menu; RUY-583), home (KEY_HOME), meta (KEY_LEFTMETA), back (KEY_ESC, Back; RUY-597), up/down/left/right and return (the arrows and Enter, to drive the Hub: RUY-611).
Several keys in one call are pressed one after the other on one device (the device takes 1.5 s to be adopted).
--hold N keeps the key down for N seconds (the Guide long press); the guest's key repeat
applies as it would for a real held key.
Root vouches for the keyboard (vm_uinput_trust.py, next to this script; RUY-1063): a uinput device
nobody vouched for is foreign, and the shell never reads it.
"""
import argparse
import fcntl
import os
import struct
import time

import vm_uinput_trust

KEYS = {"guide": 172, "menu": 127, "home": 102, "meta": 125, "back": 1,
        "up": 103, "left": 105, "right": 106, "down": 108, "return": 28}

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502


def emit(fd, etype, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, etype, code, value))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("key", choices=sorted(KEYS), nargs="+")
    ap.add_argument("--hold", type=float, default=0.1, help="seconds to keep the key down")
    args = ap.parse_args()
    codes = [KEYS[k] for k in args.key]

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in codes:
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    name = b"ruya-test-keyboard".ljust(80, b"\0")
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1209, 0x0001, 1, name, 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    trusted = vm_uinput_trust.trust(fd)
    try:
        time.sleep(1.5)  # let the shell's libinput adopt the new device
        for code in codes:
            emit(fd, EV_KEY, code, 1)
            emit(fd, EV_SYN, 0, 0)
            time.sleep(args.hold)
            emit(fd, EV_KEY, code, 0)
            emit(fd, EV_SYN, 0, 0)
            time.sleep(0.4)
        time.sleep(0.1)
    finally:
        vm_uinput_trust.untrust(trusted)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
    print(f"injected {' '.join(args.key)} (hold {args.hold}s)")


if __name__ == "__main__":
    main()
