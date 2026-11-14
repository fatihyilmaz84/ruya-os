#!/usr/bin/env python3
"""A Wayland client that asks for the screen to stay on (RUY-561), for scripts/vm-power-saving-check.sh.

It speaks the Wayland wire protocol over the socket itself (python3 only, no libwayland, no
pywayland): it binds wl_compositor, wl_shm, xdg_wm_base and zwp_idle_inhibit_manager_v1, shows
one small xdg toplevel (a shm buffer) and creates an idle inhibitor on its surface, as an SDL game
does on its first window. It then idles and answers pings until it is killed.

  runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$(id -u ruya-shell) WAYLAND_DISPLAY=ruya-0 \
      python3 /var/tmp/vm-idle-inhibit-client.py [--app-id ID]

Prints "inhibitor created" once the inhibitor exists. A test tool only; never shipped in the image.
"""
import argparse
import array
import os
import socket
import struct
import sys

WL_DISPLAY = 1


class Wire:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 2
        self.handlers = {}      # object id -> function(opcode, payload)

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    @staticmethod
    def string(s):
        raw = s.encode() + b"\0"
        raw += b"\0" * (-len(raw) % 4)
        return struct.pack("I", len(s) + 1) + raw

    def send(self, obj, opcode, payload=b"", fd=None):
        msg = struct.pack("II", obj, ((8 + len(payload)) << 16) | opcode) + payload
        if fd is None:
            self.sock.sendall(msg)
        else:
            self.sock.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])

    def pump(self):
        """Reads what is there (blocking for at least one chunk) and dispatches whole events."""
        data = self.sock.recv(65536)
        if not data:
            sys.exit("compositor closed the connection")
        self.buf += data
        while len(self.buf) >= 8:
            obj, word = struct.unpack("II", self.buf[:8])
            size, opcode = word >> 16, word & 0xFFFF
            if len(self.buf) < size:
                break
            payload, self.buf = self.buf[8:size], self.buf[size:]
            if obj == WL_DISPLAY and opcode == 0:
                target, code = struct.unpack("II", payload[:8])
                (n,) = struct.unpack("I", payload[8:12])
                sys.exit("wl_display.error object %d code %d: %s" % (target, code, payload[12:12 + n - 1].decode()))
            handler = self.handlers.get(obj)
            if handler:
                handler(opcode, payload)

    def roundtrip(self):
        cb = self.new_id()
        done = []
        self.handlers[cb] = lambda op, p: done.append(op)
        self.send(WL_DISPLAY, 0, struct.pack("I", cb))     # wl_display.sync
        while not done:
            self.pump()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-id", default="org.ruyaos.IdleInhibitClient")
    args = ap.parse_args()
    path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "ruya-0"))
    w = Wire(path)

    globals_ = {}                   # interface -> (name, version)

    def on_global(op, p):
        if op != 0:
            return
        name, n = struct.unpack("II", p[:8])
        iface = p[8:8 + n - 1].decode()
        off = 8 + ((n + 3) & ~3)
        (version,) = struct.unpack("I", p[off:off + 4])
        globals_[iface] = (name, version)

    registry = w.new_id()
    w.handlers[registry] = on_global
    w.send(WL_DISPLAY, 1, struct.pack("I", registry))      # wl_display.get_registry
    w.roundtrip()

    def bind(iface, want):
        if iface not in globals_:
            sys.exit("the compositor has no " + iface)
        name, version = globals_[iface]
        v = min(version, want)
        i = w.new_id()
        w.send(registry, 0, struct.pack("I", name) + Wire.string(iface) + struct.pack("II", v, i))
        return i

    compositor = bind("wl_compositor", 4)
    shm = bind("wl_shm", 1)
    wm_base = bind("xdg_wm_base", 1)
    manager = bind("zwp_idle_inhibit_manager_v1", 1)

    w.handlers[wm_base] = lambda op, p: w.send(wm_base, 3, p) if op == 0 else None     # ping -> pong

    surface = w.new_id()
    w.send(compositor, 0, struct.pack("I", surface))                       # create_surface
    xdg_surface = w.new_id()
    w.send(wm_base, 2, struct.pack("II", xdg_surface, surface))            # get_xdg_surface
    toplevel = w.new_id()
    w.send(xdg_surface, 1, struct.pack("I", toplevel))                     # get_toplevel
    w.send(toplevel, 2, Wire.string("Idle inhibit client"))                # set_title
    w.send(toplevel, 3, Wire.string(args.app_id))                          # set_app_id

    configured = []

    def on_xdg_surface(op, p):
        if op == 0:                                                        # configure(serial)
            w.send(xdg_surface, 4, p[:4])                                  # ack_configure
            configured.append(True)

    w.handlers[xdg_surface] = on_xdg_surface
    w.send(surface, 6)                                                     # commit (no buffer yet)
    while not configured:
        w.pump()

    width, height = 64, 64
    stride = width * 4
    size = stride * height
    fd = os.memfd_create("idle-inhibit-client")
    os.ftruncate(fd, size)
    os.write(fd, b"\x40\x80\xc0\xff" * (width * height))                   # opaque bluish pixels
    pool = w.new_id()
    w.send(shm, 0, struct.pack("Ii", pool, size), fd=fd)                   # create_pool
    buf = w.new_id()
    w.send(pool, 0, struct.pack("IiiiiI", buf, 0, width, height, stride, 1))   # create_buffer, xrgb8888
    w.send(surface, 1, struct.pack("Iii", buf, 0, 0))                      # attach
    w.send(surface, 6)                                                     # commit

    inhibitor = w.new_id()
    w.send(manager, 1, struct.pack("II", inhibitor, surface))              # create_inhibitor
    w.roundtrip()
    print("inhibitor created", flush=True)
    while True:
        w.pump()


if __name__ == "__main__":
    main()
