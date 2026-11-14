#!/usr/bin/env python3
"""Host test of scripts/vm-input-probe.py's signal listener (RUY-594): Bus reads a signal's member from the
header, and `listen` prints "heard <member>" for Input1's signals and "bus <member>" for the bus's own, and
nothing for a method reply. The VM check (vm-input-check.sh signals) relies on that split. Run by
scripts/test-vm-checks.sh. Prints "    ok   ..." and "    FAIL ..." lines like that script; exit 1 on a failure."""
import contextlib
import importlib.util
import io
import os
import socket
import struct
import sys
import types

sys.dont_write_bytecode = True
here = os.path.dirname(os.path.abspath(__file__))
# The probe imports Linux-only modules at the top; the parts tested here do not use them.
for name in ("fcntl", "pwd"):
    if name not in sys.modules:
        try:
            __import__(name)
        except ImportError:
            sys.modules[name] = types.ModuleType(name)
spec = importlib.util.spec_from_file_location("vm_input_probe", os.path.join(here, "vm-input-probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

fails = 0


def check(name, cond, detail=""):
    global fails
    if cond:
        print("    ok   " + name)
    else:
        fails += 1
        print("    FAIL %s %s" % (name, detail))


def pad(b, n):
    while len(b) % n:
        b.append(0)


def message(kind, member=None, reply_to=None):
    """A little-endian D-Bus message with the header fields the bus puts on a signal (path, interface, member,
    sender) or on a method return (reply serial), and no body."""
    fields = bytearray()

    def string_field(code, sig, value):
        pad(fields, 8)
        fields.append(code)
        fields.extend(bytes([1]) + sig.encode() + b"\0")
        pad(fields, 4)          # strings align to 4 inside the array, which itself starts at offset 16 (a multiple of 8)
        e = value.encode()
        fields.extend(struct.pack("<I", len(e)) + e + b"\0")

    if kind == 4:
        string_field(1, "o", "/org/ruyaos/Input1")
        string_field(2, "s", "org.ruyaos.Input1")
        string_field(3, "s", member)
        string_field(7, "s", ":1.7")
    else:
        pad(fields, 8)
        fields.append(5)
        fields.extend(bytes([1]) + b"u\0")
        pad(fields, 4)
        fields.extend(struct.pack("<I", reply_to))
    head = b"l" + bytes([kind, 0, 1]) + struct.pack("<II", 0, 1) + struct.pack("<I", len(fields))
    out = bytearray(head) + fields
    pad(out, 8)
    return bytes(out)


bus_peers = []


def fake_bus(messages):
    """A probe.Bus that skips the connection and AUTH and reads `messages` from a socket pair."""
    a, b = socket.socketpair()
    for m in messages:
        b.sendall(m)
    bus_peers.append(b)   # stays open: the listener ends on its timeout, as on the real bus
    bus = probe.Bus.__new__(probe.Bus)
    bus.sock, bus.buf, bus.serial, bus.name, bus.member = a, b"", 0, ":1.9", None
    bus.matches = []
    bus.call = lambda dest, path, iface, member, args: bus.matches.append(args[0]) or ""
    return bus


bus = fake_bus([message(4, "TestInput"), message(2, reply_to=5), message(4, "NameOwnerChanged")])
kind, _reply, _body = bus._message()
check("a signal is kind 4", kind == 4)
check("its member is read from the header", bus.member == "TestInput", bus.member)
kind, reply_to, _body = bus._message()
check("a method return has no member", kind != 4 and bus.member is None, (kind, bus.member))
check("and still names the call it answers", reply_to == 5, reply_to)
kind, _reply, _body = bus._message()
check("the next signal's member replaces the old one", kind == 4 and bus.member == "NameOwnerChanged", bus.member)

bus = fake_bus([message(4, "TestInput"), message(4, "NameOwnerChanged"), message(2, reply_to=2), message(4, "UserActive")])
probe.Bus = lambda: bus
args = types.SimpleNamespace(seconds=1)
out = io.StringIO()
with contextlib.redirect_stdout(out):
    probe.cmd_listen(args)
lines = out.getvalue().split()
got = [" ".join(lines[i:i + 2]) for i in range(1, len(lines) - 1, 2)]
check("listen says ready first and done last", lines[:1] == ["ready"] and lines[-1:] == ["done"], lines)
check("listen sorts Input1's signals from the bus's own and drops a method reply",
      got == ["heard TestInput", "bus NameOwnerChanged", "heard UserActive"], got)
check("listen matches Input1's signals and NameOwnerChanged",
      len(bus.matches) == 2 and "sender='org.ruyaos.Input1'" in bus.matches[0] and "NameOwnerChanged" in bus.matches[1], bus.matches)

sys.exit(1 if fails else 0)
