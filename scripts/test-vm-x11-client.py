#!/usr/bin/env python3
"""Host test of scripts/vm-x11-client.py (RUY-436) against a fake X server in this process: the isolation
probe tells accepted from refused from a wrong-place error, the cookie file is read like Flatpak's, and the
test app sends CreateWindow, ChangeProperty, MapWindow and GetInputFocus. Run by scripts/test-vm-checks.sh.
Prints "    ok   ..." and "    FAIL ..." lines like that script; exit 1 on a failure."""
import importlib.util
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True      # no __pycache__ next to the script
here = os.path.dirname(os.path.abspath(__file__))
client_path = os.path.join(here, "vm-x11-client.py")
spec = importlib.util.spec_from_file_location("vm_x11_client", client_path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)

fails = 0
# A Windows python has no AF_UNIX: the fake server then listens on loopback TCP (the probe and the window
# take tcp: addresses too) and the unix-only checks run on Linux (CI, WSL) only.
HAS_UNIX = hasattr(socket, "AF_UNIX")


def check(name, cond, detail=""):
    global fails
    if cond:
        print("    ok   " + name)
    else:
        fails += 1
        print("    FAIL %s %s" % (name, detail))


COOKIE = bytes(range(16))
OTHER = bytes(range(16, 32))
RID_BASE = 0x04000000


def recv_all(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def success_reply():
    body = struct.pack("<IIIIHHBBBBBBBB4x", 1, RID_BASE, 0x1FFFFF, 256, 4, 65535, 1, 1, 0, 0, 32, 32, 8, 255)
    body += b"Test" + b"\x18\x20\x20\x00" + b"\0" * 4          # vendor, one pixmap format
    body += struct.pack("<IIIIIHHHHHHIBBBB", 0x2A, 0x20, 0xFFFFFF, 0, 0, 1920, 1080, 508, 285, 1, 1, 0x21, 0, 0, 24, 0)
    return struct.pack("<BxHHH", 1, 11, 0, len(body) // 4) + body


class FakeX:
    """An X server that accepts one cookie and records the opcodes of the requests after the setup."""

    def __init__(self, path, cookie):
        self.cookie = cookie
        self.requests = []          # (opcode, bytes)
        self.setups = []            # (auth name, auth data)
        if HAS_UNIX:
            self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.server.bind(path)
            self.address = path
        else:
            self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server.bind(("127.0.0.1", 0))
            self.address = "tcp:127.0.0.1:%d" % self.server.getsockname()[1]
        self.server.listen(8)
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        try:
            head = recv_all(conn, 12)
            n, d = struct.unpack("<HH", head[6:10])
            name = recv_all(conn, n + client.pad4(n))[:n]
            data = recv_all(conn, d + client.pad4(d))[:d]
            self.setups.append((name, data))
            if name != client.COOKIE_NAME or data != self.cookie:
                reason = b"Authorization required"
                body = reason + b"\0" * client.pad4(len(reason))
                conn.sendall(struct.pack("<BBHHH", 0, len(reason), 11, 0, len(body) // 4) + body)
                return
            conn.sendall(success_reply())
            while True:
                req = recv_all(conn, 4)
                (words,) = struct.unpack("<H", req[2:4])
                req += recv_all(conn, words * 4 - 4)
                self.requests.append((req[0], req))
                if req[0] == 43:
                    conn.sendall(struct.pack("<BBHI", 1, 1, 1, 0) + b"\0" * 24)
        except (EOFError, OSError):
            pass
        finally:
            conn.close()


def xauth_record(display, cookie, family=65535):
    out = struct.pack(">H", family)
    for field in (b"", str(display).encode(), client.COOKIE_NAME, cookie):
        out += struct.pack(">H", len(field)) + field
    return out


with tempfile.TemporaryDirectory() as tmp:
    sock_path = os.path.join(tmp, "X7")
    x = FakeX(sock_path, COOKIE)

    print("vm-x11-client.py probe: accepted, refused and wrong-place")
    text, code = client.probe(x.address, "hex:" + COOKIE.hex())
    check("the right cookie is accepted", (text, code) == ("accepted", 0), (text, code))
    text, code = client.probe(x.address, "none")
    check("no cookie is refused", code == 1 and text.startswith("refused: setup status 0 Authorization required"), (text, code))
    text, code = client.probe(x.address, "hex:" + OTHER.hex())
    check("another instance's cookie is refused", code == 1 and text.startswith("refused:"), (text, code))
    if HAS_UNIX:
        text, code = client.probe(os.path.join(tmp, "nothing-here"), "none")
        check("a missing socket is an error, not a refusal", code == 2 and text.startswith("error: ENOENT"), (text, code))
    else:
        print("    (unix-socket probes run on Linux only)")
    text, code = client.probe(x.address, "rubbish")
    check("a bad auth argument is an error", code == 2, (text, code))
    # A TCP port nobody listens on: ECONNREFUSED, a refusal (the "no TCP listener" probe).
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    text, code = client.probe("tcp:127.0.0.1:%d" % port, "none")
    check("a closed TCP port is a refusal", code == 1 and text.startswith("refused:"), (text, code))
    if sys.platform.startswith("linux"):
        text, code = client.probe("@/tmp/.X11-unix/X-no-such-listener-%d" % os.getpid(), "none")
        check("an abstract name nobody listens on is a refusal", code == 1 and text.startswith("refused: ECONNREFUSED"), (text, code))
        asock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        aname = "/tmp/.X11-unix/Xtest-%d" % os.getpid()
        asock.bind("\0" + aname)
        asock.listen(1)

        def accept_and_close():
            c, _ = asock.accept()
            c.close()
        threading.Thread(target=accept_and_close, daemon=True).start()
        text, code = client.probe("@" + aname, "none")
        check("an abstract listener that closes at once is a refusal", code == 1, (text, code))
    else:
        print("    (abstract-socket probes run on Linux only)")

    print("vm-x11-client.py cookie: the Xauthority file as Flatpak passes it on")
    auth = os.path.join(tmp, "Xauthority")
    with open(auth, "wb") as f:
        f.write(xauth_record(3, OTHER) + xauth_record(7, COOKIE))
    check("the cookie of the display asked for", client.cookie_of(auth, 7) == COOKIE)
    check("the first cookie when the display is not named", client.cookie_of(auth) == OTHER)
    check("the first cookie when no record matches (Flatpak renumbers the display)", client.cookie_of(auth, 99) == OTHER)
    with open(auth, "wb") as f:
        f.write(xauth_record(7, COOKIE, family=256))
    check("a file with a cookie of another family is read too", client.cookie_of(auth, 7) == COOKIE)
    with open(auth, "wb") as f:
        pass
    check("an empty file has no cookie", client.cookie_of(auth, 7) is None)
    out = subprocess.run([sys.executable, client_path, "cookie", auth], capture_output=True, text=True)
    check("the cookie subcommand fails on an empty file", out.returncode == 2, out.returncode)

    print("vm-x11-client.py window: the test app maps a window")
    with open(auth, "wb") as f:
        f.write(xauth_record(7, COOKIE))
    env = dict(os.environ, DISPLAY=":7", XAUTHORITY=auth, X11_CLIENT_ADDRESS=x.address)
    env.pop("WAYLAND_DISPLAY", None)
    proc = subprocess.Popen([sys.executable, client_path, "window"], env=env, stdout=subprocess.PIPE, text=True)
    line = proc.stdout.readline()
    check("it prints its mapped line with display and no Wayland",
          line.startswith("test-x11-client: uid=") and "DISPLAY=:7 " in line and "WAYLAND_DISPLAY= " in line
          and "mapped window=0x%x" % RID_BASE in line, line)
    opcodes = [op for op, _ in x.requests]
    check("it sent CreateWindow, ChangeProperty, MapWindow, GetInputFocus", opcodes == [1, 18, 8, 43], opcodes)
    created = [r for op, r in x.requests if op == 1]
    check("CreateWindow names the first resource id and the server's root window",
          created and struct.unpack("<II", created[0][4:12]) == (RID_BASE, 0x2A), created)
    named = [r for op, r in x.requests if op == 18]
    check("the window has a name", named and b"RuyaOS X11 test" in named[0], named)
    mapped = [r for op, r in x.requests if op == 8]
    check("MapWindow maps the created window", mapped and struct.unpack("<I", mapped[0][4:8]) == (RID_BASE,), mapped)
    if sys.platform.startswith("linux"):
        proc.terminate()
        check("SIGTERM ends it with status 0", proc.wait(10) == 0)
    else:
        proc.kill()
        proc.wait(10)
    proc.stdout.close()

    with open(auth, "wb") as f:
        f.write(xauth_record(7, OTHER))
    out = subprocess.run([sys.executable, client_path, "window"], env=env, capture_output=True, text=True, timeout=20)
    check("with the wrong cookie it exits 1 and says so", out.returncode == 1 and "setup refused" in out.stdout, (out.returncode, out.stdout))
    env["DISPLAY"] = ""
    out = subprocess.run([sys.executable, client_path, "window"], env=env, capture_output=True, text=True, timeout=20)
    check("without DISPLAY it exits 1", out.returncode == 1 and "DISPLAY is ''" in out.stdout, (out.returncode, out.stdout))

sys.exit(1 if fails else 0)
