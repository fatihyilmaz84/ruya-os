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
Verified: host (vm pending: vm-session-check.sh display) — CHECKPOINT (round 1, 2026-11-09), not finished.

**Design (decided, ADR-023 in `00-overview.md`, Accepted (lead, 2026-11-09)):** the compositor makes one socket per profile, `/run/ruya-wayland/ruya-<id>` (the compositor unit's `RuntimeDirectory`, 0711, `ruya-shell`), mode 0600 plus ACL `user:ruya-<id>:rw-`, bound in a private `.staging` dir and renamed into place, served with `addSocketDescriptor`; `ruya-session` sets `WAYLAND_DISPLAY=/run/ruya-wayland/ruya-<id>` and `SDL_VIDEODRIVER=wayland`; Flatpak binds only that socket as `wayland-0`. Clients are mapped by peer uid (`AppGate.verdict`); other users and everyone but the shell while nobody is signed in are closed at their first surface; `Shell.addApp(item, profile)` shows a window only to its profile and nothing while nobody is signed in. Rejected alternatives (fd handoff from `ruya-session`, one shared socket, a socket unit per profile, `--filesystem` on the directory) are in the ADR. Input: through the compositor only (no `/dev/input` for profile users). GL: Fedora's qt6-qtwayland has no `linux-dmabuf-unstable-v1` plugin, so GL clients cannot share GPU buffers (expected to fall back to software; unverified).

**Implemented:** `services/ruya-session/src/{spawner.rs (WAYLAND_DIR, wayland_display, app_env, FakeSpawner::last_env), session.rs (with_wayland_dir), main.rs}`; `shell/src/session/AppGate.{h,cpp}` (new, in CMakeLists); `shell/qml/Shell.qml` (records carry `profile`, `shownApps`, `appShownTo`, hidden apps get no focus); `shell/compositor/ProfileSockets.{h,cpp}` (new, in CMakeLists) and `Compositor.qml` (sync sockets with `Profiles.profiles`, refuse by verdict, `addApp(item, verdict.profile)`); `ruya-compositor@.service` (`RuntimeDirectory=ruya-wayland`, 0711); `scripts/vm-session-check.sh` (`display`, `display-clean`); docs: ADR-023, ADR-002/004 notes, `01` §2.1, `02` §1.5, `03` launch bullet and the per-profile-home decision for T-163, `PATTERNS.md`, `dev-setup.md`, developer guide (display, *experimental*), Session1.xml header note.

**Verified so far:** `dev.ps1 test` ALL GREEN (948 QML passed, 73 skipped; Rust all passed); new tests `tst_app_owner.qml` (5 functions) and two Rust tests. Revert checks: `appShownTo` -> `return true` fails 4 tst_app_owner tests (revert-check.ps1); `app_env(...)` -> `self.env.clone()` in `Session::launch` fails `each_app_gets_the_wayland_socket_of_its_own_profile` (by hand, cargo test). In WSL (Fedora 44 Qt 6.11): the shell with `RUYA_COMPOSITOR=ON` compiles; the compositor run offscreen made `/run/ruya-wayland/ruya-p1` with exactly `user::rw- user:ruya-p1:rw- group::--- mask::rw- other::---`; `ruya-p1` connected, `nobody` got "Permission denied" (connect and `ls` of the directory); a Qt Wayland client as `ruya-p1` while nobody was signed in was refused (`refused surface/window of uid 990 (nobody-signed-in)`, client disconnected); the shell's own client was accepted (`profile (shell)`). Scratch user and build dir removed afterwards.

**Image:** `scripts/build.sh 0.0.57` finished in WSL (lint passed): `localhost/ruyaos:dev` = image `0c6bc410c343`, version 0.0.57, built from this branch's working tree (before the WIP commit; same content). `make-disk.sh qcow2` was aborted by the lead for the checkpoint: no disk exists yet.

**Next steps (exact):**
1. WSL: `cd /mnt/d/dev/RuyaOS-worktrees/T-164 && scripts/make-disk.sh qcow2` (needs `image/bib/config.toml`, already copied into the worktree; rebuild with `scripts/build.sh 0.0.57` first if `localhost/ruyaos:dev` is no longer `0c6bc410c343`).
2. Windows, in the worktree: `.\scripts\smoke-test.ps1 -Keep` (snapshot mode, no work copy) until `RUYA_BOOT_OK 0.0.57`; `.\scripts\vm-goto.ps1 home` (wizard: Player One, PIN 1234).
3. `scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-session-check.sh scripts/vm-key-client.qml scripts/vm-inject-key.py root@127.0.0.1:/root/`, then `ssh ... bash /root/vm-session-check.sh display` (must end ALL CHECKS PASSED), `.\scripts\vm-screenshot.ps1 profile-app` and review it, `ssh ... bash /root/vm-session-check.sh display-clean`; also `ssh ... bash /root/vm-session-check.sh check` (regression of the T-162 checks with the new env).
4. Stop QEMU, `.\scripts\free-space.ps1`; finish this Outcome (UX notes, socket owner/mode recorded above, the refusal lines), commit, HANDOFF with the Dell commands for STK.

Inbox (for the HANDOFF): GL clients need a `linux-dmabuf-v1` server integration (missing from Fedora's Qt, B-003); `IdleInhibitManager` still counts inhibitors of hidden apps (planner note 3); pad access for games (T-217/T-266, B-006); possibly public: the app display environment (`WAYLAND_DISPLAY` path, `wayland-0` in Flatpak, `SDL_VIDEODRIVER=wayland`), documented as experimental.
