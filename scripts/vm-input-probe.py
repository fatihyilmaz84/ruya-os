#!/usr/bin/env python3
"""Probes for scripts/vm-input-check.sh (RUY-3 / T-367): Ruya Input's virtual pads and routing.

  python3 vm-input-probe.py check --user ruya-p1 --profile p1 --other ruya-p2
      As root. Creates a uinput "physical" pad, drives Input1.SetRoute over its own system-bus
      connection (busctl's would leave the bus at once, and a leaving caller locks the route),
      runs a game process as the profile user on the virtual pad, and prints PASS:/FAIL: lines.
  python3 vm-input-probe.py game <node>      (as the profile user; driven by `check` over stdin)
  python3 vm-input-probe.py open <node>      prints "open ok" or "open refused <errno name>"
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
        sig = "s" * len(args)
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

    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_RDWR | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_PHYS, PHYS.encode() + b"\0")
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
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1234, 0x5678, 1, NAME.encode(), 8))
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
        status = bus.call(SVC, PATH, IFC, "SetRoute", ["app", "vm-check-1", "org.ruyaos.VmCheck", args.profile])
        expect(status == "ok", f"SetRoute app for {args.profile}: ok", f"SetRoute app: {status}")
        expect(route_prop() == "app", "the Route property reads app", f"Route reads {route_prop()}")
        vnode, vsys = wait_for(lambda: node_by("phys", "ruya-input/pad1")[0] and node_by("phys", "ruya-input/pad1"), 3) or (None, None)
        if not vnode:
            bad("no virtual pad (phys ruya-input/pad1) within 3 s of SetRoute app")
            return fails
        ok(f"virtual pad ruya-input/pad1 is {vnode} ({vsys})")
        routed = wait_for(lambda: any(d.get("routed") for d in (devices() or [])), 3)
        expect(routed, "ListDevices says routed after the ACL is set", "the pad never became routed")
        owner, named = acl_users(vnode)
        expect(owner == "ruya-input", "the virtual node is owned by ruya-input", f"virtual node owner: {owner}")
        expect(named == [args.user], f"its ACL names only {args.user}", f"its ACL names {named}")

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
        expect((EV_KEY, BTN_SOUTH, 1) in ev, "app route: South reaches the virtual pad", f"virtual pad read {ev}")
        expect(not any(c == KEY_ENTER for c, _ in keys), "app route: no Enter on the navigation keyboard", f"nav keys {keys}")
        pad.emit(EV_KEY, BTN_MODE, 1)
        pad.emit(EV_KEY, BTN_MODE, 0)
        ev = game.events()
        keys = nav.keys(0.2)
        expect((KEY_HOMEPAGE, 1) in keys, "app route: Guide reaches the shell as KEY_HOMEPAGE", f"nav keys {keys}")
        expect(not any(c == BTN_MODE for _, c, _ in ev if isinstance(ev, list)), "app route: Guide never reaches the virtual pad", f"virtual pad read {ev}")

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
    args = ap.parse_args()
    if args.cmd == "check":
        sys.exit(1 if cmd_check(args) else 0)
    {"game": cmd_game, "open": cmd_open}[args.cmd](args)


if __name__ == "__main__":
    main()
