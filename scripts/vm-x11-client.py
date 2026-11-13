#!/usr/bin/env python3
"""A raw X11 client for scripts/vm-x11-check.sh (RUY-436, ADR-034): the X11-only test app and the
isolation probe. Python's standard library only: the test Flatpak runs it with the guest's own python3
(through --filesystem=host-os), and the probe runs it as other users.

  vm-x11-client.py window
      The test app. Reads DISPLAY and XAUTHORITY, connects to /tmp/.X11-unix/X<n>, maps a window (the
      MIT-MAGIC-COOKIE-1 of the first matching Xauthority record), prints one "test-x11-client: ..."
      line and then waits; SIGTERM (the unit's Stop) or the loss of the X connection ends it.
  vm-x11-client.py probe <address> <auth>
      Sends an X11 setup request and prints "accepted", "refused: <why>" or "error: <why>" (exit 0, 1, 2).
      <address>: /path/to/socket, @abstract-name (a leading NUL: "@/tmp/.X11-unix/X0"), tcp:host:port.
      <auth>: none, or hex:<hex> (a MIT-MAGIC-COOKIE-1). A missing socket (ENOENT) is an "error", not a
      refusal: a probe at the wrong place must not pass a negative test.
  vm-x11-client.py cookie <Xauthority file> [display]
      Prints the hex cookie of the first MIT-MAGIC-COOKIE-1 record (that of the display number, if given).

The setup request is the only part of the protocol the isolation test needs; the window needs
CreateWindow, ChangeProperty, MapWindow and one GetInputFocus round trip.
"""
import errno
import os
import signal
import socket
import struct
import sys

COOKIE_NAME = b"MIT-MAGIC-COOKIE-1"
TIMEOUT = 5.0


def pad4(n):
    return (4 - n % 4) % 4


def read_xauthority(path):
    """The records of an Xauthority file: (family, address, number, name, data)."""
    with open(path, "rb") as f:
        raw = f.read()
    records = []
    pos = 0
    while pos + 2 <= len(raw):
        family = struct.unpack(">H", raw[pos:pos + 2])[0]
        pos += 2
        fields = []
        for _ in range(4):
            if pos + 2 > len(raw):
                return records
            (n,) = struct.unpack(">H", raw[pos:pos + 2])
            pos += 2
            fields.append(raw[pos:pos + n])
            pos += n
        records.append((family,) + tuple(fields))
    return records


def cookie_of(path, display=None):
    """The MIT-MAGIC-COOKIE-1 data for `display` (a string), else of the first such record."""
    first = None
    for _family, _addr, number, name, data in read_xauthority(path):
        if name != COOKIE_NAME:
            continue
        if first is None:
            first = data
        if display is not None and number == str(display).encode():
            return data
    return first


def setup_request(name=b"", data=b""):
    out = struct.pack("<BxHHHHxx", 0x6C, 11, 0, len(name), len(data))
    out += name + b"\0" * pad4(len(name)) + data + b"\0" * pad4(len(data))
    return out


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def connect(address):
    """A connected socket for /path, @abstract or tcp:host:port."""
    if address.startswith("tcp:"):
        _tcp, host, port = address.split(":", 2)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target = (host, int(port))
    else:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        target = ("\0" + address[1:]) if address.startswith("@") else address
    s.settimeout(TIMEOUT)
    s.connect(target)
    return s


def handshake(sock, name=b"", data=b""):
    """Sends the setup request. Returns (status, body): status 1 success, 0 failed, 2 authenticate."""
    sock.sendall(setup_request(name, data))
    head = recv_exact(sock, 8)
    status, reason_len = head[0], head[1]
    (extra,) = struct.unpack("<H", head[6:8])
    body = recv_exact(sock, extra * 4)
    if status == 1:
        return status, body
    return status, body[:reason_len] if status == 0 else body


def probe(address, auth):
    name, data = b"", b""
    if auth.startswith("hex:"):
        name, data = COOKIE_NAME, bytes.fromhex(auth[4:])
    elif auth != "none":
        return "error: auth must be none or hex:<cookie>", 2
    try:
        sock = connect(address)
    except (ConnectionRefusedError, PermissionError) as e:
        return "refused: %s" % errno.errorcode.get(e.errno, e), 1
    except socket.timeout:
        return "error: connect timed out", 2
    except OSError as e:
        return "error: %s %s" % (errno.errorcode.get(e.errno, "OSError"), e.strerror or e), 2
    try:
        status, body = handshake(sock, name, data)
    except (EOFError, ConnectionResetError, BrokenPipeError) as e:
        return "refused: connection closed (%s)" % e, 1
    except socket.timeout:
        return "error: no answer to the setup request", 2
    finally:
        sock.close()
    if status == 1:
        return "accepted", 0
    why = body.decode("latin-1").strip() if status == 0 else "authenticate"
    return "refused: setup status %d %s" % (status, why), 1


def parse_setup(body):
    """(resource id base, resource id mask, root window) out of a successful setup reply body."""
    rid_base, rid_mask = struct.unpack("<II", body[4:12])
    (vendor_len,) = struct.unpack("<H", body[16:18])
    formats = body[21]
    pos = 32 + vendor_len + pad4(vendor_len) + formats * 8
    (root,) = struct.unpack("<I", body[pos:pos + 4])
    return rid_base, rid_mask, root


def create_window(sock, wid, root, width, height, pixel):
    # CreateWindow: depth 0 and visual 0 copy the parent's; class InputOutput; one value (BackPixel).
    return struct.pack("<BBHIIhhHHHHIII", 1, 0, 9, wid, root, 0, 0, width, height, 0, 1, 0, 0x2, pixel)


def change_name(wid, title):
    raw = title.encode("latin-1")
    padded = raw + b"\0" * pad4(len(raw))
    # ChangeProperty, mode Replace, WM_NAME (atom 39) of type STRING (atom 31), 8-bit data.
    head = struct.pack("<BBHIIIB3xI", 18, 0, 6 + len(padded) // 4, wid, 39, 31, 8, len(raw))
    return head + padded


def map_window(wid):
    return struct.pack("<BxHI", 8, 2, wid)


def get_input_focus():
    return struct.pack("<BxH", 43, 1)


def window():
    display = os.environ.get("DISPLAY", "")
    xauth = os.environ.get("XAUTHORITY", "")
    if not display.startswith(":") or not display[1:].split(".")[0].isdigit():
        print("test-x11-client: error: DISPLAY is '%s'" % display, flush=True)
        return 1
    number = display[1:].split(".")[0]
    cookie = cookie_of(xauth, number) if xauth else None
    if cookie is None:
        print("test-x11-client: error: no MIT-MAGIC-COOKIE-1 in XAUTHORITY '%s'" % xauth, flush=True)
        return 1
    try:
        # X11_CLIENT_ADDRESS is for the host test (scripts/test-vm-x11-client.py) only.
        sock = connect(os.environ.get("X11_CLIENT_ADDRESS") or "/tmp/.X11-unix/X" + number)
        status, body = handshake(sock, COOKIE_NAME, cookie)
    except (OSError, EOFError) as e:
        print("test-x11-client: error: cannot connect to %s: %s" % (display, e), flush=True)
        return 1
    if status != 1:
        print("test-x11-client: error: setup refused (%d)" % status, flush=True)
        return 1
    rid_base, _mask, root = parse_setup(body)
    wid = rid_base
    sock.sendall(create_window(sock, wid, root, 640, 480, 0x336699) + change_name(wid, "RuyaOS X11 test")
                 + map_window(wid) + get_input_focus())
    # The reply to GetInputFocus is 32 bytes; an error (first byte 0) in front of it means a request failed.
    first = recv_exact(sock, 32)
    if first[0] == 0:
        print("test-x11-client: error: X error code %d" % first[1], flush=True)
        return 1
    print("test-x11-client: uid=%d DISPLAY=%s XAUTHORITY=%s WAYLAND_DISPLAY=%s mapped window=0x%x"
          % (os.getuid() if hasattr(os, "getuid") else -1, display, xauth, os.environ.get("WAYLAND_DISPLAY", ""), wid), flush=True)

    def stop(_signum, _frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    sock.settimeout(None)
    while True:                      # events are read and dropped; the loss of the server ends us
        if not sock.recv(4096):
            print("test-x11-client: the X connection closed", flush=True)
            return 1


def main(argv):
    if len(argv) >= 1 and argv[0] == "window":
        return window()
    if len(argv) == 3 and argv[0] == "probe":
        text, code = probe(argv[1], argv[2])
        print(text)
        return code
    if len(argv) in (2, 3) and argv[0] == "cookie":
        data = cookie_of(argv[1], argv[2] if len(argv) == 3 else None)
        if data is None:
            print("error: no cookie in %s" % argv[1])
            return 2
        print(data.hex())
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
