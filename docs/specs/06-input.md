# 06 — Ruya Input (design)

**Status.** Design, from the spike T-366 / RUY-2 (lead, 2026-11-12). Built today: only `ruya-inputd`'s Phase 0 bridge (pads to navigation keys, ADR-003). Everything else here is the **target** that the tasks T-367..T-374 build, each marked *(planned, T-nnn)*. The owner's requirements are the appendix [`06-input-requirements.md`](06-input-requirements.md); where this file and an *Accepted* ADR differ, the ADR wins. Contract draft: [`api/dbus/org.ruyaos.Input1.xml`](../../api/dbus/org.ruyaos.Input1.xml); profile format: [`schemas/input-profile-v1.json`](schemas/input-profile-v1.json).

## 1. Evidence from the spike (Dell OptiPlex 7080, image 0.0.68, 2026-11-12)

All probes are in `scripts/dell-input-spike.py` (root on the console; it changes nothing that survives it).

| Question | Result |
|---|---|
| `ruya-inputd` cost | RSS 2.35 MB (VmHWM 2.35 MB) after 1 h 31 min with a Bluetooth DualSense; runs as root today, no capabilities. |
| Added latency | `dell-input-spike.py latency --runs 200`: write on a uinput source pad → read of the source node: median 86 µs, p90 121 µs; → read of the key `ruya-inputd` emits: median 180 µs, p90 247 µs, max 298 µs. **Added by the service: median 88 µs, p90 126 µs, max 212 µs**, no miss. |
| A virtual pad reaches a game | A uinput pad (`045e:028e`, Xbox 360 layout) with one ACL entry `u:ruya-p1:rw`: inside SuperTuxKart's sandbox (Flatpak 1.18.4, `devices=all`, runtime `org.freedesktop.Platform 26.08`) as `ruya-p1` the node opens (`EVIOCGNAME` "Ruya Spike Xbox 360 Pad"); every other `event*` node (physical DualSense, its motion and touchpad nodes, the navigation keyboard) is refused. SuperTuxKart (SDL 2.32.74) logs `SDLController: Xbox 360 Controller plugged in: buttons: 11, axes: 6, hats: 1` and `uses game controller mapping Xbox 360 Controller`; when the pad is destroyed it logs `Xbox 360 Controller unplugged`. |
| Another user | The same sandbox as `ruya-p2`: all 17 nodes refused, the pad included. |
| No `--device` | `net.ptilouk.superfluous` (`devices=dri` only): `/dev/input` does not exist in the sandbox. A game needs `--device=input` (Flatpak ≥ 1.15.6) or `all`. |
| udev in the sandbox | `/run/udev` is absent in the sandbox; SDL still found the pad (its container path enumerates `/dev/input` with inotify). The service must not depend on apps seeing udev properties. |
| The ACL survives udev? | **No, not by itself.** `70-ruya-input.rules` (and systemd's `70-uaccess.rules` for joysticks) tag every `event*` node `uaccess`; logind's `uaccess` builtin then **flushes** other ACL entries and writes the seat user's (`ruya-shell`). An ACL set before udev finished the `add` event was gone; one set after it held; a later `change` event (`udevadm trigger`) wiped it again even with `TAG-="uaccess"` in a later rule. |
| Non-root service | A system user with an ACL on `/dev/uinput` creates pads; a udev rule matching `ATTRS{phys}=="ruya-input/*"` makes it the node's owner (`crw-rw----+ ruya-input-spike input`), and as owner it sets the per-profile ACL itself; with an ACL on a physical pad it reads it and `EVIOCGRAB` works. An ACL added by a `RUN+=` rule coexists with logind's `ruya-shell` entry (RUN runs after the builtin). No root and no capability is needed. |
| Service death | `kill -9 ruya-inputd`, three times: the navigation node is back after 2213-2429 ms (systemd `Restart=always`, `RestartSec=2`) and the shell has it open 25-57 ms later. Navigation is lost for those ~2.3 s; a crash loop would end it (systemd's default start limit). |
| Found in passing | The shell holds the DualSense **touchpad** node open (libinput takes it as a pointer, `ID_INPUT_TOUCHPAD=1`): its motion reaches the focused surface, a game included. §5 fixes it. |

**InputPlumber, not measured here.** Building it from source on the host was refused by the session's permission check (third-party code); the facts below are from its repository (v0.84.0, 2026-11-05): GPL-3.0-or-later; Rust; the unit has no `User=` (root) and only `ProtectSystem=full`; the bus name may be owned by root only; virtual targets `xb360`, `xbox-elite`, `dualsense`, Steam Deck, keyboard, mouse, touchpad and more; an `InterceptMode` property for overlays; YAML device configs (about 100) with a generic-gamepad fallback; source nodes hidden by moving them to `/dev/inputplumber/sources`; **no per-user or per-session concept for its virtual devices** (they are daemon-global); packaged for Fedora only in a COPR.

## 2. Engine decision (ADR-003, ADR-024)

**`ruya-inputd` grows into the Ruya Input service; InputPlumber is not used** (ADR-003's named fallback). Reasons, in order:
1. **Least privilege.** The requirement is "not the whole engine as root" (§2.3 of the requirements; the hardening invariant in `CLAUDE.md`). The spike shows the whole service can run as an unprivileged system user with udev ACLs; InputPlumber runs as root with almost no hardening, and its design (moving device nodes) needs it.
2. **The profile boundary is ours anyway.** ADR-024's core rule, "a virtual node has one ACL entry, for the signed-in profile, re-made at every lock and switch", has no place in InputPlumber; we would write that layer next to it and keep a root daemon we do not control between the pads and the games.
3. **Packaging.** A COPR in a signed image is a third-party repository in the supply chain (01 §4); a source build is a new Rust stack in our image build, for one daemon.
4. **Cost of ours.** It already reads every pad, survives pads vanishing (T-337) and adds 88 µs median. What it lacks (virtual pads, routing, profiles) is the work T-367..T-374 plan either way.

What we take from InputPlumber: an intercept mode for overlays (our route `overlay`), a device database separate from user profiles, the generic-gamepad fallback, and its list of virtual targets as the long-term goal for §7 of the requirements. Revisit only if handheld-specific hardware (built-in pads exposed as keyboards, vendor HID buttons) becomes a target: InputPlumber's device configs are its real value there.

## 3. Process, privilege and device access *(planned, T-367)*

- **User.** `ruya-inputd` runs as the system user `ruya-input` (sysusers, no home, no login shell), not root. Unit hardening stays as today plus `User=ruya-input`, `DeviceAllow=char-input rw`, `DeviceAllow=/dev/uinput rw`, `DeviceAllow=char-hidraw rw` (T-373 only), `RestrictAddressFamilies=AF_UNIX AF_NETLINK` (the udev monitor).
- **udev rules** (one file, `70-ruya-input.rules`, replacing today's single line):
  1. `/dev/uinput`: `GROUP="ruya-input", MODE="0660"`. Only root and `ruya-input` can create input devices, so only they can claim the `ruya-input/` phys prefix below.
  2. **Physical pads** (`ENV{ID_INPUT_JOYSTICK}=="1"` and not ours): `RUN+="/usr/bin/setfacl -m u:ruya-input:rw $devnode"` (after logind's builtin, so both entries stay). The pad's **motion and touchpad nodes** (same HID parent, `ID_INPUT_ACCELEROMETER` / `ID_INPUT_TOUCHPAD` on a joystick's parent) get the same entry and **lose `uaccess`** (no ACL for the shell): the service reads them (T-373), libinput in the shell no longer does.
  3. **Virtual nodes** (`ATTRS{phys}=="ruya-input/*"`): `OWNER="ruya-input", MODE="0600"`, and the uaccess tag is not set for them (the generic `uaccess` line gets `ATTRS{phys}!="ruya-input/*"`). systemd's own `70-uaccess.rules` still tags joysticks, so the service **re-asserts its ACL after every udev event on its own node** (it watches the udev monitor for its phys prefix) and only then announces the device as ready. The spike showed both halves: an ACL set after the `add` event holds, a `change` event wipes it.
  4. **hidraw** of a known pad family (T-373: adaptive triggers, lightbar, gyro calibration): `ruya-input` only. Never a profile user, except in the `passthrough` and `steam` modes (§6) for the running app's user, and only for that run.
- **The shell keeps its own path**: the physical pad nodes keep logind's `ruya-shell` entry (uaccess), so the emergency reader (§8) can open them without the service.

## 4. Device model

### 4.1 Identity
- **Stable id**, `<bus>-<vid>-<pid>-<key>`, where `<key>` is a 12-hex-digit hash (SHA-256 of a machine salt kept in `/var/lib/ruya-input/salt` plus the identifying string): Bluetooth → the device address (`uniq`, measured on the Dell: the DualSense's MAC); USB with a serial (`ID_SERIAL_SHORT`) → the serial; USB without one → the USB port path (`ID_PATH`), so two identical serial-less pads are told apart by socket. Never `eventN`. The hash keeps MAC addresses and serials off the bus.
- **Instance id**: a counter per connection (`<stable id>#<n>`). Signals carry both; the shell keys rows by the stable id.
- **Like pads (ADR-017).** A serial-less USB pad plugged into another socket is a new stable id. The registry (T-264) matches it to a known one only when exactly one known pad of the same `vid:pid` is absent; otherwise the "Who's playing?" dialog asks. A pad that reconnects within 60 s gets its slot back (ADR-017).
- **Family** (`xbox`, `playstation`, `nintendo`, `generic`, ...): from the service's own device table by `vid:pid` (first entries: T-261's audit and RUY-154's 360 receiver), then the kernel driver, then `generic`. SDL's mapping database is a separate data file the service reads for unknown pads (requirements §4.2); it never decides capabilities.

### 4.2 Normalised input
Buttons: `south east west north l1 r1 l3 r3 start select guide dpad_up dpad_down dpad_left dpad_right` plus `paddle1..4`, `misc1` (share/capture) and `touchpad_click`. Axes: `left_x left_y right_x right_y` as i16 (-32768..32767, up negative) and `left_trigger right_trigger` as 0..32767. Motion: `gyro_{x,y,z}` in deg/s ×16, `accel_{x,y,z}` in mg; touchpad contacts as (id, x, y) in 0..65535 of the pad's surface. Every event keeps its **raw source** (`<node kind>:<evtype>:<code>`) so a profile can map an input that has no normal name. Buttons are named by **position**, not label: Nintendo's A is `east` (the family's confirm button, ADR-027, is a mapping on top: T-398).

### 4.3 Capability descriptor
Per device, per capability (`buttons`, `sticks`, `analog_triggers`, `dpad`, `gyro`, `accelerometer`, `touchpad`, `rumble`, `trigger_rumble`, `adaptive_triggers`, `lightbar`, `player_leds`, `speaker`, `microphone`, `battery`), four booleans:
- `hardware` — the model has it (device table);
- `driver` — the kernel exposes it here (a motion node exists, `EV_FF` with `FF_RUMBLE` on the node, a power-supply entry);
- `available` — usable now (the node opened, the battery reports, Bluetooth rumble acknowledged);
- `output` — the virtual device the pad is routed to can carry it (an Xbox 360 virtual pad: rumble yes, gyro no).
Only what is detected is reported (`rumble` never implies `adaptive_triggers`). `GetCapabilities` returns them as `a(sbbbb)`.

## 5. Routing *(planned, T-367; ownership modes T-371)*

### 5.1 States
| Route | Set when | Pads produce |
|---|---|---|
| `shell` | the shell (or the Hub, a page, the picker's pre-session state) is in front | navigation keys on "RuyaOS Navigation" (today's behaviour); the virtual pads are idle |
| `app` | an app has the focus | the app's profile's virtual pads only; navigation keys stop, except **Guide**, which always goes to the shell as `KEY_HOMEPAGE` and is never forwarded to the virtual pad |
| `overlay` | an overlay over a running app (Hub, Guide menu, a system dialog: ADR-033) | navigation keys; the virtual pads are held in neutral (sticks centred, nothing pressed) |
| `locked` | the picker or the PIN pad after Lock, or no profile signed in | navigation keys; **no virtual pad exists** |

Every transition releases on the side being left whatever is held (the `KeyBoard` count of T-337, extended to pad buttons and axes), then switches: no stuck button and no double input. The shell is the only source of the route: the compositor knows the focus first (`KeyRouter`), and the shell calls `Input1.SetRoute(route, instance, profile)` on every change, exactly as it reports presence to `Session1` today. The service trusts the shell's argument (the bus policy lets only `ruya-shell` and root call it, like `Session1.Launch`), refuses profiles that are not profile accounts, and **falls back to `locked` when the caller that set the route leaves the bus** (`NameOwnerChanged`), so a dead shell never leaves a game owning the pads.

### 5.2 Sign-in, switch, lock, run end, Quick Resume
- **Who tells whom.** The shell, through `SetRoute`: it already learns sign-in, switch and lock from `Profiles1` (`SwitchTo`, `Lock`, `ActiveProfile`) and freezing from `Session1`. No new call from `ruya-profiles` or `ruya-session` to the input service and no new bus-policy line on their interfaces; the one new policy is `org.ruyaos.Input1`'s own (owner `ruya-input`; `ruya-shell` and root may call; `ruya-link` nothing until ADR-029's allow-list names a method).
- **An already open descriptor is not closed by removing an ACL** (Linux checks access at `open`). So at **lock**, **profile switch**, **run end** and **Freeze** the service **destroys** the profile's virtual devices (`UI_DEV_DESTROY`: the app reads `ENODEV`, SDL reports "unplugged", seen on the Dell) and creates new ones for the next owner. Quick Resume: on `Thaw` the service creates fresh pads for the app's profile; SDL's hot-plug picks them up; nothing depends on node or instance ids staying the same (requirements §14).
- **Overlay over a frozen game**: no pad exists for the frozen app, so nothing can leak into it.

### 5.3 Ownership modes *(planned, T-371)*
`managed` (default; the routing above), `passthrough` (the running app's user gets an ACL on the physical event and hidraw nodes for that run; the service applies no mapping and creates no virtual pad, but keeps reading the pad without a grab for Guide and the shortcuts), `steam` (as passthrough; Steam Input does the rest; we never edit Steam's files), `semantic` (native Ruya apps receive actions through `Platform1`, T-374). The mode is a per-app setting stored by the service; switching mode takes effect at the next launch.

### 5.4 Grabs
The service never grabs a pad in `managed`: apps cannot open physical nodes (no ACL), so there is nothing to hide. It grabs (`EVIOCGRAB`, proven non-root) only where another reader would otherwise double the input, today none.

## 6. Bluetooth pairing as an attack surface *(planned, T-203 follow-up, T-397)*
- Only bonded devices connect: BlueZ `ClassicBondedOnly=true` (the BlueZ default; the image must not change it; a VM check asserts it), and HID goes through the kernel (`UserspaceHID=false`, T-375).
- Pairing is possible only while the shell's pairing screen is open (the pairable timeout, T-299), and the screen shows the new device's name and **class**; a device that announces itself as a keyboard needs a second confirmation ("This is a keyboard. Pair it?"), because a keyboard can type anywhere the shell can.
- **What a new pad may do before a profile owns it** (ADR-017, ADR-027): navigate the profile picker and the "Who's playing?" dialog; inside a session it drives nothing until it is assigned (T-397 decides takeover rules). It never reaches a game as anything but a player slot of the signed-in profile.

## 7. Profiles *(planned, T-369 global, T-370 game and platform)*
- **Format**: JSON, `schema_version: 1`, described by [`schemas/input-profile-v1.json`](schemas/input-profile-v1.json); the service validates every profile on load, save and import, refuses unknown fields and reports errors as `path: message` lines. The requirements' example (§9.3) is valid. No scripts: macros are data.
- **Precedence**: game → platform → global → the built-in default; a profile names its parent in `inherits` and lists only what differs. Resolution walks at most 8 levels and refuses cycles. Per controller: a profile may be limited to a family (`match.family`) or one stable id (`match.device`).
- **Limits**: 256 mappings, 8 layers, 32 macro steps, 10 s total macro duration, delays ≥ 10 ms, turbo ≤ 30 Hz, a chord of at most 4 inputs, names ≤ 64 characters, 64 KiB per file. Imported profiles are untrusted data (requirements §15): validated, never executed.
- **Storage**: per console profile, by the service, under `/var/lib/ruya-input/profiles/<profile id>/` (the unit's `StateDirectory`, owned by `ruya-input`, 0700; profile users cannot read it); export and import go through the shell's file picker as JSON text over `Input1`.

## 8. When the service fails *(planned, T-367 restart; emergency reader: its own task)*
Chosen path: **both**, because each covers what the other cannot.
1. **Fast restart**: `RestartSec=100ms`, `StartLimitIntervalSec=0` (never give up), `WatchdogSec=5s` with `sd_notify` from the event loop. Target: navigation back within 0.5 s of a crash (today 2.2-2.4 s, §1).
2. **The compositor's emergency reader**: when `org.ruyaos.Input1` has had no owner for 3 s (a crash loop, a failed start, a broken image), the compositor opens the physical pads itself (it keeps logind's ACL on them, §3) and maps D-pad, left stick, south, east, start and guide to the same keys as `ruya-inputd`'s Phase 0 table, until the name has an owner again. It never feeds a game. A journal line names both transitions.
The spike proved the restart path (§1); the emergency reader is not built yet, and its acceptance test is the Dell drill: mask the service, the shell still navigates.

## 9. Performance and instrumentation
The input path stays event-driven (one thread per source node, no polling). The service counts, per device, events in and out and the time from the kernel timestamp of the source event to the write of the output event (`CLOCK_MONOTONIC` on both sides), and logs `ruya-inputd: latency <device> n=<n> p50=<us> p99=<us> max=<us>` every 60 s while `RUYA_INPUT_TRACE=1`. Budget: added latency p99 ≤ 1 ms (measured today: p90 126 µs).

## 10. The contract
`org.ruyaos.Input1` (draft, [`api/dbus/org.ruyaos.Input1.xml`](../../api/dbus/org.ruyaos.Input1.xml)): devices and capabilities (T-367/T-368), the live button test (T-368), routing (T-367), profiles and assignments (T-369/T-370), ownership modes (T-371). Internal (shell and root): apps reach input only as evdev virtual devices (the public raw surface, `docs/developers/controller-input.md`) and, later, semantic actions through `Platform1` (T-374, ADR-022).

## 11. Task map
| Task | What, after this design |
|---|---|
| T-367 / RUY-3 | `ruya-input` user and udev rules (§3), one Xbox 360-style virtual pad per physical pad for the signed-in profile, the ACL re-assert, routing states and `SetRoute` (§5.1-5.2), restart settings (§8.1), `Input1` devices and routing part, mock and client, a VM check and the Dell SuperTuxKart check |
| new (lead files) | the compositor's emergency reader (§8.2) |
| T-368 / RUY-39 | device list, capabilities (§4.3), the live button test; Settings > Controllers |
| T-369 / RUY-42 | profiles v1: schema, validation, global profile, import/export, dead zones and curves |
| T-370 / RUY-43 | game and platform profiles, resolution chain, the game page's Controller entry |
| T-371 / RUY-44 | ownership modes (§5.3) |
| T-372 / RUY-45 | keyboard and mouse output, layers, chords, shortcuts |
| T-373 / RUY-46 | motion, touchpad (the nodes leave the shell, §3), rumble back to the pad, hidraw |
| T-374 / RUY-47 | semantic actions and glyphs through `Platform1` |
