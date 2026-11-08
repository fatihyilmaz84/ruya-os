# T-164 — Per-profile Wayland sockets: an app launched for a profile appears in the shell

Status: in-progress · Phase: 2 · Depends: T-162 · Area: shell, services, api, image · Size: M · Owner: lead

## Goal
An app that `ruya-session` starts as a profile's Unix user connects to a Wayland socket only that user can open, and its window appears full-screen in the shell's app layer. No app window is ever drawn while nobody is signed in.

## Read first
- `docs/specs/00-overview.md` ADR-002 (option A, as built), ADR-004; `02-shell.md` §1.5; `01-platform.md` §2
- `shell/compositor/Compositor.qml`, `shell/src/input/KeyRouter.*`, `Shell.addApp` in `shell/qml/Shell.qml`
- T-130 and T-162 Outcomes; `scripts/vm-app-check.sh`, `vm-key-client.qml`

## Scope
1. **Socket design (decide in the VM, record as an ADR *Accepted (lead)* or in 01 §2):** today clients connect to `ruya-0` in `ruya-shell`'s 0700 runtime directory, which a profile user cannot reach. Preferred: `ruya-session` creates a listening socket `wayland-0` in the profile's runtime directory, owned by and only reachable for that user, and hands the fd to the shell (`Session1` signal or method with a `h` argument, contract first); the compositor serves it with `QWaylandCompositor::addSocketDescriptor`. Alternatives (the compositor creating the socket itself with an ACL) are fine if simpler and as tight; say why.
2. **Which profile a client belongs to:** the compositor maps each client to a profile by its peer uid (`WaylandClient.userId`); a client whose uid is not the signed-in profile's (or `ruya-shell`'s own, for the VM test client) is not shown and is closed.
3. **Nobody signed in:** no app surface is shown above the picker or the wizard (Inbox, T-130): surfaces wait hidden, or are refused; T-165 then decides what a profile switch does to them.
4. The spawner sets `WAYLAND_DISPLAY` for the launched unit to that socket (T-162's `launch_command`, tested).
5. **VM check:** extend `vm-session-check.sh` (or `vm-app-check.sh`): `Session1.Launch` of a Wayland test client for `p1` while `p1` is signed in: the surface appears in the app layer (journal line `ruya-compositor: app …`, VM screenshot), Guide still opens over it; the same client as `ruya-p2` (not signed in) is not shown; `ruya-p2` cannot connect to `p1`'s socket (permission denied).

## Out of scope
- Freezing or stopping apps on a profile switch (T-165), the full-screen app flow (T-147), PipeWire sockets for profile apps (B-007, ADR-010), Xwayland.

## Acceptance criteria
- [ ] `dev.ps1 test` ALL GREEN; any shell-side mapping logic that can run on Windows has a QML or C++ test.
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; the Scope 5 checks ALL PASSED; one VM screenshot of a profile's app in the app layer, reviewed.
- [ ] The socket's owner and mode, and the refusal for the other user, recorded in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `scripts\smoke-test.ps1` and the VM check over SSH. `Compositor.qml` has no Windows test: the image build is its only compile check.

## Docs to update
- ADR-002/ADR-004 notes in `00-overview.md`, `01-platform.md` §2, `02-shell.md` §1.5, the Session1 XML if extended.

## Hints
- `vm-key-client.qml` is a ready Wayland test client; run it through `ruya-shell --qml` as the profile user.
- Mind the hardening of `ruya-session` from T-162: creating a socket in `/run/user/<uid>` needs write access there.
- Same per-profile problem, next in line (lead, T-163): `ruya-library` can't read profile homes (`ProtectHome`), so Steam libraries per profile need a path in. Options: a per-profile user unit started by `ruya-session`, or `ruya-session` handing the library a directory fd. Choose here, with the socket design, and note it in `03` (no Steam code in this task).

- Planner notes (2026-11-07 inbox triage): (1) **GL clients on KMS (Dell, B-003):** the shell logs `Failed to initialize EGL display ... no EGL_WL_bind_wayland_display extension` on real Intel hardware (and in the VM); pick a Qt Wayland hardware integration that works on KMS (`linux-dmabuf-v1`) and test a **GL client on the Dell**, not only the software test client. (2) **Input for profile apps:** a game running as `ruya-p<N>` cannot open `/dev/input/event*` (the udev ACL is for the shell's session) and `ruya-inputd` does not grab, so every pad press also arrives as a key (B-006): decide per-profile access to the pads here or record it for T-217/T-266. (3) `IdleInhibitManager` (T-202) ignores which surface holds an inhibitor: key it by the client surface once clients are mapped. (4) `Library.launch` only emits `launchRequested`: T-147 wires it to `Session.launch`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
