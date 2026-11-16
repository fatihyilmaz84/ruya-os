#!/usr/bin/env python3
"""Wake the TV from the shell's idle screen: one Left Shift press from a
throw-away uinput keyboard (the pattern of scripts/dell-glass-check.sh)."""
import fcntl, os, struct, time

def emit(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)          # UI_SET_EVBIT EV_KEY
fcntl.ioctl(fd, 0x40045565, 42)         # UI_SET_KEYBIT KEY_LEFTSHIFT
fcntl.ioctl(fd, 0x405C5503, struct.pack("HHHH80sI", 3, 0x1209, 2, 1, b"ruy91-wake".ljust(80, b"\0"), 0))
fcntl.ioctl(fd, 0x5501)                 # UI_DEV_CREATE
try:
    time.sleep(1.5)
    for v in (1, 0):
        emit(fd, 1, 42, v)
        emit(fd, 0, 0, 0)
        time.sleep(0.1)
    time.sleep(0.5)
finally:
    fcntl.ioctl(fd, 0x5502)             # UI_DEV_DESTROY
    os.close(fd)
