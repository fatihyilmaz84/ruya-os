#!/usr/bin/env python3
"""Host fixtures for the input udev rules (06-input.md section 3, RUY-1063): 70-ruya-input.rules,
71-ruya-input-pad.rules and 74-ruya-input-acl.rules, run in file order with stand-ins for systemd's
70-power-switch.rules and 70-uaccess.rules, by a small evaluator of the udev syntax these files use
(match and parent-match keys, TEST with $id, ENV, TAG+= and TAG-=, OWNER, MODE, RUN, GOTO/LABEL).
Each fixture is one event on a device chain with the marker files that exist; the outcome (origin,
owner, mode, tags, LIBINPUT_IGNORE_DEVICE, the RUN programs) is compared with what the spec says.
Prints PASS:/FAIL: lines and exits 1 on a failure. Run by test-vm-checks.sh.
"""
import fnmatch
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RULES = os.path.join(HERE, "..", "image", "rootfs", "usr", "lib", "udev", "rules.d")
# systemd's own rules these files sort around (the lines that matter here, as Fedora ships them).
POWER_SWITCH = 'SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEY}=="1", TAG+="power-switch"'
UACCESS = 'SUBSYSTEM=="input", ENV{ID_INPUT_JOYSTICK}=="?*", TAG+="uaccess"'
PARENT_KEYS = {"SUBSYSTEMS", "KERNELS", "DRIVERS"}

fails = 0


def ok(msg):
    print(f"PASS: {msg}")


def bad(msg):
    global fails
    fails += 1
    print(f"FAIL: {msg}")


TOKEN = re.compile(r'\s*([A-Z_]+(?:\{[^}]*\})?)\s*(==|!=|\+=|-=|=)\s*"((?:[^"\\]|\\.)*)"\s*(?:,|$)')


def parse(text):
    """The rule lines of a file as lists of (key, op, value)."""
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tokens, pos = [], 0
        while pos < len(line):
            m = TOKEN.match(line, pos)
            if not m:
                raise ValueError(f"cannot parse {line!r} at {pos}")
            tokens.append((m.group(1), m.group(2), m.group(3)))
            pos = m.end()
        lines.append(tokens)
    return lines


def glob_match(value, pattern):
    return any(fnmatch.fnmatchcase(value, p) for p in pattern.split("|"))


class Event:
    def __init__(self, action, chain, env, files=()):
        self.action, self.chain, self.env, self.files = action, chain, dict(env), set(files)
        self.tags, self.owner, self.mode, self.run = set(), "root", None, []

    def run_file(self, lines):
        label = None
        for tokens in lines:
            if label is not None:
                if ("LABEL", "=", label) in tokens:
                    label = None
                continue
            if any(k == "LABEL" for k, _, _ in tokens):
                continue
            goto = self.apply(tokens)
            if goto:
                label = goto

    def apply(self, tokens):
        """Matches one line and applies it; its GOTO label when it matched."""
        dev = self.chain[0]
        subst = {}
        parent = [t for t in tokens if t[0] in PARENT_KEYS or t[0].startswith("ATTRS{")]
        for key, op, val in tokens:
            if op not in ("==", "!="):
                continue
            if key in PARENT_KEYS or key.startswith("ATTRS{") or key == "TEST":
                continue
            have = {"ACTION": self.action, "SUBSYSTEM": dev["subsystem"], "KERNEL": dev["kernel"],
                    "DEVPATH": dev["devpath"]}.get(key)
            if key.startswith("ENV{"):
                have = self.env.get(key[4:-1], "")
            if key == "TAG":
                have = None
                hit = val in self.tags
            else:
                hit = glob_match(have or "", val)
            if hit != (op == "=="):
                return None
        if parent:
            for node in self.chain:
                def one(key, val):
                    if key == "SUBSYSTEMS":
                        return glob_match(node["subsystem"], val)
                    if key == "KERNELS":
                        return glob_match(node["kernel"], val)
                    if key == "DRIVERS":
                        return glob_match(node.get("driver", ""), val)
                    return glob_match(node.get("attrs", {}).get(key[6:-1], ""), val)
                if all(one(k, v) for k, op, v in parent if op == "=="):
                    subst["id"] = node["kernel"]
                    break
            else:
                return None
        for key, op, val in tokens:
            if key == "TEST":
                path = val.replace("$id", subst.get("id", ""))
                if (path in self.files) != (op == "=="):
                    return None
        goto = None
        for key, op, val in tokens:
            if key.startswith("ENV{") and op == "=":
                self.env[key[4:-1]] = val
            elif key == "TAG" and op == "+=":
                self.tags.add(val)
            elif key == "TAG" and op == "-=":
                self.tags.discard(val)
            elif key == "OWNER":
                self.owner = val
            elif key == "MODE":
                self.mode = val
            elif key.startswith("RUN"):
                self.run.append(val)
            elif key == "GOTO":
                goto = val
        return goto


def evaluate(action, chain, env, files=()):
    order = ["70-ruya-input.rules", POWER_SWITCH, UACCESS, "71-ruya-input-pad.rules", "74-ruya-input-acl.rules"]
    ev = Event(action, chain, env, files)
    for f in order:
        text = f if f.endswith('"') else open(os.path.join(RULES, f), encoding="utf-8").read()
        ev.run_file(parse(text))
    return ev


def chain_virtual(n, ev, phys=""):
    return [
        {"subsystem": "input", "kernel": f"event{ev}", "devpath": f"/devices/virtual/input/input{n}/event{ev}"},
        {"subsystem": "input", "kernel": f"input{n}", "devpath": f"/devices/virtual/input/input{n}",
         "attrs": {"phys": phys}},
    ]


def chain_usb(n, ev, driver="xpad"):
    return [
        {"subsystem": "input", "kernel": f"event{ev}", "devpath": f"/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input{n}/event{ev}"},
        {"subsystem": "input", "kernel": f"input{n}", "devpath": f"/devices/pci0000:00/usb1/1-2/1-2:1.0/input/input{n}",
         "attrs": {"phys": "usb-0000:00:14.0-2/input0"}},
        {"subsystem": "usb", "kernel": "1-2:1.0", "devpath": "/devices/pci0000:00/usb1/1-2/1-2:1.0", "driver": driver},
    ]


OWN = "/run/ruya-input/own/"
TRUSTED = "/run/ruya-input-trusted/"
PAD = {"ID_INPUT": "1", "ID_INPUT_JOYSTICK": "1"}
KBD = {"ID_INPUT": "1", "ID_INPUT_KEY": "1", "ID_INPUT_KEYBOARD": "1"}
SETFACL = "/usr/bin/setfacl -m u:ruya-input:rw $devnode"


def expect(name, ev, origin, owner, mode, tags_in=(), tags_out=(), libinput_ignore=False, run=None):
    problems = []
    if ev.env.get("RUYA_INPUT_ORIGIN", "") != origin:
        problems.append(f"origin {ev.env.get('RUYA_INPUT_ORIGIN', '')!r}, not {origin!r}")
    if ev.owner != owner:
        problems.append(f"owner {ev.owner}, not {owner}")
    if ev.mode != mode:
        problems.append(f"mode {ev.mode}, not {mode}")
    for t in tags_in:
        if t not in ev.tags:
            problems.append(f"no {t} tag")
    for t in tags_out:
        if t in ev.tags:
            problems.append(f"a {t} tag")
    if (ev.env.get("LIBINPUT_IGNORE_DEVICE") == "1") != libinput_ignore:
        problems.append(f"LIBINPUT_IGNORE_DEVICE {ev.env.get('LIBINPUT_IGNORE_DEVICE')!r}")
    if run is not None and ev.run != run:
        problems.append(f"RUN {ev.run}, not {run}")
    ok(name) if not problems else bad(f"{name}: {'; '.join(problems)}")


def main():
    # 1. /dev/uinput: ruya-input's, 0600, no group (ruya-inputd gives the signed-in profile's user its one entry).
    misc = [{"subsystem": "misc", "kernel": "uinput", "devpath": "/devices/virtual/misc/uinput"}]
    ev = evaluate("add", misc, {})
    expect("/dev/uinput is ruya-input's, mode 0600", ev, "", "ruya-input", "0600")
    text = open(os.path.join(RULES, "70-ruya-input.rules"), encoding="utf-8").read()
    uinput = [l for l in parse(text) if ("KERNEL", "==", "uinput") in l]
    ok("the uinput line sets no GROUP") if uinput and not any(k == "GROUP" for k, _, _ in uinput[0]) else bad(
        f"the uinput line: {uinput}")

    # 2. ruya-inputd's own devices (marked): the navigation keyboard keeps uaccess, a virtual pad does not.
    ev = evaluate("add", chain_virtual(12, 3), KBD, {OWN + "input12"})
    expect("the marked navigation keyboard is own and keeps uaccess", ev, "own", "root", None,
           tags_in=("uaccess",))
    ev = evaluate("add", chain_virtual(29, 14, "ruya-input/pad1"), PAD, {OWN + "input29"})
    expect("a marked virtual pad is own: ruya-input's, 0600, no uaccess, no ruya-input setfacl", ev, "own",
           "ruya-input", "0600", tags_out=("uaccess",), run=[])

    # 3. Foreign: parentless and unmarked, whatever its phys.
    for phys, what in (("ruya-input/pad1", "a profile's pad with phys ruya-input/pad1"),
                       ("", "Steam's virtual pad"), ("ruya-input/kbm1", "a profile's keyboard with phys ruya-input/kbm1")):
        env = KBD if "kbm" in phys else PAD
        ev = evaluate("add", chain_virtual(40, 30, phys), env, {OWN + "input12"})
        expect(f"{what} is foreign: ruya-input's, 0600, no uaccess or power-switch, LIBINPUT_IGNORE_DEVICE, no setfacl",
               ev, "foreign", "ruya-input", "0600", tags_out=("uaccess", "power-switch"), libinput_ignore=True, run=[])
    # Another device's marker does not count; a stale marker of another number neither.
    ev = evaluate("add", chain_virtual(41, 31), KBD, {OWN + "input4", TRUSTED + "input4"})
    expect("a device whose number no marker names is foreign", ev, "foreign", "ruya-input", "0600",
           tags_out=("uaccess", "power-switch"), libinput_ignore=True)

    # 4. Foreign at add, own at the next event once the marker is there (an own device is briefly foreign).
    ev = evaluate("add", chain_virtual(42, 32), KBD, set())
    expect("before its marker: foreign at add", ev, "foreign", "ruya-input", "0600", tags_out=("uaccess",),
           libinput_ignore=True)
    ev = evaluate("change", chain_virtual(42, 32), KBD, {OWN + "input42"})
    expect("after its marker: own at the change", ev, "own", "root", None, tags_in=("uaccess",))

    # 5. Root's vouched-for stand-ins are hardware: uaccess, and a pad gets ruya-input's ACL.
    ev = evaluate("add", chain_virtual(43, 33, "vm-check/pad0"), PAD, {TRUSTED + "input43"})
    expect("a pad root vouched for is hardware: uaccess and ruya-input's setfacl", ev, "trusted", "root", None,
           tags_in=("uaccess",), run=[SETFACL])
    ev = evaluate("add", chain_virtual(44, 34), KBD, {TRUSTED + "input44"})
    expect("a keyboard root vouched for keeps uaccess and power-switch", ev, "trusted", "root", None,
           tags_in=("uaccess", "power-switch"))

    # 6. Hardware is unchanged: a USB pad and keyboard.
    ev = evaluate("add", chain_usb(5, 4), PAD)
    expect("a USB pad: uaccess and ruya-input's setfacl, no origin", ev, "", "root", None, tags_in=("uaccess",),
           run=[SETFACL])
    ev = evaluate("add", chain_usb(6, 5, "usbhid"), KBD)
    expect("a USB keyboard: uaccess and power-switch", ev, "", "root", None, tags_in=("uaccess", "power-switch"))
    # A uhid device (a Bluetooth LE pad through BlueZ) has a parent: hardware.
    uhid = [
        {"subsystem": "input", "kernel": "event20", "devpath": "/devices/virtual/misc/uhid/0005:045E:0B13.0001/input/input30/event20"},
        {"subsystem": "input", "kernel": "input30", "devpath": "/devices/virtual/misc/uhid/0005:045E:0B13.0001/input/input30",
         "attrs": {"phys": "aa:bb:cc:dd:ee:ff"}},
        {"subsystem": "hid", "kernel": "0005:045E:0B13.0001", "devpath": "/devices/virtual/misc/uhid/0005:045E:0B13.0001",
         "driver": "microsoft"},
    ]
    ev = evaluate("add", uhid, PAD)
    expect("a uhid pad (BLE through BlueZ) is hardware", ev, "", "root", None, tags_in=("uaccess",), run=[SETFACL])

    # 7. No rule trusts a ruya-input/ phys outside the marked branch.
    for f in ("70-ruya-input.rules", "71-ruya-input-pad.rules", "74-ruya-input-acl.rules"):
        lines = parse(open(os.path.join(RULES, f), encoding="utf-8").read())
        loose = [l for l in lines if any(k == "ATTRS{phys}" and "ruya-input" in v for k, _, v in l)
                 and not any(k == "ENV{RUYA_INPUT_ORIGIN}" and op == "==" and v == "own" for k, op, v in l)]
        if f == "70-ruya-input.rules":
            # In 70 the phys line sits under LABEL ruya_input_own: the evaluator proved it above; check its place.
            text = open(os.path.join(RULES, f), encoding="utf-8").read()
            own_at = text.find('LABEL="ruya_input_own"')
            phys_at = text.find('ATTRS{phys}=="ruya-input/pad*"')
            ok(f"{f}: the phys rule is inside the marked branch") if 0 <= own_at < phys_at else bad(
                f"{f}: the phys rule is outside LABEL ruya_input_own")
        else:
            ok(f"{f}: no phys trust outside ENV{{RUYA_INPUT_ORIGIN}}==own") if not loose else bad(f"{f}: {loose}")

    print("ALL PASSED" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
