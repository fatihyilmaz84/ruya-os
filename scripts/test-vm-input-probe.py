#!/usr/bin/env python3
"""Host test of scripts/vm-input-probe.py's signal listener (RUY-594) and of its players helpers (RUY-121:
JoinPlayer's (su) reply, a u argument, ListPlayers' busctl JSON) and its seathold helpers (RUY-627: a seat's
row, the removes in udevadm monitor's output): Bus reads a signal's member from the
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

# --- RUY-121: JoinPlayer's (su) reply, a u argument (LeavePlayer) and ListPlayers' busctl JSON -----------------

def reply_su(reply_to, status, slot):
    """A method return with the body (su), as JoinPlayer answers."""
    body = bytearray()
    e = status.encode()
    body.extend(struct.pack("<I", len(e)) + e + b"\0")
    pad(body, 4)
    body.extend(struct.pack("<I", slot))
    fields = bytearray()
    pad(fields, 8)
    fields.append(5)
    fields.extend(bytes([1]) + b"u\0")
    pad(fields, 4)
    fields.extend(struct.pack("<I", reply_to))
    pad(fields, 8)
    fields.append(8)
    fields.extend(bytes([1]) + b"g\0")
    fields.extend(bytes([2]) + b"su\0")
    head = b"l" + bytes([2, 0, 1]) + struct.pack("<II", len(body), 1) + struct.pack("<I", len(fields))
    out = bytearray(head) + fields
    pad(out, 8)
    return bytes(out) + bytes(body)


def real_bus(messages):
    """A probe.Bus with its own call(), past AUTH and Hello, reading `messages`; the peer socket is returned too."""
    a, b = socket.socketpair()
    for m in messages:
        b.sendall(m)
    bus = probe.Bus.__new__(probe.Bus)
    bus.sock, bus.buf, bus.serial, bus.name, bus.member = a, b"", 0, ":1.9", None
    return bus, b


check("status_and_slot reads (su)", probe.Bus.status_and_slot(reply_su(1, "ok", 2)[-12:]) == ("ok", 2),
      probe.Bus.status_and_slot(reply_su(1, "ok", 2)[-12:]))
check("status_and_slot of a short body is empty", probe.Bus.status_and_slot(b"") == ("", 0))
bus, peer = real_bus([reply_su(1, "ok", 2), reply_su(2, "full", 0)])
got = probe.join_player(bus, "usb-1234-5679-0123456789ab", "p2")
check("join_player gives JoinPlayer's status and slot", got == ("ok", 2), got)
got = probe.join_player(bus, "usb-1234-567a-0123456789ab", "p3")
check("... and a refusal with slot 0", got == ("full", 0), got)
sent = peer.recv(65536)
check("JoinPlayer is sent with the signature ss", b"\x08\x01g\x00\x02ss\x00" in sent, sent[:120])
bus, peer = real_bus([reply_su(1, "ok", 0)])
bus.call("org.ruyaos.Input1", "/org/ruyaos/Input1", "org.ruyaos.Input1", "LeavePlayer", [2])
sent = peer.recv(65536)
check("an int argument is sent as u (LeavePlayer)", b"\x08\x01g\x00\x01u\x00" in sent and sent.endswith(struct.pack("<I", 2)),
      sent[-24:])
listed = ('{"type":"aa{sv}","data":[[{"slot":{"type":"u","data":2},"profile":{"type":"s","data":"p7"},'
          '"device_id":{"type":"s","data":"usb-1234-5679-0123456789ab"},"held":{"type":"b","data":false},'
          '"held_secs":{"type":"u","data":0}},{"slot":{"type":"u","data":1},"profile":{"type":"s","data":"p1"},'
          '"device_id":{"type":"s","data":"usb-1234-5678-0123456789ab"},"held":{"type":"b","data":false},'
          '"held_secs":{"type":"u","data":0}}]]}')
rows = probe.rows_of(listed)
check("rows_of reads ListPlayers' busctl JSON", rows is not None and rows[0]["profile"] == "p7" and rows[0]["held"] is False, rows)
check("seats_of sorts the players by slot",
      probe.seats_of(rows) == [(1, "p1", "usb-1234-5678-0123456789ab"), (2, "p7", "usb-1234-5679-0123456789ab")],
      probe.seats_of(rows))
check("rows_of of something else is None", probe.rows_of("Call failed: no such method") is None
      and probe.rows_of('{"data": []}') is None)
# RUY-627 (seathold): the seat 2 row, and the udevadm monitor removes of pad2's input device.
check("player_row finds a seat and None for an empty one",
      probe.player_row(rows, 2)["profile"] == "p7" and probe.player_row(rows, 3) is None
      and probe.player_row(None, 1) is None)
monitor = """monitor will print the received events for:
KERNEL - the kernel uevent

KERNEL[812.120] add      /devices/virtual/input/input230 (input)
KERNEL[812.130] remove   /devices/virtual/input/input23/event17 (input)
UDEV  [812.140] remove   /devices/virtual/input/input23 (input)
KERNEL[812.150] remove   /devices/virtual/input/input230/event18 (input)
KERNEL[812.160] change   /devices/virtual/input/input23/event17 (input)
"""
removes = probe.udev_removes(monitor, "input23")
check("udev_removes finds KERNEL and UDEV removes of the device and its node",
      len(removes) == 2 and removes[0].startswith("KERNEL[812.130]") and removes[1].startswith("UDEV"), removes)
check("udev_removes ignores another device with a longer name and other actions",
      probe.udev_removes(monitor, "input2") == [] and probe.udev_removes("", "input23") == [],
      probe.udev_removes(monitor, "input2"))

# RUY-38 (owner, guide): the ForeignInput bodies read from `busctl monitor` text.
monitored = """Monitoring bus message stream.
‣ Type=signal  Endian=l  Flags=1  Version=1 Cookie=41  Timestamp="Sun 2026-11-15 10:00:00.000000 UTC"
  Sender=:1.3  Path=/org/ruyaos/Input1  Interface=org.ruyaos.Input1  Member=ForeignInput
  UniqueName=:1.3
  MESSAGE "ss" {
          STRING "usb-1234-5679-0123456789ab";
          STRING "press";
  };

‣ Type=signal  Endian=l  Flags=1  Version=1 Cookie=42
  Sender=:1.3  Path=/org/ruyaos/Input1  Interface=org.ruyaos.Input1  Member=ActiveInputChanged
  MESSAGE "ss" {
          STRING "usb-1234-5678-0123456789ab";
          STRING "xbox";
  };

‣ Type=signal  Endian=l  Flags=1  Version=1 Cookie=43
  Sender=:1.3  Path=/org/ruyaos/Input1  Interface=org.ruyaos.Input1  Member=ForeignInput
  MESSAGE "ss" {
          STRING "usb-1234-5679-0123456789ab";
          STRING "player-guide";
  };
"""
seen = []
probe.monitor_bodies(monitored.splitlines(True), "ForeignInput", seen)
check("monitor_bodies reads each ForeignInput's strings and skips other members",
      seen == [("usb-1234-5679-0123456789ab", "press"), ("usb-1234-5679-0123456789ab", "player-guide")], seen)

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
