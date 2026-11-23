#!/usr/bin/env python3
"""The app side of vm-platform-check.sh (RUY-157): runs inside a Flatpak test app's sandbox (the image's
python3 through /run/host) or unsandboxed as a profile user, and talks to org.ruyaos.Platform1 with the
minimal client in vm_dbus.py (next to this script). Every line it writes is "<word> <details>":

  app LOG       Register; then the calls an app must not reach (Manage, NotifyLifecycle, the shell-only
                services), each "refused <what> <error name>" or "REACHED <what> <reply>"; then every
                message that arrives, "signal <interface>.<member> <value_ms>"; on Stopping it calls SaveDone
                ("savedone <status>"). Runs until it is stopped, or 900 s.
  register      one Register, prints "register <status>" or "register error <error name>".
  helper SOCK   one request to the identity helper's socket (RUY-1129, ADR-022 decision 4) with this
                process's own pidfd and uid: connects, holds the connection 2 s first (so the check can read
                the waiting helper's capabilities), then prints "helper files pid <pid> info <code>",
                "helper refused <code>" or "helper error <exception>". The codes are the wire's
                (services/ruya-platform-identify/src/wire.rs).
"""

import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vm_dbus import Bus, DBusError  # noqa: E402

DEST = "org.ruyaos.Platform1"
PATH = "/org/ruyaos/Platform1"
LIFECYCLE = "org.ruyaos.Platform1.Lifecycle"
MANAGE = "org.ruyaos.Platform1.Manage"

# What a sandboxed app must not reach: (label, destination, path, interface, member, arguments).
FORBIDDEN = [
    ("Manage.ListCapabilities", DEST, PATH, MANAGE, "ListCapabilities", []),
    ("Manage.ListPermissions", DEST, PATH, MANAGE, "ListPermissions", ["p1"]),
    ("Manage.SetPermission", DEST, PATH, MANAGE, "SetPermission", ["p1", "org.ruyaos.TestPlatformA", "lifecycle", True]),
    ("Manage.NotifyLifecycle", DEST, PATH, MANAGE, "NotifyLifecycle", ["p1", "x.scope", "resume", 0]),
    ("Profiles1.ListProfiles", "org.ruyaos.Profiles1", "/org/ruyaos/Profiles1", "org.ruyaos.Profiles1", "ListProfiles", []),
    ("Session1.ListRunning", "org.ruyaos.Session1", "/org/ruyaos/Session1", "org.ruyaos.Session1", "ListRunning", []),
    ("Input1.ListPads", "org.ruyaos.Input1", "/org/ruyaos/Input1", "org.ruyaos.Input1", "ListPads", []),
]


def register(bus):
    try:
        return bus.call(DEST, PATH, LIFECYCLE, "Register", [])
    except DBusError as e:
        return "error " + e.name


def u64(body):
    return struct.unpack_from("<Q", body, 0)[0] if len(body) >= 8 else -1


def app(log_path):
    log = open(log_path, "a", buffering=1)
    bus = Bus()
    log.write("register %s\n" % register(bus))
    for label, dest, path, iface, member, args in FORBIDDEN:
        try:
            reply = bus.call(dest, path, iface, member, args)
            log.write("REACHED %s %s\n" % (label, reply))
        except DBusError as e:
            log.write("refused %s %s\n" % (label, e.name))
        except RuntimeError as e:
            log.write("refused %s %s\n" % (label, e))
    log.write("listening\n")
    end = time.monotonic() + 900
    while time.monotonic() < end:
        msg = bus.next_message(5)
        if msg is None:
            continue
        kind, fields, body = msg
        if kind != 4:  # only signals
            continue
        iface, member = fields.get(2, ""), fields.get(3, "")
        if iface.startswith("org.freedesktop.DBus"):
            continue  # the bus's own NameAcquired and the like
        log.write("signal %s.%s %d\n" % (iface, member, u64(body)))
        if iface == LIFECYCLE and member == "Stopping":
            try:
                log.write("savedone %s\n" % bus.call(DEST, PATH, LIFECYCLE, "SaveDone", []))
            except DBusError as e:
                log.write("savedone error %s\n" % e.name)


# The wire's codes (ruya-platform-identify wire.rs): a part's code, a refusal's code.
FILE_CODES = ["bytes", "missing", "denied", "not-owned", "not-regular", "too-large", "failed"]
REFUSALS = ["files", "bad-request", "not-root", "not-a-pidfd", "process-gone"]


def name_of(names, code):
    return names[code] if code < len(names) else "unknown-%d" % code


def helper(sock_path):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        s.connect(sock_path)
        time.sleep(2)
        socket.send_fds(s, [struct.pack("<BI", 1, os.getuid())], [os.pidfd_open(os.getpid())])
        r = s.recv(1 << 17)
    except OSError as e:
        return "helper error %s" % type(e).__name__
    if len(r) < 2 or r[0] != 1:
        return "helper malformed %r" % r[:8]
    if r[1] != 0:
        return "helper refused %s" % name_of(REFUSALS, r[1])
    if len(r) < 7:
        return "helper malformed %r" % r[:8]
    return "helper files pid %d info %s" % (struct.unpack_from("<I", r, 2)[0], name_of(FILE_CODES, r[6]))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "app":
        app(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "register":
        print("register %s" % register(Bus()))
    elif len(sys.argv) == 3 and sys.argv[1] == "helper":
        print(helper(sys.argv[2]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
