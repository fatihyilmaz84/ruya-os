# T-303 — Spike and spec: system ids, ROM and capture layout, and how a sandboxed app reaches the hub

Status: todo · Phase: 5 · Depends: T-302 · Area: services, docs, image · Size: M · Owner: lead

## Goal
Decide, with a working prototype, the three things the rest of epic T-302 stands on: the standard system list and folder layout, how a Flatpak app gets read/write access to those folders, and how it talks to the hub. Part of T-302.

## Read first
- T-302, 03 §4.5a, `docs/developers/permissions-and-sandbox.md`, `saves-and-data.md`, `05-play-packages.md` (permission vocabulary), T-250 (ADR-015), `ruya-session` / `ruya-library` D-Bus policies in `image/rootfs/usr/share/dbus-1/system.d/`

## Scope
1. **Systems:** a table in the spec: id, display name, extensions, typical emulators/cores (libretro and standalone), BIOS note (we ship none). Source: libretro/No-Intro naming; stored as data (`/usr/share/ruyaos/systems.json`), loaded by the hub, extensible by a drop-in.
2. **Layout:** per-profile `~/ROMs/<system>/` and `~/Captures/{screenshots,recordings}/<game>/`, a shared read-only console folder (decide the path under `/var/lib` and who may write), the USB convention `RuyaOS/ROMs/<system>/`; saves/states/config stay under `~/.var/app/<id>/data` by default with the hub able to answer `Paths(kind)` per game for apps that opt in. Decide whether saves are shared between emulators for the same game (recommendation: no in v1; one folder per app, the hub only names it).
3. **Sandbox reach:** try in a VM with the sample Flatpak: (a) `--filesystem=` finish-args for the ROM roots read-only, (b) the document portal / `xdg-desktop-portal` file chooser, (c) fd passing from the hub. Pick one, measure what it needs from the image (portal packages), and how permissions map into the closed `.play` vocabulary (05 §8).
4. **Bus reach:** D-Bus system bus `--system-talk-name=org.ruyaos.Hub1` from the sandbox versus a session-bus proxy; decide push (app → hub `Report`) and optional pull; the policy file keeps "root and ruya-shell may own/call" restrictive — an app user (ruya-pN) may call only the methods listed, only for its own profile (the hub checks the caller's uid).
5. Output: the Outcome with the decisions, ADR-020 updated or sent to the owner, and prototype findings; a minimal hub stub is allowed if needed to prove the sandbox path.

## Out of scope
- The full service (T-304), captures (T-305), UI.

## Acceptance criteria
- [ ] The sample sandboxed app lists a ROM folder, writes a save into the path the hub names, and calls `Hub1` over the bus in the VM, with the exact finish-args and policy lines recorded.
- [ ] Spec table of systems and layout written; `.\scripts\dev.ps1 docs` green.

## Outcome
_Filled in by the lead. First line: `Verified: vm | host`._
