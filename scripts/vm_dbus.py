"""A minimal D-Bus client for the VM checks (AUTH EXTERNAL, Hello, method calls with string, uint32 and
boolean arguments, the messages that arrive), no bindings needed: plain python3 of the image, also inside a
sandbox through /run/host (vm-platform-check.sh, RUY-157). Moved out of vm-input-probe.py, which imports it;
vm-queue.ps1 copies every vm_*.py next to the checks.
"""

import os
import select
import socket
import struct


class DBusError(RuntimeError):
    """An error reply: `name` is its error name (org.freedesktop.DBus.Error.AccessDenied, ...)."""

    def __init__(self, member, name, text):
        super().__init__(f"{member}: D-Bus error {text}")
        self.name = name
        self.text = text

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
        self.fields = {}
        self.backlog = []  # messages that arrived while call() waited for its reply: (kind, fields, body)
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
        sig = "".join("b" if isinstance(a, bool) else "u" if isinstance(a, int) else "s" for a in args)
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
            elif isinstance(a, int):
                self._pad(b, 4)
                b += struct.pack("<I", a)
            else:
                self._str(b, a)
        struct.pack_into("<I", b, 4, len(b) - body_start)
        self.sock.sendall(bytes(b))
        while True:
            kind, reply_to, body = self._message()
            if reply_to == self.serial:
                self.body = body
                text = self._first_string(body)
                if kind == 3:
                    raise DBusError(member, self.fields.get(4, ""), text)
                return text
            self.backlog.append((kind, dict(self.fields), body))

    def next_message(self, timeout):
        """The next message that is no reply to a call (a signal, mostly) as (kind, fields, body), fields
        keyed by header field code (1 path, 2 interface, 3 member, 4 error name, 6 destination, 7 sender);
        None when nothing came within `timeout` seconds."""
        if self.backlog:
            return self.backlog.pop(0)
        if not self.buf and not select.select([self.sock], [], [], timeout)[0]:
            return None
        kind, _reply_to, body = self._message()
        return kind, dict(self.fields), body

    def _message(self):
        self.member = None
        self.fields = {}
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
                self.fields[code] = fields[i + 4:i + 4 + n].decode(errors="replace")
                if code == 3:
                    self.member = self.fields[code]
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
    def status_and_slot(body):
        """A reply body of signature (su), JoinPlayer's: (status, slot); slot 0 when it is missing."""
        if len(body) < 4:
            return "", 0
        n = struct.unpack_from("<I", body, 0)[0]
        status = body[4:4 + n].decode(errors="replace")
        off = 4 + n + 1
        off += -off % 4
        slot = struct.unpack_from("<I", body, off)[0] if len(body) >= off + 4 else 0
        return status, slot

    @staticmethod
    def _first_string(body):
        if len(body) < 4:
            return ""
        n = struct.unpack_from("<I", body, 0)[0]
        return body[4:4 + n].decode(errors="replace")

    def close(self):
        self.sock.close()
