"""The ROM door fd probe (RUY-1152 spike, ADR-048 A4), run by vm-roms-check.sh. Plain python3 of the
image, no bindings: a minimal D-Bus connection that negotiates unix fds (NEGOTIATE_UNIX_FD, SCM_RIGHTS,
the `h` type), also inside a Flatpak sandbox through /run/host. Roles:
  gamedata <root>   owns org.ruyaos.SpikeGamedata: OpenRom(s id) -> (s status, a(sh) members), one
                    read-only fd per file of <root>/<id>/ (the stand-in for ruya-gamedata)
  door <root>       owns org.ruyaos.SpikeDoor: OpenRom(s id) forwarded to SpikeGamedata, the fds handed
                    on unchanged (the stand-in for ruya-platform); logs whether it can stat <root>
  facts <dest> <id> [<sha256 of the first MiB>]   what a receiver can and cannot do with the fds
  paths <path>...   whether the caller reaches each path (stat, list, open)
  bench <dest> <id> <n>   n calls on one connection: median, p95, min, max in ms
  cold <dest> <id>  one new connection and one call: connect ms, call ms
  call <dest> <iface> <member>   one call without arguments, prints ok or the error name
The id "__none__" answers ok with no members (the same chain without fds).
"""

import array
import errno
import fcntl
import hashlib
import mmap
import os
import re
import socket
import struct
import sys
import time

ALIGN = {"y": 1, "g": 1, "v": 1, "b": 4, "i": 4, "u": 4, "h": 4, "s": 4, "o": 4, "a": 4, "(": 8, "{": 8, "x": 8, "t": 8}
BUS = "org.freedesktop.DBus"
GD = "org.ruyaos.SpikeGamedata"
DOOR = "org.ruyaos.SpikeDoor"
PATH = "/org/ruyaos/Spike"
MAX_FD = 253


def end_of(sig, i):
    c = sig[i]
    if c == "a":
        return end_of(sig, i + 1)
    if c in "({":
        depth = 0
        for j in range(i, len(sig)):
            if sig[j] in "({":
                depth += 1
            elif sig[j] in ")}":
                depth -= 1
                if depth == 0:
                    return j + 1
    return i + 1


def split(sig):
    out, i = [], 0
    while i < len(sig):
        j = end_of(sig, i)
        out.append(sig[i:j])
        i = j
    return out


class W:
    def __init__(self):
        self.b = bytearray()

    def pad(self, n):
        self.b += b"\0" * ((-len(self.b)) % n)

    def put(self, t, v):
        c = t[0]
        if c == "y":
            self.b.append(v)
        elif c in "buh":
            self.pad(4)
            self.b += struct.pack("<I", int(v))
        elif c == "i":
            self.pad(4)
            self.b += struct.pack("<i", v)
        elif c in "so":
            e = v.encode()
            self.pad(4)
            self.b += struct.pack("<I", len(e)) + e + b"\0"
        elif c == "g":
            e = v.encode()
            self.b += bytes([len(e)]) + e + b"\0"
        elif c == "v":
            self.put("g", v[0])
            self.put(v[0], v[1])
        elif c == "a":
            self.pad(4)
            at = len(self.b)
            self.b += b"\0\0\0\0"
            self.pad(ALIGN[t[1]])
            start = len(self.b)
            for x in v:
                self.put(t[1:], x)
            struct.pack_into("<I", self.b, at, len(self.b) - start)
        elif c in "({":
            self.pad(8)
            for sub, x in zip(split(t[1:-1]), v):
                self.put(sub, x)
        else:
            raise ValueError(f"type {c} not supported")


class R:
    def __init__(self, b, p):
        self.b, self.p = b, p

    def al(self, n):
        self.p += (-self.p) % n

    def u32(self):
        self.al(4)
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def get(self, t):
        c = t[0]
        if c == "y":
            self.p += 1
            return self.b[self.p - 1]
        if c in "buh":
            v = self.u32()
            return bool(v) if c == "b" else v
        if c == "i":
            self.al(4)
            self.p += 4
            return struct.unpack_from("<i", self.b, self.p - 4)[0]
        if c in "so":
            n = self.u32()
            v = self.b[self.p:self.p + n].decode()
            self.p += n + 1
            return v
        if c == "g":
            n = self.b[self.p]
            v = self.b[self.p + 1:self.p + 1 + n].decode()
            self.p += n + 2
            return v
        if c == "v":
            sig = self.get("g")
            return (sig, self.get(sig))
        if c == "a":
            n = self.u32()
            self.al(ALIGN[t[1]])
            end, out = self.p + n, []
            while self.p < end:
                out.append(self.get(t[1:]))
            return out
        if c in "({":
            self.al(8)
            return tuple(self.get(x) for x in split(t[1:-1]))
        raise ValueError(f"type {c} not supported")


class DBusError(RuntimeError):
    def __init__(self, name, text):
        super().__init__(f"{name}: {text}")
        self.name = name


class Conn:
    def __init__(self, path=None):
        if path is None:
            addr = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/run/dbus/system_bus_socket")
            path = addr.split("path=", 1)[1].split(",", 1)[0]
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf, self.fds, self.serial, self.pending = b"", [], 0, []
        self.sock.sendall(b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
        if not self._line().startswith(b"OK"):
            raise RuntimeError("auth refused")
        self.sock.sendall(b"NEGOTIATE_UNIX_FD\r\n")
        line = self._line()
        if line != b"AGREE_UNIX_FD":
            raise RuntimeError(f"no unix fds: {line!r}")
        self.sock.sendall(b"BEGIN\r\n")
        self.name = self.call(BUS, "/org/freedesktop/DBus", BUS, "Hello")[0][0]

    def _line(self):
        while b"\r\n" not in self.buf:
            d = self.sock.recv(4096)
            if not d:
                raise EOFError("bus closed")
            self.buf += d
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _more(self):
        data, anc, _flags, _addr = self.sock.recvmsg(65536, socket.CMSG_SPACE(MAX_FD * 4))
        for level, kind, raw in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array("i")
                a.frombytes(raw[:len(raw) - len(raw) % 4])
                self.fds.extend(a)
        if not data:
            raise EOFError("bus closed")
        self.buf += data

    def _read(self):
        while len(self.buf) < 16:
            self._more()
        blen, = struct.unpack_from("<I", self.buf, 4)
        hlen, = struct.unpack_from("<I", self.buf, 12)
        body = 16 + hlen + ((-(16 + hlen)) % 8)
        while len(self.buf) < body + blen:
            self._more()
        raw, self.buf = self.buf[:body + blen], self.buf[body + blen:]
        fields = dict(R(raw, 12).get("a(yv)"))
        fields = {k: v[1] for k, v in fields.items()}
        n = fields.get(9, 0)
        fds, self.fds = self.fds[:n], self.fds[n:]
        r = R(raw, body)
        args = [r.get(t) for t in split(fields.get(8, ""))]
        return {"type": raw[1], "serial": struct.unpack_from("<I", raw, 8)[0], "f": fields, "args": args, "fds": fds}

    def _send(self, kind, fields, sig="", args=(), fds=()):
        body = W()
        for t, v in zip(split(sig), args):
            body.put(t, v)
        self.serial += 1
        hf = list(fields)
        if sig:
            hf.append((8, ("g", sig)))
        if fds:
            hf.append((9, ("u", len(fds))))
        h = W()
        h.b += struct.pack("<cBBBII", b"l", kind, 0, 1, len(body.b), self.serial)
        h.put("a(yv)", hf)
        h.pad(8)
        data = bytes(h.b + body.b)
        if fds:
            sent = self.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
            if sent < len(data):
                self.sock.sendall(data[sent:])
        else:
            self.sock.sendall(data)
        return self.serial

    def call(self, dest, path, iface, member, sig="", args=(), fds=()):
        serial = self._send(1, [(1, ("o", path)), (2, ("s", iface)), (3, ("s", member)), (6, ("s", dest))], sig, args, fds)
        while True:
            m = self._read()
            if m["type"] in (2, 3) and m["f"].get(5) == serial:
                if m["type"] == 3:
                    for fd in m["fds"]:
                        os.close(fd)
                    raise DBusError(m["f"].get(4), m["args"][0] if m["args"] else "")
                return m["args"], m["fds"]
            self.pending.append(m)

    def reply(self, m, sig, args, fds=()):
        self._send(2, [(5, ("u", m["serial"])), (6, ("s", m["f"][7]))], sig, args, fds)

    def error(self, m, name, text):
        self._send(3, [(5, ("u", m["serial"])), (6, ("s", m["f"][7])), (4, ("s", name))], "s", (text,))

    def own(self, name):
        got = self.call(BUS, "/org/freedesktop/DBus", BUS, "RequestName", "su", (name, 4))[0][0]
        if got != 1:
            raise RuntimeError(f"RequestName {name}: {got}")

    def next(self):
        return self.pending.pop(0) if self.pending else self._read()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def serve(conn, handler):
    while True:
        m = conn.next()
        if m["type"] != 1:
            continue
        if m["f"].get(3) != "OpenRom" or m["f"].get(8) != "s":
            conn.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "only OpenRom(s)")
            continue
        handler(m)


def role_gamedata(root):
    conn = Conn()
    conn.own(GD)
    log(f"gamedata {conn.name} serving {root}")

    def handle(m):
        rid = m["args"][0]
        if rid == "__none__":
            return conn.reply(m, "sa(sh)", ("ok", []))
        if not re.fullmatch(r"[a-z0-9_]{1,64}", rid):
            return conn.reply(m, "sa(sh)", ("invalid-argument", []))
        d = os.path.join(root, rid)
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            return conn.reply(m, "sa(sh)", ("not-found", []))
        fds, members = [], []
        try:
            for i, name in enumerate(names):
                fd = os.open(os.path.join(d, name), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NOCTTY)
                fds.append(fd)
                members.append((name, i))
            conn.reply(m, "sa(sh)", ("ok", members), fds)
        except OSError as e:
            log(f"OpenRom {rid}: {e}")
            conn.reply(m, "sa(sh)", ("failed", []))
        finally:
            for fd in fds:
                os.close(fd)
    serve(conn, handle)


def role_door(root):
    try:
        os.stat(os.path.join(root, "small"))
        log(f"door: stat {root}/small WORKS (the door can see the collection)")
    except OSError as e:
        log(f"door: stat {root}/small -> {errno.errorcode[e.errno]}")
    conn = Conn()
    conn.own(DOOR)
    up = Conn()
    log(f"door {conn.name} forwarding to {GD} over {up.name}")

    def handle(m):
        rid = m["args"][0]
        try:
            args, fds = up.call(GD, PATH, GD, "OpenRom", "s", (rid,))
        except DBusError as e:
            return conn.error(m, e.name, str(e))
        try:
            conn.reply(m, "sa(sh)", args, fds)
        except OSError as e:
            log(f"door: reply with {len(fds)} fds: {e}")
            conn.reply(m, "sa(sh)", ("failed", []))
        finally:
            for fd in fds:
                os.close(fd)
    serve(conn, handle)


def err(fn):
    try:
        r = fn()
        return f"ok{'' if r is None else ' ' + str(r)}"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
    except (ValueError, TypeError) as e:
        return f"{type(e).__name__}({e})"


def sha_first(fd):
    return hashlib.sha256(os.pread(fd, 1 << 20, 0)).hexdigest()


def role_facts(dest, rid, want=""):
    conn = Conn()
    t0 = time.perf_counter_ns()
    try:
        (status, members), fds = conn.call(dest, PATH, dest, "OpenRom", "s", (rid,))
    except DBusError as e:
        print(f"FACT call {e.name}")
        return
    print(f"FACT call status={status} members={len(members)} fds={len(fds)} ms={(time.perf_counter_ns() - t0) / 1e6:.3f}")
    if status != "ok":
        return
    tmp = os.path.join(os.environ.get("XDG_DATA_HOME") or "/var/tmp", "spike-link")
    for name, idx in members[:3]:
        fd = fds[idx]
        st = os.fstat(fd)
        acc = {os.O_RDONLY: "O_RDONLY", os.O_WRONLY: "O_WRONLY", os.O_RDWR: "O_RDWR"}[fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE]
        p = f"/proc/self/fd/{fd}"
        print(f"FACT member {name} fd={fd} size={st.st_size} uid={st.st_uid} mode={oct(st.st_mode & 0o7777)} flags={acc}")
        got = sha_first(fd)
        print(f"FACT read sha256(first MiB)={'match' if want and got == want else got}")
        print(f"FACT pread at end-4096: {err(lambda: len(os.pread(fd, 4096, max(0, st.st_size - 4096))))}")
        print(f"FACT write(fd): {err(lambda: os.write(fd, b'x'))}")
        print(f"FACT readlink {p}: {err(lambda: os.readlink(p))}")

        def reopen(flags):
            def f():
                n = os.open(p, flags)
                try:
                    return sha_first(n)[:12] if flags & os.O_ACCMODE != os.O_WRONLY else None
                finally:
                    os.close(n)
            return f
        print(f"FACT reopen O_RDONLY: {err(reopen(os.O_RDONLY))}")
        print(f"FACT reopen O_RDWR: {err(reopen(os.O_RDWR))}")
        print(f"FACT reopen O_WRONLY|O_APPEND: {err(reopen(os.O_WRONLY | os.O_APPEND))}")
        print(f"FACT reopen O_RDONLY|O_TRUNC: {err(reopen(os.O_RDONLY | os.O_TRUNC))}")

        def setfl():
            fcntl.fcntl(fd, fcntl.F_SETFL, os.O_RDWR)
            return {0: "O_RDONLY", 1: "O_WRONLY", 2: "O_RDWR"}[fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE]
        print(f"FACT fcntl(F_SETFL, O_RDWR) then access mode: {err(setfl)}")
        print(f"FACT ftruncate: {err(lambda: os.ftruncate(fd, 0))}")
        print(f"FACT fchmod 0666: {err(lambda: os.fchmod(fd, 0o666))}")
        print(f"FACT fchown self: {err(lambda: os.fchown(fd, os.getuid(), os.getgid()))}")
        print(f"FACT setxattr user.x: {err(lambda: os.setxattr(fd, 'user.x', b'1'))}")
        print(f"FACT ioctl FS_IOC_SETFLAGS: {err(lambda: fcntl.ioctl(fd, 0x40086602, struct.pack('l', 0)))}")
        print(f"FACT mmap MAP_SHARED|PROT_WRITE: {err(lambda: mmap.mmap(fd, min(4096, st.st_size), mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE).close())}")
        print(f"FACT mmap MAP_PRIVATE|PROT_READ: {err(lambda: mmap.mmap(fd, min(4096, st.st_size), mmap.MAP_PRIVATE, mmap.PROT_READ).close())}")
        print(f"FACT openat(fd, '..'): {err(lambda: os.close(os.open('..', os.O_RDONLY, dir_fd=fd)))}")
        print(f"FACT open {p}/..: {err(lambda: os.close(os.open(p + '/..', os.O_RDONLY)))}")

        def link():
            os.link(p, tmp, follow_symlinks=True)
            os.unlink(tmp)
        print(f"FACT link {p} into the app's data: {err(link)}")
    for fd in fds:
        os.close(fd)


def role_paths(paths):
    for p in paths:
        print(f"PATH {p} stat={err(lambda: oct(os.stat(p).st_mode))} list={err(lambda: len(os.listdir(p)))} "
              f"open={err(lambda: os.close(os.open(p, os.O_RDONLY)))}")


def one(conn, dest, rid):
    t0 = time.perf_counter_ns()
    (status, _members), fds = conn.call(dest, PATH, dest, "OpenRom", "s", (rid,))
    t = (time.perf_counter_ns() - t0) / 1e6
    for fd in fds:
        os.close(fd)
    if status != "ok":
        raise RuntimeError(f"OpenRom {rid}: {status}")
    return t, len(fds)


def role_bench(dest, rid, n):
    conn = Conn()
    one(conn, dest, rid)
    ts, nfd = [], 0
    for _ in range(n):
        t, nfd = one(conn, dest, rid)
        ts.append(t)
    ts.sort()
    p95 = ts[min(len(ts) - 1, int(round(0.95 * len(ts))) - 1)]
    print(f"BENCH dest={dest} id={rid} n={n} fds={nfd} median={ts[len(ts) // 2]:.3f} p95={p95:.3f} min={ts[0]:.3f} max={ts[-1]:.3f} ms")


def role_cold(dest, rid):
    t0 = time.perf_counter_ns()
    conn = Conn()
    c = (time.perf_counter_ns() - t0) / 1e6
    t, nfd = one(conn, dest, rid)
    print(f"COLD connect={c:.3f} call={t:.3f} fds={nfd} ms")


def role_call(dest, iface, member):
    conn = Conn()
    try:
        conn.call(dest, PATH, iface, member)
        print("CALL ok")
    except DBusError as e:
        print(f"CALL {e.name}")


def main(a):
    if a[0] == "gamedata":
        role_gamedata(a[1])
    elif a[0] == "door":
        role_door(a[1])
    elif a[0] == "facts":
        role_facts(a[1], a[2], a[3] if len(a) > 3 else "")
    elif a[0] == "paths":
        role_paths(a[1:])
    elif a[0] == "bench":
        role_bench(a[1], a[2], int(a[3]))
    elif a[0] == "cold":
        role_cold(a[1], a[2])
    elif a[0] == "call":
        role_call(a[1], a[2], a[3])
    else:
        raise SystemExit(f"unknown role {a[0]}")


if __name__ == "__main__":
    main(sys.argv[1:])
