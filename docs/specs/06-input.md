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
  3. **Virtual nodes** (`ATTRS{phys}=="ruya-input/*"`): `OWNER="ruya-input", MODE="0600"`, and the uaccess tag is not set for them (the generic `uaccess` line gets `ATTRS{phys}!="ruya-input/*"`). systemd's own `70-uaccess.rules` still tags joysticks, so the service **re-asserts its ACL after every udev event on its own node** (it watches the udev monitor for its phys prefix) and only then announces the device as ready. The spike showed both halves: an ACL set after the `add` event holds, a `change` event wipes it. This rule is for **virtual pads** (`ruya-input/pad*`). **Virtual keyboards and mice** (`ruya-input/kbm*`, T-372) are different: a Wayland game (and Xwayland or Wine through it) never reads keyboard or pointer nodes; it gets keys and motion from the compositor's seat. So those nodes keep `uaccess` (the shell's libinput reads them) and never get a profile ACL. The service emits on them only while the route is `app`, and the compositor delivers them to the focused app through `KeyRouter` like a real keyboard, Guide keys included.
  4. **hidraw** of a known pad family (T-373: adaptive triggers, lightbar, gyro calibration): `ruya-input` only. Never a profile user, except in `steam` mode (§5.3) for the running app's user, and only for that run.
- **The shell keeps its own path**: the physical pad nodes keep logind's `ruya-shell` entry (uaccess), so the emergency reader (§8) can open them without the service.

## 4. Device model

### 4.1 Identity
- **Stable id**, `<bus>-<vid>-<pid>-<key>`, where `<key>` is a 12-hex-digit hash (SHA-256 of a machine salt kept in `/var/lib/ruya-input/salt` plus the identifying string): Bluetooth → the device address (`uniq`, measured on the Dell: the DualSense's MAC); USB with a serial (`ID_SERIAL_SHORT`) → the serial; USB without one → the USB port path (`ID_PATH`), so two identical serial-less pads are told apart by socket. Never `eventN`. The hash keeps MAC addresses and serials off the bus.
- **Instance id**: a counter per connection (`<stable id>#<n>`). Signals carry both; the shell keys rows by the stable id.
- **Like pads (ADR-017).** A serial-less USB pad plugged into another socket is a new stable id. The registry (T-264) matches it to a known one only when exactly one known pad of the same `vid:pid` is absent; otherwise the "Who's playing?" dialog asks. A pad that reconnects within 60 s gets its slot back (ADR-017).
- **Family** (`xbox`, `playstation`, `nintendo`, `generic`, ...): from the service's own device table by `vid:pid` (first entries: T-261's audit and RUY-154's 360 receiver), then the kernel driver, then `generic`. SDL's mapping database is a separate data file the service reads for unknown pads (requirements §4.2); it never decides capabilities.

### 4.2 Normalised input
Buttons: `south east west north l1 r1 l3 r3 start select guide dpad_up dpad_down dpad_left dpad_right` plus `paddle1..4`, `misc1` (share/capture) and `touchpad_click`. Axes: `left_x left_y right_x right_y` as i16 (-32768..32767, up negative) and `left_trigger right_trigger` as 0..32767. Motion: `gyro_{x,y,z}` in deg/s ×16, `accel_{x,y,z}` in mg; touchpad contacts as (id, x, y) in 0..65535 of the pad's surface; `touchpad` names the surface as a whole (for touchpad-as-mouse). Every event keeps its **raw source** (`<node kind>:<evtype>:<code>`) so a profile can map an input that has no normal name. Buttons are named by **position**, not label: Nintendo's A is `east` (the family's confirm button, ADR-027, is a mapping on top: T-398).

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

Every transition releases on the side being left whatever is held (the `KeyBoard` count of T-337, extended to pad buttons and axes), then switches: no stuck button and no double input. The shell is the only source of the route: the compositor knows the focus first (`KeyRouter`), and the shell calls `Input1.SetRoute(route, instance, app_id, profile)` on every change (`app_id`: the Flatpak id of the app in front; RUY-3 adds it to the draft XML), exactly as it reports presence to `Session1` today. The service trusts the shell's argument (the bus policy lets only `ruya-shell` and root call it, like `Session1.Launch`), refuses profiles that are not profile accounts, and **falls back to `locked` when the caller that set the route leaves the bus** (`NameOwnerChanged`), so a dead shell never leaves a game owning the pads.

### 5.2 Sign-in, switch, lock, run end, Quick Resume
- **Who tells whom.** The shell, through `SetRoute`: it already learns sign-in, switch and lock from `Profiles1` (`SwitchTo`, `Lock`, `ActiveProfile`) and freezing from `Session1`. No new call from `ruya-profiles` or `ruya-session` to the input service and no new bus-policy line on their interfaces; the one new policy is `org.ruyaos.Input1`'s own (owner `ruya-input`; `ruya-shell` and root may call; `ruya-link` nothing until ADR-029's allow-list names a method).
- **An already open descriptor is not closed by removing an ACL** (Linux checks access at `open`). So at **lock**, **profile switch**, **run end** and **Freeze** the service **destroys** the profile's virtual devices (`UI_DEV_DESTROY`: the app reads `ENODEV`, SDL reports "unplugged", seen on the Dell) and creates new ones for the next owner. Quick Resume: on `Thaw` the service creates fresh pads for the app's profile; SDL's hot-plug picks them up; nothing depends on node or instance ids staying the same (requirements §14).
- **Overlay over a frozen game**: no pad exists for the frozen app, so nothing can leak into it.

### 5.3 Ownership modes *(planned, T-371)*
`managed` (default; the routing above), `passthrough` (the running app's user gets an ACL on the physical event nodes for that run; the service applies no mapping and creates no virtual pad, keeps reading the pad for Guide and the shortcuts, and grabs it outside the route `app`, below), `steam` (as passthrough, plus the pad's hidraw nodes; Steam Input does the rest; we never edit Steam's files), `semantic` (native Ruya apps receive actions through `Platform1`, T-374). The mode is a per-app setting stored by the service; switching mode takes effect at the next launch.

**Leaks in `passthrough` and `steam` (RUY-2 review).** The app then holds descriptors on physical nodes that can be neither destroyed nor revoked (§5.2). Rules, built and tested by T-371:
- **evdev:** in every route but `app` (overlay, Hub, PIN pad, picker, a frozen app), the service holds `EVIOCGRAB` on those pads' event nodes, so the app's descriptors receive nothing, also not as a backlog after a Thaw; it releases the grab when the route returns to `app` for that app. The service reads the grabbed node itself, so navigation keeps working.
- **hidraw** cannot be grabbed: a reader keeps receiving reports (and a frozen reader finds them buffered after Thaw). So hidraw is granted in `steam` mode only, never in `passthrough`, and while an app holds a pad's hidraw that pad **enters no PIN**: the PIN pad takes digits from the keyboard and from other pads, and shows "Close <app> to use this controller here" for that pad. Acceptance test (T-371): no report from a grabbed node reaches the app's descriptor during an overlay or after a Thaw, and the PIN pad refuses a hidraw-held pad.
- Steam Input creates its own uinput pads: `steam` mode needs `/dev/uinput` for the profile user for that run, which breaks §3.1's "only root and `ruya-input` create input devices". T-371 decides how (check the creating process of a `ruya-input/` node, not only its phys prefix, or keep Steam's pads outside the prefix); the same question applies to T-412 (phone) and T-418 (development pad).

### 5.4 Grabs
In `managed` the service never grabs a pad: apps cannot open physical nodes (no ACL), so there is nothing to hide. It grabs (`EVIOCGRAB`, proven non-root) only in the cases of §5.3.

## 6. Bluetooth pairing as an attack surface *(built, RUY-411; T-397 open)*
- Only bonded devices connect: BlueZ `ClassicBondedOnly=true` (the BlueZ default; the image must not change it), and HID goes through the kernel (`UserspaceHID=false`, T-375). `scripts/vm-devices-check.sh bluetooth` asserts both from the image's config files: no `ClassicBondedOnly=false` in `/etc/bluetooth/*.conf`, `UserspaceHID=false` in `input.conf` (RUY-411).
- Pairing is possible only while the shell's pairing screen is open (the pairable timeout, T-299), and the screen shows the new device's name and **class**; a device that announces itself as a keyboard needs a second confirmation ("This is a keyboard. Pair it?", with its name; Cancel has focus, Back cancels), because a keyboard can type anywhere the shell can. The service tells it in `Devices1.Bluetooth.ListDevices` as `keyboard` (Class of Device major Peripheral with the keyboard bit, which a keyboard/pointer combo has too; a LE device without a class by its HID keyboard appearance; BlueZ's `Icon` `input-keyboard`). Pads, headsets and mice pair as before. **The controller pairing window never pairs a keyboard** (RUY-411: the agent and the sweep treat a keyboard-class device as a stranger, refuse it and remove it if it bonded); a keyboard pairs only from Settings > Bluetooth, also when it is paired again after Forget. If the device leaves the list while the confirmation is open, the confirmation closes. The class is told by the remote device, so this is a speed bump for the user, not a defence against a spoofing device. The guided controller screen lists controllers only and is unchanged; the confirmation is on Settings > Bluetooth's device rows.
- **What a new pad may do before a profile owns it** (ADR-017, ADR-027): navigate the profile picker and the "Who's playing?" dialog; inside a session it drives nothing until it is assigned (T-397 decides takeover rules). It never reaches a game as anything but a player slot of the signed-in profile. **Until T-264 and T-397** every connected pad counts as the signed-in profile's (today's behaviour), and RUY-3 gives each one a virtual pad for that profile; the ownership rules of §11.3 narrow that.

## 7. Profiles *(planned, T-369 global, T-370 game and platform)*
- **Format**: JSON, `schema_version: 1`, described by [`schemas/input-profile-v1.json`](schemas/input-profile-v1.json); the service validates every profile on load, save and import, refuses unknown fields and reports errors as `path: message` lines. The requirements' example (§9.3) is valid. No scripts: macros are data.
- **Precedence**: game → platform → global → the built-in default; a profile names its parent in `inherits` and lists only what differs. Resolution walks at most 8 levels and refuses cycles. Per controller: a profile may be limited to a family (`match.family`) or one stable id (`match.device`).
- **Limits**: 256 mappings per list (the top level and each layer), 8 layers, 32 macro steps, a macro step never targets a macro (no recursion; a service rule), `press`/`release`/`tap` steps need a `target` and `wait` a `ms` (service rules), 10 s total macro duration, delays ≥ 10 ms, turbo ≤ 30 Hz, a chord of at most 4 inputs, names ≤ 64 characters, 64 KiB per file. Imported profiles are untrusted data (requirements §15): validated, never executed.
- **What a profile changes**: only what the **virtual devices** emit in the route `app` (the game's view). The shell's navigation is never remapped by a profile: it follows the family and the Confirm row (§11.2). A "Nintendo layout" is a built-in preset profile (south ↔ east, west ↔ north) for games, not a navigation setting.
- **Stick maths** (per stick, on the vector, so the dead zone is round, not square): magnitude `r` in 0..1. Then `r' = clamp((r − inner) / (1 − inner − outer), 0, 1)`. Then the curve `c`: Linear `r'`, Precise `r'²`, Aggressive `√r'`. Then `out = 0` if `r' = 0`, else `anti + (1 − anti) · c`, times `sensitivity`, clamped to 1. The direction is kept, and inversion applies per axis afterwards. Triggers use `trigger_threshold` as their inner dead zone. Smoothing is off unless set (an exponential moving average with the factor `smoothing`). The defaults are inner 0.08, outer 0.02, anti 0, sensitivity 1, Linear.
- **Deleting a parent**: its children are re-parented to its own parent and keep their overrides. A built-in profile cannot be deleted (`not-allowed`).
- **Game and platform keys**: `game_id` is the Library's stable game id (ADR-028; for a Flatpak game today its app id); `platform_id` is the launcher's app id (Heroic, RPCS3, Steam). The service learns the app in front from `SetRoute`'s `app_id`.
- **Storage**: per console profile, by the service, under `/var/lib/ruya-input/profiles/<profile id>/` (the unit's `StateDirectory`, owned by `ruya-input`, 0700; profile users cannot read it).
- **Export and import** are JSON text over `Input1` (`GetProfile`; `ValidateProfile` then `SaveProfile`). The shell writes the file to, and reads it from, a removable drive through the existing removable-volume path of `Devices1.Storage` (as `SaveReport` does: no symlinks followed, never as root into a user-controlled directory, a size cap of 64 KiB before parsing). The input service never touches removable media.

## 8. When the service fails *(planned, T-367 restart; emergency reader: its own task)*
Chosen path: **both**, because each covers what the other cannot.
1. **Fast restart**: `RestartSec=100ms`, `StartLimitIntervalSec=0` (never give up), `WatchdogSec=5s` with `sd_notify` from the event loop. Target: navigation back within 0.5 s of a crash (today 2.2-2.4 s, §1).
2. **The compositor's emergency reader**: when `org.ruyaos.Input1` has had no owner for 3 s (a crash loop, a failed start, a broken image), the compositor opens the physical pads itself (it keeps logind's ACL on them, §3) and maps D-pad, left stick, south, east, start and guide to the same keys as `ruya-inputd`'s Phase 0 table, until the name has an owner again. It never feeds a game. A journal line names both transitions.
The spike proved the restart path (§1); the emergency reader is not built yet, and its acceptance test is the Dell drill: mask the service, the shell still navigates.

## 9. Performance and instrumentation
The input path stays event-driven (one thread per source node, no polling). The service counts, per device, events in and out and the time from the kernel timestamp of the source event to the write of the output event (`CLOCK_MONOTONIC` on both sides), and logs `ruya-inputd: latency <device> n=<n> p50=<us> p99=<us> max=<us>` every 60 s while `RUYA_INPUT_TRACE=1`. Budget: added latency p99 ≤ 1 ms (measured today: p90 126 µs).

## 10. The contract
`org.ruyaos.Input1` (draft, [`api/dbus/org.ruyaos.Input1.xml`](../../api/dbus/org.ruyaos.Input1.xml)): devices and capabilities (T-367/T-368), the live button test (T-368), routing (T-367), UI ownership and the active input (T-397..T-399, §11), profiles and assignments (T-369/T-370), ownership modes (T-371). Internal (shell and root): apps reach input only as evdev virtual devices (the public raw surface, `docs/developers/controller-input.md`) and, later, semantic actions through `Platform1` (T-374, ADR-022).

## 11. UI ownership, the family's buttons and glyphs (ADR-027; T-396 / RUY-5) *(planned, T-397..T-399)*

### 11.1 Actions (one vocabulary)
The shell, the hint bar, `Platform1` (T-374) and the development tools (T-418) name buttons by **action**, never by letter: `up down left right` (the D-pad or the left stick), `accept`, `back`, `options` (context menu), `view`, `guide`, `tabPrev` / `tabNext` (shoulders), `pagePrev` / `pageNext` (triggers: fast scroll), `done` (finish a text entry), `dpad` (any direction, for hints). The service turns pad events into these actions; today they reach the shell as the Phase 0 keys (`accept` = Enter, `back` = Esc, `options` = Menu, `guide` = HomePage, `tabPrev/Next` = PgUp/PgDn), which stay the keyboard's keys too.

### 11.2 The family's own confirm button
**Decided per event in the input service** (`ruya-inputd`, T-398), from the device's family (§4.1: the service's device table, T-261, then the driver, then `generic`); never in QML. Per family, by position:

| Action | Xbox / generic | PlayStation | Nintendo | Keyboard |
|---|---|---|---|---|
| `accept` | A (south) | Cross (south); Circle (east) with "Confirm button: right" | A (east) | Enter |
| `back` | B (east) | Circle (east); Cross with "right" | B (south) | Esc / Backspace |
| `options` | Menu | Options | + | M / context key |
| `view` | View | Create | − | Tab |
| `guide` | Guide | PS | Home | Super |
| `tabPrev` / `tabNext` | LB / RB | L1 / R1 | L / R | Q / E, PgUp / PgDn |
| `pagePrev` / `pageNext` | LT / RT | L2 / R2 | ZL / ZR | Home / End |

The **Confirm button** row lives in **Settings > Controllers** (the one Settings home for controllers, with T-368's list): "As on the controller" (default) / "Bottom" / "Right", per console profile, stored by the service (`Input1.SetConfirmButton`). It swaps `accept` and `back` only; a game never sees it (games get positional buttons on the virtual pad).

### 11.3 Who drives the UI
| State | Pads that navigate the shell | Another pad's press | Guide on another pad |
|---|---|---|---|
| Picker, PIN pad, "Who's playing?" dialog, first boot | any pad, the keyboard | (it navigates) | opens the Guide menu as usual |
| Signed in | the **owner pads** of the active profile and the keyboard | nothing in the UI; the first press of each foreign pad per session shows one toast: "This controller isn't <profile>'s. Press Guide to switch or join." | a pad with a default owner (T-267): "Switch to <its profile>?"; an unknown pad: "Who's playing?" (ADR-017) |
| Every owner pad gone (disconnected or battery dead) | the keyboard | "Use this controller for <profile>?": Accept makes it an owner pad; **a PIN-protected profile asks its PIN first**; no idle timeout ever starts a takeover | as the row above |
| App in front | owner pads drive the app (slot 1, ADR-017); other pads reach the app only as assigned player slots; unassigned pads nothing | — | an owner pad opens the Hub; an assigned non-owner player's Guide opens the Hub without Settings and Power (ADR-017 point 3); an unassigned pad: "Who's playing?" |

**Owner pads** are the active profile's pads: with ADR-017's registry (T-264) its assigned slots; before it, the pad that sent the input that signed the profile in, plus any pad that took over or was assigned. The service keeps the set (it sees which pad sent an event; the keys the shell receives carry no source), publishes it in the device record (`profile`), turns only owner-pad events into navigation keys while the route is `shell` or `overlay`, and reports a foreign pad's press as `ForeignInput` for the toast and the prompts; the shell answers with `AssignPad`. Lock clears the set.

### 11.4 Glyphs follow the active input
- **Active input** = the device that sent the last **press** among the owner pads and the keyboard; it changes on the first press of another device, never on connect, a battery report, stick or trigger noise below the navigation threshold, or mouse motion (no flicker). The service sends `ActiveInputChanged(device_id, family)`; the shell tells the keyboard apart by the event's source device (not "RuyaOS Navigation").
- **Glyph of an action** = the label of the button that performs it **after** the Confirm setting (with "Right" on a PlayStation pad, `accept` shows Circle). One set per family, all our own drawings (no vendor artwork; the T-199 question stays open): Xbox letters, PlayStation shapes, Nintendo letters, keyboard key caps, and a **generic** set of position diamonds (four dots, the pressed one filled) for unknown pads. Guide is one home glyph for every pad. Drawing and sizes: `04` §3.7.

## 12. Task map
| Task | What, after this design |
|---|---|
| T-367 / RUY-3 | `ruya-input` user and udev rules (§3), one Xbox 360-style virtual pad per physical pad for the signed-in profile, the ACL re-assert, routing states and `SetRoute` (§5.1-5.2), restart settings (§8.1), `Input1` devices and routing part, mock and client, a VM check and the Dell SuperTuxKart check |
| RUY-409 | the shell calls `SetRoute` (§5.1-5.2); the Dell SuperTuxKart race |
| RUY-410 | the compositor's emergency reader (§8.2) |
| RUY-411 | done: Bluetooth bonded-only VM check and the keyboard-class confirmation (§6) |
| T-368 / RUY-39 | device list, capabilities (§4.3), the live button test; Settings > Controllers |
| T-369 / RUY-42 | profiles v1: schema, validation, global profile, import/export, dead zones and curves |
| T-370 / RUY-43 | game and platform profiles, resolution chain, the game page's Controller entry |
| T-371 / RUY-44 | ownership modes, the grab and hidraw rules and Steam's uinput (§5.3) |
| T-372 / RUY-45 | keyboard and mouse output, layers, chords, shortcuts |
| T-373 / RUY-46 | motion, touchpad (the nodes leave the shell, §3), rumble back to the pad, hidraw |
| T-374 / RUY-47 | semantic actions and glyphs through `Platform1` (the vocabulary of §11.1) |
| T-397 / RUY-38 | owner pads, foreign-pad toast, takeover, Guide on a foreign pad (§11.3; `ForeignInput`, `AssignPad`) |
| T-398 / RUY-40 | the family mapping in the service and the Confirm button row (§11.2; `SetConfirmButton`) |
| T-399 / RUY-41 | active input and action glyphs (§11.4; `ActiveInputChanged`; 04 §3.7) |
| T-263 / RUY-120 | the registry and slots spec: owner pads are the slots of §11.3 |
