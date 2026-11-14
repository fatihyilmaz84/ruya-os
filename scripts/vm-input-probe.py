#!/usr/bin/env python3
"""Probes for scripts/vm-input-check.sh (RUY-3 / T-367): Ruya Input's virtual pads and routing.

  python3 vm-input-probe.py check --user ruya-p1 --profile p1 --other ruya-p2
      As root. Creates a uinput "physical" pad, drives Input1.SetRoute over its own system-bus
      connection (busctl's would leave the bus at once, and a leaving caller locks the route),
      runs a game process as the profile user on the virtual pad, and prints PASS:/FAIL: lines.
  python3 vm-input-probe.py game <node>      (as the profile user; driven by `check` over stdin)
  python3 vm-input-probe.py open <node>      prints "open ok" or "open refused <errno name>"
  python3 vm-input-probe.py restart          (root) kill -9 ruya-inputd; prints "<old> <new> <ms>"
  python3 vm-input-probe.py pad <seconds>    (root) holds a uinput "physical" pad for that long
      (RUY-409: the shell's route makes its virtual pad); prints "pad ready <node>" once it has a node
  python3 vm-input-probe.py confirm --profile p1
      (root; RUY-40) a uinput pad with Nintendo's vendor id: the Confirm button swaps Enter and Esc
      for BTN_EAST and BTN_SOUTH by mode (vm-input-check.sh confirm stops the compositor first)
  python3 vm-input-probe.py hold --profile p1
      (root; RUY-479) StartTest(device_id, hold_left_stick): with the flag a pushed left stick sends
      no arrow key (the D-pad still does), a stick held when the test starts is released once, and
      after StopTest a stick still pushed stays quiet until it was neutral (vm-input-check.sh hold
      stops the compositor first)
  python3 vm-input-probe.py twoprofiles --user ruya-p1 --profile p1
      (root; RUY-545) two pads, a device's and a family's global slot: each virtual pad emits its own
      pad's profile, emptying one slot changes only that pad (vm-input-check.sh twopads runs it)
  python3 vm-input-probe.py nodes --profile p1 --user ruya-p1
      (root; RUY-446) the virtual pad nodes (phys ruya-input/pad<n>) are ruya-input's, user rw only, with no
      uaccess tag and no entry for ruya-shell, and the profile user's ACL entry; a node whose phys is
      ruya-input/kbm* keeps uaccess (vm-input-check.sh nodes runs it)
  python3 vm-input-probe.py navpad [--settle S] [--lefts N] [--rights M] [--start K]
      (root; RUY-410) a uinput pad that, S seconds after it is ready, taps the D-pad left N times and
      right M times, then A (the emergency reader's keys: Left, Right, Return); prints "pad ready <node>"
      and then "sent"
"""
import argparse
import errno
import fcntl
import glob
import json
import os
import select
import socket
import struct
import subprocess
import sys
import threading
import time

EV_SYN, EV_KEY, EV_ABS, EV_FF, EV_UINPUT = 0, 1, 3, 0x15, 0x0101
UI_FF_UPLOAD, UI_FF_ERASE = 1, 2
FF_RUMBLE = 0x50
BTN_SOUTH, BTN_EAST, BTN_MODE = 0x130, 0x131, 0x13C
BTN_TL = 0x136
BTN_START = 0x13B
KEYS = [0x130, 0x131, 0x133, 0x134, 0x136, 0x137, 0x13A, 0x13B, 0x13C, 0x13D, 0x13E]
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y = 0, 1, 2, 3, 4, 5, 0x10, 0x11
KEY_ENTER, KEY_ESC, KEY_HOMEPAGE = 28, 1, 172

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_SET_FFBIT = 0x40045564, 0x40045565, 0x40045567, 0x4004556B
UI_DEV_SETUP, UI_ABS_SETUP, UI_SET_PHYS = 0x405C5503, 0x401C5504, 0x4008556C
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_BEGIN_FF_UPLOAD, UI_END_FF_UPLOAD = 0xC06855C8, 0x406855C9
UI_BEGIN_FF_ERASE, UI_END_FF_ERASE = 0xC00C55CA, 0x400C55CB
EVIOCGID, EVIOCSFF = 0x80084502, 0x40304580
EVENT = struct.Struct("llHHi")
FF_EFFECT = struct.Struct("HhHHHHH2xHH28x")  # type id direction trigger(2) replay(2) | rumble(2) pad
PHYS = "vm-check/pad0"
NAME = "Ruya VM Check Pad"
NAV = "RuyaOS Navigation"
SVC, PATH, IFC = "org.ruyaos.Input1", "/org/ruyaos/Input1", "org.ruyaos.Input1"


def ioc_read(nr, size):
    return (2 << 30) | (size << 16) | (ord("E") << 8) | nr


def eviocgname(fd):
    buf = bytearray(256)
    n = fcntl.ioctl(fd, ioc_read(0x06, 256), buf)
    return bytes(buf).split(b"\0", 1)[0].decode(errors="replace")


def eviocgbit(fd, ev, size):
    buf = bytearray(size)
    fcntl.ioctl(fd, ioc_read(0x20 + ev, size), buf)
    return [i for i in range(size * 8) if buf[i // 8] >> (i % 8) & 1]


def eviocgabs(fd, code):
    buf = bytearray(24)
    fcntl.ioctl(fd, ioc_read(0x40 + code, 24), buf)
    return struct.unpack("6i", bytes(buf))  # value min max fuzz flat res


# ---- a minimal D-Bus client (AUTH EXTERNAL, Hello, method calls with string arguments) ------

class Bus:
    def __init__(self, path="/run/dbus/system_bus_socket"):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.sendall(b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
        if not self._line().startswith(b"OK"):
            raise RuntimeError("D-Bus auth refused")
        self.sock.sendall(b"BEGIN\r\n")
        self.serial = 0
        self.buf = b""
        self.name = self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", [])

    def _line(self):
        out = b""
        while not out.endswith(b"\r\n"):
            out += self.sock.recv(1)
        return out

    def _recv(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("bus closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    @staticmethod
    def _pad(b, n):
        while len(b) % n:
            b.append(0)

    def _str(self, b, s):
        self._pad(b, 4)
        e = s.encode()
        b += struct.pack("<I", len(e)) + e + b"\0"

    def call(self, dest, path, iface, member, args):
        self.serial += 1
        b = bytearray(b"l\x01\x00\x01")
        b += struct.pack("<II", 0, self.serial)
        b += struct.pack("<I", 0)  # header fields length, patched below
        self._pad(b, 8)
        fields_start = len(b)
        sig = "".join("b" if isinstance(a, bool) else "s" for a in args)
        fields = [(1, "o", path), (2, "s", iface), (3, "s", member), (6, "s", dest)]
        if sig:
            fields.append((8, "g", sig))
        for code, t, value in fields:
            self._pad(b, 8)
            b.append(code)
            b += bytes([1]) + t.encode() + b"\0"
            if t == "g":
                b += bytes([len(value)]) + value.encode() + b"\0"
            else:
                self._str(b, value)
        struct.pack_into("<I", b, 12, len(b) - fields_start)
        self._pad(b, 8)
        body_start = len(b)
        for a in args:
            if isinstance(a, bool):
                self._pad(b, 4)
                b += struct.pack("<I", 1 if a else 0)
            else:
                self._str(b, a)
        struct.pack_into("<I", b, 4, len(b) - body_start)
        self.sock.sendall(bytes(b))
        while True:
            kind, reply_to, body = self._message()
            if reply_to == self.serial:
                text = self._first_string(body)
                if kind == 3:
                    raise RuntimeError(f"{member}: D-Bus error {text}")
                return text

    def _message(self):
        head = self._recv(16)
        kind = head[1]
        body_len, _, fields_len = struct.unpack_from("<III", head, 4)
        fields = self._recv(fields_len + (-(16 + fields_len) % 8))
        body = self._recv(body_len)
        reply_to = None
        i = 0
        while i < fields_len:
            i += -i % 8
            code = fields[i]
            slen = fields[i + 1]
            t = fields[i + 2:i + 2 + slen].decode()
            i += 3 + slen
            if t in ("s", "o"):
                i += -(16 + i) % 4
                n = struct.unpack_from("<I", fields, i)[0]
                i += 4 + n + 1
            elif t == "g":
                i += 1 + fields[i] + 1
            elif t == "u":
                i += -(16 + i) % 4
                if code == 5:
                    reply_to = struct.unpack_from("<I", fields, i)[0]
                i += 4
            else:
                break
        return kind, reply_to, body

    @staticmethod
    def _first_string(body):
        if len(body) < 4:
            return ""
        n = struct.unpack_from("<I", body, 0)[0]
        return body[4:4 + n].decode(errors="replace")

    def close(self):
        self.sock.close()


# ---- the "physical" pad -------------------------------------------------------------------

class FakePad:
    """A uinput gamepad that ruya-inputd takes as physical; it answers rumble uploads."""

    def __init__(self, vendor=0x1234, product=0x5678, phys=PHYS, name=NAME):
        self.fd = os.open("/dev/uinput", os.O_RDWR | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_PHYS, phys.encode() + b"\0")
        for ev in (EV_KEY, EV_ABS, EV_FF):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        for code in KEYS:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        for code, lo, hi in [(ABS_X, -32768, 32767), (ABS_Y, -32768, 32767), (ABS_RX, -32768, 32767),
                             (ABS_RY, -32768, 32767), (ABS_Z, 0, 255), (ABS_RZ, 0, 255),
                             (ABS_HAT0X, -1, 1), (ABS_HAT0Y, -1, 1)]:
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("HxxiiiiiI", code, 0, lo, hi, 0, 0, 0))
        fcntl.ioctl(self.fd, UI_SET_FFBIT, FF_RUMBLE)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, vendor, product, 1, name.encode(), 8))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        self.rumble = []  # (strong, weak) uploads
        self.played = []  # (effect id, value)
        self.alive = True
        threading.Thread(target=self._serve_ff, daemon=True).start()

    def _serve_ff(self):
        while self.alive:
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if not r:
                continue
            try:
                data = os.read(self.fd, EVENT.size * 16)
            except OSError:
                continue
            for i in range(0, len(data), EVENT.size):
                _, _, t, c, v = EVENT.unpack_from(data, i)
                if t == EV_UINPUT and c == UI_FF_UPLOAD:
                    req = bytearray(struct.pack("Ii", v, 0) + bytes(96))
                    fcntl.ioctl(self.fd, UI_BEGIN_FF_UPLOAD, req)
                    kind, eid, _, _, _, _, _, strong, weak = FF_EFFECT.unpack_from(bytes(req), 8)
                    self.rumble.append((kind, strong, weak))
                    struct.pack_into("i", req, 4, 0)
                    fcntl.ioctl(self.fd, UI_END_FF_UPLOAD, bytes(req))
                elif t == EV_UINPUT and c == UI_FF_ERASE:
                    req = bytearray(struct.pack("IiI", v, 0, 0))
                    fcntl.ioctl(self.fd, UI_BEGIN_FF_ERASE, req)
                    fcntl.ioctl(self.fd, UI_END_FF_ERASE, bytes(req))
                elif t == EV_FF:
                    self.played.append((c, v))

    def emit(self, t, c, v):
        os.write(self.fd, EVENT.pack(0, 0, t, c, v) + EVENT.pack(0, 0, EV_SYN, 0, 0))

    def close(self):
        self.alive = False
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


def node_by(attr, value):
    """The event node of the input device whose sysfs `attr` is `value`."""
    for d in glob.glob("/sys/class/input/input*"):
        try:
            if open(os.path.join(d, attr)).read().strip() == value:
                ev = glob.glob(os.path.join(d, "event*"))
                if ev:
                    return "/dev/input/" + os.path.basename(ev[0]), os.path.basename(d)
        except OSError:
            pass
    return None, None


def wait_for(fn, timeout, step=0.02):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return fn()


def acl_users(node):
    out = subprocess.run(["getfacl", "-p", node], capture_output=True, text=True).stdout
    named = [l.split(":")[1] for l in out.splitlines() if l.startswith("user:") and l.split(":")[1]]
    owner = next((l.split(": ", 1)[1] for l in out.splitlines() if l.startswith("# owner:")), "")
    return owner, named


def devices():
    out = subprocess.run(["busctl", "--system", "--json=short", "call", SVC, PATH, IFC, "ListDevices"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        rows = json.loads(out.stdout)["data"][0]
    except (ValueError, KeyError, IndexError):
        return None
    return [{k: v["data"] for k, v in row.items()} for row in rows]


def assigned_slots(profile):
    """The console profile's global slots now ({scope_id: profile id}), from ListProfiles; None when
    it cannot be read."""
    out = subprocess.run(["busctl", "--system", "--json=short", "call", SVC, PATH, IFC, "ListProfiles", "s", profile],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        status, rows = json.loads(out.stdout)["data"]
    except (ValueError, KeyError, TypeError):
        return None
    if status != "ok":
        return None
    rows = [{k: v["data"] for k, v in row.items()} for row in rows]
    return {r["global_slot"]: r["id"] for r in rows if r.get("assigned")}


def route_prop():
    out = subprocess.run(["busctl", "--system", "get-property", SVC, PATH, IFC, "Route"],
                         capture_output=True, text=True).stdout.strip()
    return out.split(" ", 1)[1].strip('"') if " " in out else out


class Nav:
    """Reads the RuyaOS Navigation keyboard (root)."""

    def __init__(self):
        node, _ = node_by("name", NAV)
        self.fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK) if node else None

    def keys(self, seconds=0.3):
        out = []
        if self.fd is None:
            return out
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            r, _, _ = select.select([self.fd], [], [], max(0, end - time.monotonic()))
            if not r:
                break
            try:
                data = os.read(self.fd, EVENT.size * 64)
            except OSError:
                break
            for i in range(0, len(data), EVENT.size):
                _, _, t, c, v = EVENT.unpack_from(data, i)
                if t == EV_KEY:
                    out.append((c, v))
        return out


class Game:
    """The game process, as the profile user, on the virtual pad."""

    def __init__(self, user, node):
        self.p = subprocess.Popen(["runuser", "-u", user, "--", sys.executable, os.path.abspath(__file__), "game", node],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.hello = self.p.stdout.readline().strip()

    def ask(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        return self.p.stdout.readline().strip()

    def events(self, ms=300):
        answer = self.ask(f"read {ms}")
        if answer.startswith("EVENTS "):
            return [tuple(e) for e in json.loads(answer[7:])]
        return answer

    def events_until(self, want, timeout_ms=2000):
        """Reads until `want(events so far)` holds or `timeout_ms` is up (so timing cannot fail a
        check), then 100 ms more to catch a surplus event; what was read, or the error."""
        got = []
        end = time.monotonic() + timeout_ms / 1000
        while True:
            ev = self.events(100)
            if not isinstance(ev, list):
                return ev
            got += ev
            if want(got) or time.monotonic() >= end:
                break
        more = self.events(100)
        return got + more if isinstance(more, list) else more

    def close(self):
        try:
            self.ask("quit")
        except (BrokenPipeError, OSError):
            pass
        self.p.wait(timeout=5)


def cmd_game(args):
    try:
        fd = os.open(args.node, os.O_RDWR | os.O_NONBLOCK)
    except OSError as e:
        print(f"OPEN refused {errno.errorcode.get(e.errno, e.errno)}", flush=True)
        return
    idbuf = bytearray(8)
    fcntl.ioctl(fd, EVIOCGID, idbuf)
    info = {
        "name": eviocgname(fd),
        "id": "%04x:%04x:%04x:%04x" % struct.unpack("4H", bytes(idbuf)),
        "keys": eviocgbit(fd, EV_KEY, 96),
        "abs": {str(c): eviocgabs(fd, c)[1:5] for c in eviocgbit(fd, EV_ABS, 8)},
        "ff": eviocgbit(fd, EV_FF, 16),
    }
    print("OPEN ok " + json.dumps(info), flush=True)
    for line in sys.stdin:
        cmd = line.split()
        if not cmd or cmd[0] == "quit":
            break
        if cmd[0] == "read":
            end = time.monotonic() + int(cmd[1]) / 1000
            out, err = [], None
            while time.monotonic() < end:
                r, _, _ = select.select([fd], [], [], max(0, end - time.monotonic()))
                if not r:
                    break
                try:
                    data = os.read(fd, EVENT.size * 64)
                except OSError as e:
                    err = errno.errorcode.get(e.errno, e.errno)
                    break
                for i in range(0, len(data), EVENT.size):
                    _, _, t, c, v = EVENT.unpack_from(data, i)
                    if t != EV_SYN:
                        out.append((t, c, v))
            print(f"ERR {err}" if err else "EVENTS " + json.dumps(out), flush=True)
        elif cmd[0] == "rumble":
            effect = bytearray(FF_EFFECT.pack(FF_RUMBLE, -1, 0, 0, 0, 1000, 0, 40000, 20000))
            effect += bytes(48 - len(effect))
            try:
                fcntl.ioctl(fd, EVIOCSFF, effect)
                eid = struct.unpack_from("h", effect, 2)[0]
                os.write(fd, EVENT.pack(0, 0, EV_FF, eid, 1))
                print(f"RUMBLE {eid}", flush=True)
            except OSError as e:
                print(f"RUMBLE failed {errno.errorcode.get(e.errno, e.errno)}", flush=True)


def cmd_open(args):
    try:
        os.close(os.open(args.node, os.O_RDONLY | os.O_NONBLOCK))
        print("open ok")
    except OSError as e:
        print(f"open refused {errno.errorcode.get(e.errno, e.errno)}")


def cmd_pad(args):
    """Holds a "physical" test pad, so the shell's route (not this probe) decides its virtual pad."""
    pad = FakePad()
    try:
        node = wait_for(lambda: node_by("phys", PHYS)[0], 3)
        print(f"pad ready {node}" if node else "pad has no node", flush=True)
        time.sleep(args.seconds)
    finally:
        pad.close()


def cmd_navpad(args):
    """A "physical" pad that taps the D-pad and A once the shell's emergency reader has found it."""
    pad = FakePad()
    try:
        node = wait_for(lambda: node_by("phys", PHYS)[0], 3)
        print(f"pad ready {node}" if node else "pad has no node", flush=True)
        time.sleep(args.settle)

        def tap(kind, code, value):
            pad.emit(kind, code, value)
            time.sleep(0.15)
            pad.emit(kind, code, 0)
            time.sleep(0.3)

        for _ in range(args.lefts):
            tap(EV_ABS, ABS_HAT0X, -1)
        for _ in range(args.rights):
            tap(EV_ABS, ABS_HAT0X, 1)
        if args.start:
            # RUY-583: Start (Options) taps; the shell opens the Options menu on the first and closes it on the second.
            for _ in range(args.start):
                tap(EV_KEY, BTN_START, 1)
        else:
            tap(EV_KEY, BTN_SOUTH, 1)
        print("sent", flush=True)
        time.sleep(1)
    finally:
        pad.close()


def cmd_confirm(args):
    """RUY-40: a uinput pad announcing Nintendo's vendor id (0x057e) turns BTN_EAST into Enter and
    BTN_SOUTH into Esc; "south" swaps them back and "east" gives every family the right button. The
    probe holds the route `shell` for the profile on its own bus connection (the shell must not
    run, or its Home would act on the Enter); prints PASS:/FAIL: lines."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    pad = FakePad(vendor=0x057E, product=0x2009)
    bus = None
    try:
        row = wait_for(lambda: next((d for d in (devices() or []) if d.get("name") == NAME), None), 5)
        if not row:
            bad("ListDevices does not list the pad")
            return fails
        if row.get("family") == "nintendo":
            ok(f"the pad with vendor 0x057e is family nintendo ({row['id']})")
        else:
            bad(f"the pad with vendor 0x057e has family '{row.get('family')}'")
        bus = Bus()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
        ok("route shell for the profile") if status == "ok" else bad(f"SetRoute answered {status}")
        nav = Nav()
        nav.keys(0.3)

        def tap(button):
            pad.emit(EV_KEY, button, 1)
            time.sleep(0.1)
            pad.emit(EV_KEY, button, 0)
            return nav.keys(0.4)

        def prop():
            out = subprocess.run(["busctl", "--system", "get-property", SVC, PATH, IFC, "ConfirmButton"],
                                 capture_output=True, text=True).stdout.strip()
            return out.split(" ", 1)[1].strip('"') if " " in out else out

        def expect(mode, east_key, south_key):
            status = bus.call(SVC, PATH, IFC, "SetConfirmButton", [args.profile, mode])
            ok(f"SetConfirmButton {mode}: ok") if status == "ok" else bad(f"SetConfirmButton {mode} answered {status}")
            ok(f"ConfirmButton reads {mode}") if prop() == mode else bad(f"ConfirmButton reads '{prop()}', not {mode}")
            for name, button, want in (("BTN_EAST", BTN_EAST, east_key), ("BTN_SOUTH", BTN_SOUTH, south_key)):
                got = tap(button)
                label = {KEY_ENTER: "KEY_ENTER", KEY_ESC: "KEY_ESC"}[want]
                if got == [(want, 1), (want, 0)]:
                    ok(f"mode {mode}: {name} gives {label}")
                else:
                    bad(f"mode {mode}: {name} gave {got}, wanted {label} down and up")

        expect("family", KEY_ENTER, KEY_ESC)       # a Nintendo pad: A (east) confirms
        expect("south", KEY_ESC, KEY_ENTER)        # Bottom: the south button confirms
        expect("east", KEY_ENTER, KEY_ESC)         # Right
        expect("family", KEY_ENTER, KEY_ESC)       # back to the default
        status = bus.call(SVC, PATH, IFC, "SetConfirmButton", [args.profile, "sideways"])
        ok("SetConfirmButton sideways: invalid") if status == "invalid" else bad(f"sideways answered {status}")
        status = bus.call(SVC, PATH, IFC, "SetConfirmButton", ["root", "east"])
        ok("SetConfirmButton for root: unknown-profile") if status == "unknown-profile" else bad(f"root answered {status}")
    finally:
        pad.close()
        if bus:
            bus.close()
    return fails


def cmd_hold(args):
    """RUY-479: Input1.StartTest(device_id, hold_left_stick). The probe holds the route `shell` and the
    test on its own bus connection (a leaving caller ends a test) and reads RuyaOS Navigation;
    prints PASS:/FAIL: lines."""
    fails = 0
    KEY_LEFT, KEY_RIGHT = 105, 106

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    def expect(got, want, label):
        ok(label) if got == want else bad(f"{label}: got {got}, wanted {want}")

    pad = FakePad()
    bus = None
    try:
        row = wait_for(lambda: next((d for d in (devices() or []) if d.get("name") == NAME), None), 5)
        if not row:
            bad("ListDevices does not list the pad")
            return fails
        did = row["id"]
        bus = Bus()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
        expect(status, "ok", "route shell for the profile")
        nav = Nav()
        nav.keys(0.3)

        def stick(value):
            pad.emit(EV_ABS, ABS_X, value)
            return nav.keys(0.4)

        def dpad_right():
            pad.emit(EV_ABS, ABS_HAT0X, 1)
            time.sleep(0.1)
            pad.emit(EV_ABS, ABS_HAT0X, 0)
            return nav.keys(0.4)

        expect(bus.call(SVC, PATH, IFC, "StartTest", [did, False]), "ok", "StartTest without the flag: ok")
        expect(stick(32767), [(KEY_RIGHT, 1)], "without the flag the left stick sends Right")
        expect(stick(0), [(KEY_RIGHT, 0)], "and lets go")
        expect(stick(32767), [(KEY_RIGHT, 1)], "pushed again, Right is down")
        expect(bus.call(SVC, PATH, IFC, "StopTest", [did]), "ok", "StopTest: ok")
        expect(bus.call(SVC, PATH, IFC, "StartTest", [did, True]), "ok", "StartTest with the flag: ok")
        expect(nav.keys(0.4), [(KEY_RIGHT, 0)], "the stick held when the hold starts is released once")
        expect(stick(0), [], "letting go sends nothing more")
        expect(stick(-32768), [], "with the flag the left stick sends no Left")
        expect(dpad_right(), [(KEY_RIGHT, 1), (KEY_RIGHT, 0)], "with the flag the D-pad still sends Right")
        expect(bus.call(SVC, PATH, IFC, "StopTest", [did]), "ok", "StopTest: ok")
        expect(nav.keys(0.4), [], "ending the test with the stick pushed sends no stray key")
        expect(stick(-30000), [], "the pushed stick stays quiet after the test")
        expect(stick(0), [], "back at neutral, still nothing")
        expect(stick(-32768), [(KEY_LEFT, 1)], "then it navigates again")
        expect(stick(0), [(KEY_LEFT, 0)], "and lets go")
    finally:
        pad.close()
        if bus:
            bus.close()
    return fails


def signal_counter():
    """A `busctl monitor` on Input1's UserActive; `count()` reads how many it has seen so far."""
    mon = subprocess.Popen(["busctl", "--system", "monitor", "--match",
                            "type='signal',interface='org.ruyaos.Input1',member='UserActive'"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    seen = []
    threading.Thread(target=lambda: [seen.append(1) for line in mon.stdout if "Member=UserActive" in line or "member=UserActive" in line],
                     daemon=True).start()
    return mon, lambda: len(seen)


def cmd_useractive(args):
    """RUY-588: Input1.UserActive reaches the bus once for a press in `app`, not again within the gap, never for
    stick noise or in the shell route, and again after the gap (31 s; the service keeps its real 30 s here).
    Run with the shell stopped, as twopads."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    pad = FakePad()
    mon = None
    try:
        if not wait_for(lambda: node_by("phys", PHYS)[0], 3):
            bad("the uinput pad has no node")
            return fails
        bus = Bus()
        mon, count = signal_counter()
        time.sleep(1.0)
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
        pad.emit(EV_KEY, BTN_SOUTH, 1)
        pad.emit(EV_KEY, BTN_SOUTH, 0)
        time.sleep(0.5)
        ok("no UserActive for a press in the shell route") if count() == 0 else bad(f"{count()} UserActive in the shell route")
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-3", "org.ruyaos.VmCheck", args.profile])
        if status != "ok":
            bad(f"SetRoute app: {status}")
            return fails
        pad.emit(EV_ABS, ABS_X, 1000)  # a resting thumb: under a quarter of the range
        time.sleep(0.5)
        ok("no UserActive for stick noise") if count() == 0 else bad(f"{count()} UserActive for stick noise")
        pad.emit(EV_KEY, BTN_EAST, 1)
        pad.emit(EV_KEY, BTN_EAST, 0)
        time.sleep(0.5)
        ok("one UserActive for a press in app") if count() == 1 else bad(f"{count()} UserActive after the first press, expected 1")
        for _ in range(5):
            pad.emit(EV_KEY, BTN_EAST, 1)
            pad.emit(EV_KEY, BTN_EAST, 0)
            time.sleep(1.0)
        ok("no second UserActive within the gap") if count() == 1 else bad(f"{count()} UserActive within 30 s, expected 1")
        time.sleep(26)
        pad.emit(EV_KEY, BTN_EAST, 1)
        pad.emit(EV_KEY, BTN_EAST, 0)
        time.sleep(0.5)
        ok("another UserActive after the gap") if count() == 2 else bad(f"{count()} UserActive after the gap, expected 2")
    finally:
        if mon:
            mon.terminate()
        pad.close()
    return fails


def cmd_playing(args):
    """RUY-588: holds the route `app` and presses a button every `--every` s for `--seconds` s, like a game being
    played; the shell (running, with RUYA_IDLE_DIVISOR) must not start its saver meanwhile."""
    pad = FakePad()
    try:
        if not wait_for(lambda: node_by("phys", PHYS)[0], 3):
            print("FAIL: the uinput pad has no node", flush=True)
            sys.exit(1)
        bus = Bus()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-4", "org.ruyaos.VmCheck", args.profile])
        print(f"route app: {status}", flush=True)
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            pad.emit(EV_KEY, BTN_EAST, 1)
            pad.emit(EV_KEY, BTN_EAST, 0)
            time.sleep(args.every)
        print("stopped pressing", flush=True)
    finally:
        pad.close()


def cmd_twopads(args):
    """RUY-540: two pads, one of them signs the profile in; on entry to `app` that pad is ruya-input/pad1 (SDL
    index 0). Run twice, once with each pad the active one, so the key order cannot decide it."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    pads = [FakePad(phys="vm-check/pad0", name=NAME), FakePad(0x1234, 0x5679, "vm-check/pad1", NAME + " 2")]
    bus = None
    game = None
    try:
        if not wait_for(lambda: len([d for d in (devices() or []) if d.get("name") in (NAME, NAME + " 2")]) == 2, 5):
            bad("ListDevices does not list both pads")
            return fails
        bus = Bus()
        for active in (1, 0, 1):
            expect_pad, other_pad = pads[active], pads[1 - active]
            # Locked (nobody signed in), the chosen pad gives the sign-in input, then the profile is signed in.
            status = bus.call(SVC, PATH, IFC, "SetRoute", ["locked", "", "", ""])
            if status != "ok":
                bad(f"SetRoute locked: {status}")
                return fails
            expect_pad.emit(EV_KEY, BTN_SOUTH, 1)
            expect_pad.emit(EV_KEY, BTN_SOUTH, 0)
            time.sleep(0.3)
            status = bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
            if status != "ok":
                bad(f"SetRoute shell: {status}")
                return fails
            # A later press on the other pad does not move the profile's active controller.
            other_pad.emit(EV_KEY, BTN_SOUTH, 1)
            other_pad.emit(EV_KEY, BTN_SOUTH, 0)
            time.sleep(0.3)
            status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-2", "org.ruyaos.VmCheck", args.profile])
            if status != "ok":
                bad(f"SetRoute app: {status}")
                return fails
            v1 = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0], 3)
            v2 = wait_for(lambda: node_by("phys", "ruya-input/pad2")[0], 3)
            if not v1 or not v2:
                bad(f"both virtual pads should exist (pad1 {v1}, pad2 {v2})")
                return fails
            n1 = int(os.path.basename(v1).replace("event", ""))
            n2 = int(os.path.basename(v2).replace("event", ""))
            # No PASS for the node order: it holds whichever pad was used. The two button checks
            # below are the assertion on which physical pad drives pad1.
            if n1 >= n2:
                bad(f"pad1 ({v1}) was created after pad2 ({v2})")
            wait_for(lambda: all(d.get("routed") for d in (devices() or []) if d.get("name") in (NAME, NAME + " 2")), 3)
            game = Game(args.user, v1)
            if not game.hello.startswith("OPEN ok"):
                bad(f"{args.user} cannot open pad1: {game.hello}")
                return fails
            expect_pad.emit(EV_KEY, BTN_EAST, 1)
            expect_pad.emit(EV_KEY, BTN_EAST, 0)
            got = game.events_until(lambda ev: len(ev) >= 2)
            ok("the pad the player used drives pad1 (SDL index 0)") if isinstance(got, list) and (EV_KEY, BTN_EAST, 1) in got else bad(f"pad1 did not get the used pad's button: {got}")
            other_pad.emit(EV_KEY, BTN_SOUTH, 1)
            other_pad.emit(EV_KEY, BTN_SOUTH, 0)
            got = game.events(300)
            ok("the idle pad does not reach pad1") if got == [] else bad(f"pad1 heard the idle pad: {got}")
            game.close()
            game = None
    finally:
        if game:
            game.close()
        if bus:
            bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
            bus.close()
        for p in pads:
            p.close()
    return fails


def cmd_guide(args):
    """RUY-11: two pads in route `app`; the Guide button of either one gives KEY_HOMEPAGE (press, a long
    hold, release) on RuyaOS Navigation and never a BTN_MODE on the game's virtual pad. A BTN_SOUTH
    pressed while Guide is held must reach one of the virtual pads (the positive control: a dead pad would read nothing)."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    pads = [FakePad(phys="vm-check/pad0", name=NAME), FakePad(0x1234, 0x5679, "vm-check/pad1", NAME + " 2")]
    bus = None
    game = None
    try:
        if not wait_for(lambda: len([d for d in (devices() or []) if d.get("name") in (NAME, NAME + " 2")]) == 2, 5):
            bad("ListDevices does not list both pads")
            return fails
        bus = Bus()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-guide", "org.ruyaos.VmCheck", args.profile])
        if status != "ok":
            bad(f"SetRoute app: {status}")
            return fails
        v1 = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0], 3)
        v2 = wait_for(lambda: node_by("phys", "ruya-input/pad2")[0], 3)
        if not v1 or not v2:
            bad(f"both virtual pads should exist (pad1 {v1}, pad2 {v2})")
            return fails
        games = [Game(args.user, v1), Game(args.user, v2)]
        game = games
        for g in games:
            if not g.hello.startswith("OPEN ok"):
                bad(f"{args.user} cannot open a virtual pad: {g.hello}")
                return fails
        if not wait_for(lambda: all(d.get("routed") for d in (devices() or []) if d.get("name") in (NAME, NAME + " 2")), 3):
            bad("the pads are not routed to the virtual pads")
            return fails
        nav = Nav()
        if nav.fd is None:
            bad("RuyaOS Navigation is not there")
            return fails
        nav.keys(0.3)
        for i, pad in enumerate(pads):
            for g in games:
                g.events(100)
            nav.keys(0.1)
            pad.emit(EV_KEY, BTN_MODE, 1)
            time.sleep(0.6)                      # a long hold: the shell times it, the service just passes it
            pad.emit(EV_KEY, BTN_SOUTH, 1)       # positive control: a live pad must carry this while Guide is held
            pad.emit(EV_KEY, BTN_SOUTH, 0)
            pad.emit(EV_KEY, BTN_MODE, 0)
            keys = nav.keys(0.4)
            if (KEY_HOMEPAGE, 1) in keys and (KEY_HOMEPAGE, 0) in keys:
                ok(f"pad {i}: Guide gives KEY_HOMEPAGE down and up on RuyaOS Navigation")
            else:
                bad(f"pad {i}: Guide gave {keys} on RuyaOS Navigation")
            reads = [g.events(300) for g in games]
            if not any(isinstance(ev, list) and (EV_KEY, BTN_SOUTH, 1) in ev for ev in reads):
                bad(f"pad {i}: BTN_SOUTH reached no virtual pad (dead pad?): {reads}")
            else:
                ok(f"pad {i}: BTN_SOUTH reaches a virtual pad while Guide is held")
            for j, ev in enumerate(reads):
                if isinstance(ev, list) and not any(c == BTN_MODE for _, c, _ in ev):
                    ok(f"pad {i}: no BTN_MODE on virtual pad {j + 1}")
                else:
                    bad(f"pad {i}: virtual pad {j + 1} read {ev}")
    finally:
        for g in (game or []):
            g.close()
        if bus:
            bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
            bus.close()
        for p in pads:
            p.close()
    return fails


def udev_tags(node):
    """The CURRENT_TAGS of `node` from udev's database."""
    out = subprocess.run(["udevadm", "info", "-q", "property", "-n", node], capture_output=True, text=True).stdout
    tags = set()
    for line in out.splitlines():
        # CURRENT_TAGS only: TAGS keeps every tag a rule ever added, a removed one included.
        if line.startswith("CURRENT_TAGS="):
            tags |= {t for t in line.split("=", 1)[1].split(":") if t}
    return tags


def cmd_nodes(args):
    """RUY-446: a virtual pad node is ruya-input's with user rw and no group or other access, carries no
    uaccess tag and no ACL entry for ruya-shell; a ruya-input/kbm* node keeps uaccess."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    pad = FakePad(phys="vm-check/pad0", name=NAME)
    kbm = None
    bus = None
    try:
        if not wait_for(lambda: len([d for d in (devices() or []) if d.get("name") == NAME]) == 1, 5):
            bad("ListDevices does not list the pad")
            return fails
        bus = Bus()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-446", "org.ruyaos.VmCheck", args.profile])
        if status != "ok":
            bad(f"SetRoute app: {status}")
            return fails
        node = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0], 3)
        if not node:
            bad("no virtual pad exists in the route app")
            return fails
        # The service's ACL entry comes after the add event; wait for it before reading the node.
        wait_for(lambda: args.user in acl_users(node)[1], 3)
        nodes = [node]
        for n in nodes:
            owner, named = acl_users(n)
            acl = subprocess.run(["getfacl", "-p", n], capture_output=True, text=True).stdout.splitlines()
            owner_ok = owner == "ruya-input"
            base_ok = "user::rw-" in acl and "group::---" in acl and "other::---" in acl
            ok(f"{n} is owned by ruya-input, user rw, group and other nothing") if owner_ok and base_ok else bad(
                f"{n}: owner {owner}, getfacl {[l for l in acl if l.startswith(('user::', 'group::', 'other::'))]}")
            tags = udev_tags(n)
            ok(f"{n} has no uaccess tag") if "uaccess" not in tags else bad(f"{n} carries the uaccess tag: {sorted(tags)}")
            ok(f"{n} has no ACL entry for ruya-shell (named: {named})") if "ruya-shell" not in named else bad(
                f"{n} has an ACL entry for ruya-shell: {named}")
            ok(f"{n} has the profile user's ACL entry") if args.user in named else bad(f"{n}: no entry for {args.user}: {named}")
        # A keyboard or mouse (the kbm rule of 06 section 3) keeps uaccess: stand in with a uinput device.
        kbm = FakePad(0x1234, 0x567A, "ruya-input/kbm-check", NAME + " kbm")
        knode = wait_for(lambda: node_by("phys", "ruya-input/kbm-check")[0], 3)
        if not knode:
            bad("the ruya-input/kbm stand-in has no node")
        else:
            time.sleep(0.5)
            ok(f"{knode} (ruya-input/kbm*) keeps the uaccess tag") if "uaccess" in udev_tags(knode) else bad(
                f"{knode} (ruya-input/kbm*) lost the uaccess tag: {sorted(udev_tags(knode))}")
    finally:
        if bus:
            bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
            bus.close()
        if kbm:
            kbm.close()
        pad.close()
        # Leave no device behind: a later check in the same boot counts the pads ListDevices lists.
        wait_for(lambda: not [d for d in (devices() or []) if d.get("name", "").startswith(NAME)]
                 and not node_by("phys", "vm-check/pad0")[0] and not node_by("phys", "ruya-input/kbm-check")[0], 5)
        time.sleep(1.5)
    return fails


def cmd_twoprofiles(args):
    """RUY-545: two pads, two global slots assigned over Input1: pad A's own device profile (South as
    East) and the Nintendo family's (South as LB) for pad B, a pad with Nintendo's vendor id. In `app`
    each virtual pad emits its own pad's profile; emptying the family's slot gives B South again and
    leaves A's. A slot that the profile's match does not name is refused."""
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    names = (NAME, NAME + " N")
    pads = [FakePad(phys="vm-check/pad0", name=names[0]), FakePad(0x057E, 0x2009, "vm-check/pad1", names[1])]
    pad_a, pad_b = pads
    bus = None
    games = []
    slots = []      # the slots this check assigned; the cleanup gives each back what it held before
    before = {}
    saved = []
    try:
        rows = wait_for(lambda: (lambda r: r if len(r) == 2 else None)(
            [d for d in (devices() or []) if d.get("name") in names]), 5)
        if not rows:
            bad("ListDevices does not list both pads")
            return fails
        a_id = next(d["id"] for d in rows if d["name"] == names[0])
        b_row = next(d for d in rows if d["name"] == names[1])
        if b_row.get("family") != "nintendo":
            bad(f"the pad with vendor 0x057e has family '{b_row.get('family')}'")
            return fails
        before = assigned_slots(args.profile)
        if before is None:
            bad("ListProfiles cannot be read: the slots could not be restored afterwards")
            return fails
        bus = Bus()

        def south_as(pid, code, match):
            return json.dumps({"schema_version": 1, "id": pid, "name": "VM check " + pid, "scope": {"type": "global"},
                               "match": match, "mappings": [{"from": "south", "to": {"type": "button", "code": code}}]})

        for text, pid in ((south_as("vm-check-own", "east", {"device": a_id}), "vm-check-own"),
                          (south_as("vm-check-family", "l1", {"family": "nintendo"}), "vm-check-family")):
            status = bus.call(SVC, PATH, IFC, "SaveProfile", [args.profile, text])
            if status != "ok":
                bad(f"SaveProfile {pid}: {status}")
                return fails
            saved.append(pid)
        status = bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", "", "vm-check-own"])
        ok("AssignProfile of a device's profile to all controllers' slot: invalid") if status == "invalid" \
            else bad(f"AssignProfile to the wrong slot answered {status}")
        for slot, pid in ((f"device:{a_id}", "vm-check-own"), ("family:nintendo", "vm-check-family")):
            status = bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", slot, pid])
            if status != "ok":
                bad(f"AssignProfile {slot} {pid}: {status}")
                return fails
            slots.append(slot)
        ok(f"two slots assigned: device:{a_id}, family:nintendo")
        # Pad A signs the profile in, so it is ruya-input/pad1 (RUY-540) and pad B is pad2.
        for route in (["locked", "", "", ""], None, ["shell", "", "", args.profile],
                      ["app", "vm-check-3", "org.ruyaos.VmCheck", args.profile]):
            if route is None:
                pad_a.emit(EV_KEY, BTN_SOUTH, 1)
                pad_a.emit(EV_KEY, BTN_SOUTH, 0)
                time.sleep(0.3)
                continue
            status = bus.call(SVC, PATH, IFC, "SetRoute", route)
            if status != "ok":
                bad(f"SetRoute {route[0]}: {status}")
                return fails
        v1 = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0], 3)
        v2 = wait_for(lambda: node_by("phys", "ruya-input/pad2")[0], 3)
        if not v1 or not v2:
            bad(f"both virtual pads should exist (pad1 {v1}, pad2 {v2})")
            return fails
        wait_for(lambda: all(d.get("routed") for d in (devices() or []) if d.get("name") in names), 3)
        game_a, game_b = Game(args.user, v1), Game(args.user, v2)
        games += [game_a, game_b]
        if not (game_a.hello.startswith("OPEN ok") and game_b.hello.startswith("OPEN ok")):
            bad(f"{args.user} cannot open both pads: {game_a.hello} / {game_b.hello}")
            return fails

        def tap(pad, game, want, label):
            pad.emit(EV_KEY, BTN_SOUTH, 1)
            pad.emit(EV_KEY, BTN_SOUTH, 0)
            got = game.events_until(lambda ev: (EV_KEY, want, 0) in ev)
            if isinstance(got, list) and (EV_KEY, want, 1) in got and not any(
                    c in (BTN_SOUTH, BTN_EAST, BTN_TL) and c != want for _, c, _ in got):
                ok(label)
            else:
                bad(f"{label}: read {got}")

        tap(pad_a, game_a, BTN_EAST, "pad A's South reaches its virtual pad as East (its device's profile)")
        tap(pad_b, game_b, BTN_TL, "pad B's South reaches its virtual pad as LB (its family's profile)")
        status = bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", "family:nintendo", ""])
        ok("the family's slot emptied") if status == "ok" else bad(f"emptying the family's slot answered {status}")
        tap(pad_b, game_b, BTN_SOUTH, "pad B's South is South again")
        tap(pad_a, game_a, BTN_EAST, "pad A keeps its own profile")
    finally:
        for g in games:
            g.close()
        if bus:
            for slot in slots:
                bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", slot, before.get(slot, "")])
            for pid in saved:
                bus.call(SVC, PATH, IFC, "DeleteProfile", [args.profile, pid])
            bus.call(SVC, PATH, IFC, "SetRoute", ["shell", "", "", args.profile])
            bus.close()
        for p in pads:
            p.close()
    return fails


def cmd_restart(args):
    """kill -9 the service; prints the ms until a new RuyaOS Navigation device exists."""
    _, before = node_by("name", NAV)
    out = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", "ruya-inputd"],
                         capture_output=True, text=True).stdout.strip()
    pid = int(out or 0)
    if not pid:
        print("no-pid")
        return
    start = time.monotonic()
    os.kill(pid, 9)
    while time.monotonic() - start < 5:
        _, now = node_by("name", NAV)
        if now and now != before:
            print(f"{before} {now} {int((time.monotonic() - start) * 1000)}")
            return
        time.sleep(0.005)
    print(f"{before} none 5000")


def cmd_check(args):
    fails = 0

    def ok(msg):
        print(f"PASS: {msg}", flush=True)

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", flush=True)

    def expect(cond, good, failed):
        ok(good) if cond else bad(failed)

    pad = FakePad()
    bus = None
    game = None
    try:
        phys_node, _ = wait_for(lambda: node_by("phys", PHYS)[0] and node_by("phys", PHYS), 3) or (None, None)
        expect(phys_node, f"the uinput 'physical' pad is {phys_node}", "the uinput pad has no event node")
        row = wait_for(lambda: next((d for d in (devices() or []) if d.get("name") == NAME), None), 5)
        if not row:
            bad("ListDevices does not list the pad (ruya-inputd did not take it)")
            return fails
        ok(f"ListDevices lists it: id {row['id']} instance {row['instance']} connection {row['connection']}")
        rid = row["id"]
        expect(rid.startswith("usb-1234-5678-") and len(rid.rsplit("-", 1)[1]) == 12,
               "stable id is <bus>-<vid>-<pid>-<12 hex>", f"stable id has the wrong form: {rid}")
        owner, named = acl_users(phys_node)
        expect("ruya-input" in named, f"the physical pad's ACL names ruya-input ({named})",
               f"no ruya-input entry on the physical pad: {named}")
        subprocess.run(["udevadm", "trigger", "--action=change", phys_node])
        subprocess.run(["udevadm", "settle"])
        _, named = acl_users(phys_node)
        expect("ruya-input" in named, f"... and after a udev change event ({named})",
               f"a change event dropped ruya-input from the physical pad: {named}")
        expect(not node_by("phys", "ruya-input/pad1")[0], "no virtual pad while the route is shell",
               "a virtual pad exists before any SetRoute app")

        bus = Bus()
        nav = Nav()
        expect(nav.fd is not None, "the RuyaOS Navigation keyboard exists", "no RuyaOS Navigation node")
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "", "", args.profile])
        expect(status == "invalid", "SetRoute app without an instance is invalid", f"SetRoute app without instance: {status}")
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-1", "org.ruyaos.VmCheck", "shell"])
        expect(status == "unknown-profile", "SetRoute for ruya-shell is unknown-profile", f"SetRoute for shell: {status}")
        t_route = time.monotonic()
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-1", "org.ruyaos.VmCheck", args.profile])
        expect(status == "ok", f"SetRoute app for {args.profile}: ok", f"SetRoute app: {status}")
        expect(route_prop() == "app", "the Route property reads app", f"Route reads {route_prop()}")
        vnode, vsys = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0] and node_by("phys", "ruya-input/pad1"), 3) or (None, None)
        if not vnode:
            bad("no virtual pad (phys ruya-input/pad1) within 3 s of SetRoute app")
            return fails
        ok(f"virtual pad ruya-input/pad1 is {vnode} ({vsys})")
        routed = wait_for(lambda: any(d.get("routed") for d in (devices() or [])), 3)
        ms = int((time.monotonic() - t_route) * 1000)
        expect(routed, f"ListDevices says routed after the ACL is set ({ms} ms after SetRoute app, busctl polling included)",
               "the pad never became routed")
        owner, named = acl_users(vnode)
        expect(owner == "ruya-input", "the virtual node is owned by ruya-input", f"virtual node owner: {owner}")
        expect(named == [args.user], f"its ACL names only {args.user}", f"its ACL names {named}")

        # No legacy joystick API (06 section 3): joydev would make world-readable js nodes.
        js = sorted(glob.glob("/dev/input/js*"))
        expect(not js, "no /dev/input/js* node with a physical and a virtual pad up", f"js nodes exist: {js}")
        for node in js:
            out = subprocess.run(["runuser", "-u", args.other, "--", sys.executable, os.path.abspath(__file__), "open", node],
                                 capture_output=True, text=True).stdout.strip()
            expect(out.startswith("open refused"), f"{args.other} cannot open {node}", f"{args.other} opens {node}: {out}")

        for who in (args.other, "ruya-shell"):
            out = subprocess.run(["runuser", "-u", who, "--", sys.executable, os.path.abspath(__file__), "open", vnode],
                                 capture_output=True, text=True).stdout.strip()
            expect(out.startswith("open refused"), f"{who} cannot open the virtual pad ({out})", f"{who}: {out}")

        game = Game(args.user, vnode)
        expect(game.hello.startswith("OPEN ok"), f"{args.user} opens the virtual pad", f"{args.user}: {game.hello}")
        if not game.hello.startswith("OPEN ok"):
            return fails
        info = json.loads(game.hello[8:])
        # Conformance (the public format, docs/developers/controller-input.md).
        expect(info["name"] == "Ruya Xbox 360 Pad", "conformance: name Ruya Xbox 360 Pad", f"name {info['name']}")
        expect(info["id"] == "0003:045e:028e:0114", "conformance: id 0003:045e:028e:0114", f"id {info['id']}")
        expect(info["keys"] == KEYS, "conformance: the 11 xpad keys (BTN_MODE declared)", f"keys {info['keys']}")
        want_abs = {str(ABS_X): [-32768, 32767, 16, 128], str(ABS_Y): [-32768, 32767, 16, 128], str(ABS_Z): [0, 255, 0, 0],
                    str(ABS_RX): [-32768, 32767, 16, 128], str(ABS_RY): [-32768, 32767, 16, 128], str(ABS_RZ): [0, 255, 0, 0],
                    str(ABS_HAT0X): [-1, 1, 0, 0], str(ABS_HAT0Y): [-1, 1, 0, 0]}
        expect(info["abs"] == want_abs, "conformance: sticks, triggers 0..255 and the hat", f"abs {info['abs']}")
        expect(FF_RUMBLE in info["ff"], "conformance: FF_RUMBLE", f"ff {info['ff']}")

        game.events(100)
        nav.keys(0.1)
        pad.emit(EV_KEY, BTN_SOUTH, 1)
        ev = game.events()
        keys = nav.keys(0.2)
        expect(isinstance(ev, list) and (EV_KEY, BTN_SOUTH, 1) in ev, "app route: South reaches the virtual pad", f"virtual pad read {ev}")
        expect(not any(c == KEY_ENTER for c, _ in keys), "app route: no Enter on the navigation keyboard", f"nav keys {keys}")
        pad.emit(EV_KEY, BTN_MODE, 1)
        pad.emit(EV_KEY, BTN_MODE, 0)
        ev = game.events()
        keys = nav.keys(0.2)
        expect((KEY_HOMEPAGE, 1) in keys, "app route: Guide reaches the shell as KEY_HOMEPAGE", f"nav keys {keys}")
        expect(isinstance(ev, list) and not any(c == BTN_MODE for _, c, _ in ev), "app route: Guide never reaches the virtual pad", f"virtual pad read {ev}")

        # Controller profiles (RUY-42, 06 section 7). South is still held: a global profile that
        # sends South as East takes effect at once, a new press follows it, and removing the
        # assignment gives South back (still held, as the overlay check below expects).
        swap = json.dumps({"schema_version": 1, "id": "vm-check-swap", "name": "VM check swap",
                           "scope": {"type": "global"},
                           "mappings": [{"from": "south", "to": {"type": "button", "code": "east"}}]})
        status = bus.call(SVC, PATH, IFC, "SaveProfile", [args.profile, swap])
        expect(status == "ok", "profiles: SaveProfile of a South-to-East profile: ok", f"profiles: SaveProfile answered {status}")
        game.events(100)
        status = bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", "", "vm-check-swap"])
        expect(status == "ok", "profiles: AssignProfile global: ok", f"profiles: AssignProfile answered {status}")
        ev = game.events_until(lambda ev: (EV_KEY, BTN_SOUTH, 0) in ev and (EV_KEY, BTN_EAST, 1) in ev)
        expect(isinstance(ev, list) and (EV_KEY, BTN_SOUTH, 0) in ev and (EV_KEY, BTN_EAST, 1) in ev,
               "profiles: the held South turns into East on the virtual pad at once", f"profiles: virtual pad read {ev}")
        pad.emit(EV_KEY, BTN_SOUTH, 0)
        pad.emit(EV_KEY, BTN_SOUTH, 1)
        ev = game.events_until(lambda ev: (EV_KEY, BTN_EAST, 0) in ev and (EV_KEY, BTN_EAST, 1) in ev)
        expect(isinstance(ev, list) and (EV_KEY, BTN_EAST, 0) in ev and (EV_KEY, BTN_EAST, 1) in ev
               and not any(c == BTN_SOUTH for _, c, _ in ev),
               "profiles: a press of South reaches the game as East (the remap changes the pad's output)",
               f"profiles: virtual pad read {ev}")
        status = bus.call(SVC, PATH, IFC, "AssignProfile", [args.profile, "global", "", ""])
        ev = game.events_until(lambda ev: (EV_KEY, BTN_EAST, 0) in ev and (EV_KEY, BTN_SOUTH, 1) in ev)
        expect(status == "ok" and isinstance(ev, list) and (EV_KEY, BTN_EAST, 0) in ev and (EV_KEY, BTN_SOUTH, 1) in ev,
               "profiles: without the assignment the held button is South again", f"profiles: {status}, virtual pad read {ev}")
        status = bus.call(SVC, PATH, IFC, "DeleteProfile", [args.profile, "vm-check-swap"])
        expect(status == "ok", "profiles: DeleteProfile: ok", f"profiles: DeleteProfile answered {status}")

        answer = game.ask("rumble")
        got = wait_for(lambda: pad.played, 2)
        expect(answer.startswith("RUMBLE ") and "failed" not in answer, f"the app uploads rumble ({answer})", f"rumble upload: {answer}")
        expect(pad.rumble and pad.rumble[0][1:] == (40000, 20000), f"rumble reaches the physical pad ({pad.rumble})", f"physical pad uploads: {pad.rumble}")
        expect(got, f"the app's play reaches the physical pad ({pad.played})", "no EV_FF play on the physical pad")

        subprocess.run(["udevadm", "trigger", "--action=change", vnode])
        subprocess.run(["udevadm", "settle"])
        time.sleep(0.3)
        owner, named = acl_users(vnode)
        expect(named == [args.user], f"after a udev change event the ACL names only {args.user} again", f"after change: {named}")

        status = bus.call(SVC, PATH, IFC, "SetRoute", ["overlay", "vm-check-1", "org.ruyaos.VmCheck", args.profile])
        expect(status == "ok", "SetRoute overlay: ok", f"SetRoute overlay: {status}")
        ev = game.events()
        expect(isinstance(ev, list) and (EV_KEY, BTN_SOUTH, 0) in ev, "overlay: the held South is released (neutral)", f"virtual pad read {ev}")
        pad.emit(EV_KEY, BTN_SOUTH, 0)
        nav.keys(0.1)
        pad.emit(EV_KEY, BTN_EAST, 1)
        pad.emit(EV_KEY, BTN_EAST, 0)
        ev = game.events()
        keys = nav.keys(0.2)
        expect(ev == [], "overlay: nothing reaches the app", f"virtual pad read {ev}")
        expect((KEY_ESC, 1) in keys, "overlay: East navigates (Esc)", f"nav keys {keys}")

        status = bus.call(SVC, PATH, IFC, "SetRoute", ["locked", "", "", ""])
        expect(status == "ok", "SetRoute locked: ok", f"SetRoute locked: {status}")
        ev = game.events()
        expect(ev == "ERR ENODEV", "lock: the app's open descriptor reads ENODEV", f"after lock the app read {ev}")
        expect(wait_for(lambda: not node_by("phys", "ruya-input/pad1")[0], 2), "lock: the virtual pad is gone", "the virtual pad survived the lock")
        game.close()
        game = None

        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-2", "org.ruyaos.VmCheck", args.profile])
        expect(status == "ok" and wait_for(lambda: node_by("phys", "ruya-input/pad1")[0], 3),
               "a new app route makes a new virtual pad", f"second SetRoute app: {status}")
        bus.close()
        bus = None
        expect(wait_for(lambda: route_prop() == "locked", 3), "the route caller left the bus: Route is locked", f"Route reads {route_prop()}")
        expect(wait_for(lambda: not node_by("phys", "ruya-input/pad1")[0], 2), "... and the virtual pad is destroyed", "the virtual pad survived its caller")
    finally:
        if game:
            game.p.kill()
        if bus:
            bus.close()
        pad.close()
    return fails


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--user", required=True)
    c.add_argument("--profile", required=True)
    c.add_argument("--other", required=True)
    g = sub.add_parser("game")
    g.add_argument("node")
    o = sub.add_parser("open")
    o.add_argument("node")
    sub.add_parser("restart")
    p = sub.add_parser("pad")
    p.add_argument("seconds", type=float)
    cf = sub.add_parser("confirm")
    cf.add_argument("--profile", required=True)
    hd = sub.add_parser("hold")
    hd.add_argument("--profile", required=True)
    tp = sub.add_parser("twopads")
    tp.add_argument("--user", required=True)
    tp.add_argument("--profile", required=True)
    gd = sub.add_parser("guide")
    gd.add_argument("--user", required=True)
    gd.add_argument("--profile", required=True)
    tw = sub.add_parser("twoprofiles")
    tw.add_argument("--user", required=True)
    tw.add_argument("--profile", required=True)
    ua = sub.add_parser("useractive")
    ua.add_argument("--profile", required=True)
    pl = sub.add_parser("playing")
    pl.add_argument("--profile", required=True)
    pl.add_argument("--seconds", type=float, default=30)
    pl.add_argument("--every", type=float, default=2)
    nd = sub.add_parser("nodes")
    nd.add_argument("--user", required=True)
    nd.add_argument("--profile", required=True)
    n = sub.add_parser("navpad")
    n.add_argument("--settle", type=float, default=2.5)
    n.add_argument("--lefts", type=int, default=0)
    n.add_argument("--rights", type=int, default=0)
    n.add_argument("--start", type=int, default=0, help="tap BTN_START this many times instead of BTN_SOUTH")
    args = ap.parse_args()
    if args.cmd == "check":
        sys.exit(1 if cmd_check(args) else 0)
    if args.cmd == "confirm":
        sys.exit(1 if cmd_confirm(args) else 0)
    if args.cmd == "useractive":
        sys.exit(1 if cmd_useractive(args) else 0)
    if args.cmd == "twopads":
        sys.exit(1 if cmd_twopads(args) else 0)
    if args.cmd == "guide":
        sys.exit(1 if cmd_guide(args) else 0)
    if args.cmd == "twoprofiles":
        sys.exit(1 if cmd_twoprofiles(args) else 0)
    if args.cmd == "nodes":
        sys.exit(1 if cmd_nodes(args) else 0)
    if args.cmd == "hold":
        sys.exit(1 if cmd_hold(args) else 0)
    {"game": cmd_game, "open": cmd_open, "restart": cmd_restart, "pad": cmd_pad, "navpad": cmd_navpad, "playing": cmd_playing}[args.cmd](args)


if __name__ == "__main__":
    main()
