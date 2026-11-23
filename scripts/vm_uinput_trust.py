"""Root vouches for the uinput devices a VM or Dell check makes (06-input.md section 3 rule 1, RUY-1063).

Since RUY-1063 a parentless input device (made through /dev/uinput) is foreign unless a marker names
it: foreign devices reach neither the shell's libinput nor ruya-inputd's pad reader. A check's
stand-in pad or keyboard is made by root, so root marks it in /run/ruya-input-trusted (root-only,
tmpfiles) and the udev rules treat it as hardware. Use it right after UI_DEV_CREATE and before
UI_DEV_DESTROY:

    name = trust(fd)        # after UI_DEV_CREATE: marked, and udev has processed it as "trusted"
    ...
    untrust(name)           # before UI_DEV_DESTROY

The marker can only be written once the kernel named the device, so udev may have processed the
device's "add" before it (then the device is foreign, and libinput, which reads a device only at its
"add", never takes it). trust() waits for udev to finish what the kernel has sent (`udevadm settle`)
and, when the node is not "trusted", replays its "add" (root writes the node's uevent file), so the
device is hardware for every reader. Copy this file next to the script that imports it.
"""
import fcntl
import glob
import os
import subprocess

TRUSTED_DIR = "/run/ruya-input-trusted"
UI_GET_SYSNAME = 0x8040552C  # _IOC(_IOC_READ, 'U', 44, 64)


def sysname(fd):
    """The input device's name (input23) of a created uinput fd."""
    buf = bytearray(64)
    fcntl.ioctl(fd, UI_GET_SYSNAME, buf)
    return bytes(buf).split(b"\0", 1)[0].decode()


def origin(devpath):
    """RUYA_INPUT_ORIGIN of a device in udev's database ("" when it has none)."""
    out = subprocess.run(["udevadm", "info", "-q", "property", "-p", devpath],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("RUYA_INPUT_ORIGIN="):
            return line.split("=", 1)[1]
    return ""


def trust(fd):
    """Marks the device of `fd` as root's and makes sure udev processed its event nodes as hardware."""
    name = sysname(fd)
    if not name.startswith("input") or not name[5:].isdigit():
        raise RuntimeError(f"UI_GET_SYSNAME gave {name!r}")
    with open(os.path.join(TRUSTED_DIR, name), "w"):
        pass
    subprocess.run(["udevadm", "settle", "--timeout=10"], check=False)
    for node in glob.glob(f"/sys/devices/virtual/input/{name}/event*"):
        devpath = node[len("/sys"):]
        if origin(devpath) != "trusted":
            with open(os.path.join(node, "uevent"), "w") as f:
                f.write("add")
            subprocess.run(["udevadm", "settle", "--timeout=10"], check=False)
        if origin(devpath) != "trusted":
            raise RuntimeError(f"udev did not take {devpath} as trusted: {origin(devpath)!r}")
    return name


def untrust(name):
    """Removes root's marker (before the device is destroyed)."""
    try:
        os.unlink(os.path.join(TRUSTED_DIR, name))
    except FileNotFoundError:
        pass
