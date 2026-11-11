# T-468 — Developer docs: the Hub pauses (freezes) your game

Status: todo · Phase: 2 · Depends: — · Area: docs (developers) · Size: S · Owner: builder · Complexity: normal · Developer surface: public-format

## Goal
A developer making a game for RuyaOS knows exactly what happens to it when the player opens the Ruya Hub, goes Home or switches to another game, and what to do about it. Today `docs/developers/fullscreen-and-lifecycle.md` (lines ~34-40) still describes the old overlay ("keep running behind the overlay, pause when you lose focus"; the quick menu "planned"), while since T-457 the Hub **freezes** the game's processes (cgroup freezer) and Home leaves it frozen (ADR-033, `02` §1.6).

## Scope
1. **Find out, don't assume** (code, then the VM over SSH where the code cannot say): before the freeze, does the game get anything (Wayland keyboard leave / focus out, `xdg_toplevel` state, frame callbacks stopping)? While frozen: timers, sockets (a peer may time out), audio (silent; T-466 will detach the stream), memory (T-465/T-466: may be swapped out after about 30 s). After the thaw: what arrives first (focus in, a frame callback), the time jump (CLOCK_MONOTONIC keeps running), how long Thaw takes (Dell study: about 200 ms).
2. Rewrite the section "The Guide button and the Hub" (or the current overlay section) in `fullscreen-and-lifecycle.md`: what the player sees, what your process experiences, and what to do (clamp frame time after a long gap; pause gameplay on focus loss if the console sends it, else on the time jump; reconnect or tolerate a dropped network peer; save at safe points, since a frozen game cannot react to Close).
3. Update the checklist at the end, the samples if one pauses on focus loss, and `api-surface.md` if it lists the overlay.
4. Mark anything not yet built as planned with its task (T-465, T-466), as the guide does elsewhere.

## Acceptance criteria
- [ ] Every statement about frozen behaviour cites what was checked (code path or VM run) in the Outcome
- [ ] `dev.ps1 docs` ALL GREEN (developer guide lint)
- [ ] `ruya-api-reviewer` at merge (Developer surface: public-format)

## Hints
- Planned by lead-11 on the owner's question. The Close path (thaw, then SIGTERM, grace, kill: T-457, T-458) belongs in the same page's "Stopping" section: check it is still right.

- Since T-467 every Session1 game is frozen by the Hub, including pygame/SDL ones whose window Session1 cannot map (before, those kept running under the Hub).

## Outcome
Verified: host (vm pending: what a Wayland client receives around the freeze, see "To verify (VM)")

**What was written.** `fullscreen-and-lifecycle.md`: the section "The Guide button and the overlay" is replaced by "The Guide button and Ruya Hub: your game is paused" (what the player sees; a table of what the process experiences with the basis of each row; what the game is told; seven things to do, a Python gap-detection snippet; how to test). "Stopping" now says Close game thaws first and that the 5 s count includes the thaw; the profile-switch bullets say what happens today; the checklist, header date and Sources are updated. Smaller edits: `controller-input.md` (Guide opens the Hub, which freezes), `README.md` (Pause quick fact, chapter row), `saves-and-data.md` (Close game is built), `play-time.md` (no play time under the Hub), `audio-and-video.md` (rule 6: silence while frozen, T-466 planned), `testing-and-debugging.md` (item 8: freeze and thaw by hand with `busctl`, checklist line), `api-surface.md` (the Lifecycle row's Missing cell). Samples: none pauses on focus loss (`grep` of `samples/hello-game/src/main.c` finds no focus handling), so none changed; the sample's `dt` clamp is cited as the model. Nothing planned is stated as built: T-466 (audio detach, memory reclaim), T-279 (lifecycle API events), T-165 (profile-switch freeze) are marked planned.

**What each statement rests on.**
- *Freeze is the cgroup freezer on the unit and every active app scope; Electron's two scopes; failed freeze undone and the game keeps running; Thaw also for an app not known as frozen; Freeze/Thaw served in order; each systemctl bounded to 5 s*: `services/ruya-session/src/systemd.rs` `freezer` (lines ~278-294), `session.rs` `freeze`/`thaw` (~311-370), `dbus.rs` `freezer_turn` (~221-270); spec 03 section 4.1.
- *Close thaws first, then SIGTERM, 5 s, SIGKILL; the 5 s starts before the thaw*: `session.rs` `stop` (thaw then `spawner.stop`), `dbus.rs` `stop` (`session.stop(instance, Instant::now())`: the `now` is taken before the thaw), `tick`/`STOP_GRACE`; `Shell.qml` `closeApp` calls `Session.stop` only. The "Stopping" section was otherwise still right (reasons table unchanged in `exit_reason`).
- *What the player sees, Home leaves it frozen, Switch to, the setting (default on, Settings -> System), freeze failure, the sweep, Switch profile*: `shell/qml/HubPause.qml`, `Shell.qml` (`hubPause`, `fallbackFront`, `appFrozen`), `DeviceSettings.cpp` (`hub/pauseGames`, `m_pauseGamesInHub = true`), `SystemPane.qml`; `02-shell.md` section 1.6 ("The game pauses") and "No key reaches the app while the Hub is open".
- *No play time under the Hub*: `Shell.qml` `foregroundInstance` returns "" while `systemPanel.open`.
- *The compositor sends only fullscreen and a size, never activated/suspended*: `shell/compositor/Compositor.qml` (`toplevel.sendFullscreen` is the only state call; `grep` for `sendActivated`/`setKeyboardFocus`/`takeFocus` in `shell/` finds none).
- *Kernel-level behaviour (clocks, timers, sockets, signals, freeze/thaw time)*: **measured, 2026-11-11**, Fedora 44 WSL (kernel 6.18, systemd 259, cgroup v2): a Python stand-in game in a transient user service (`systemd-run --user`), a TCP peer outside it, `systemctl --user freeze` for 6 s then `thaw`, then a second freeze with `SIGTERM` sent while frozen. Result: loop gap monotonic = realtime = boottime = 6.085 s, CPU-time clock 0.000; a 1 s `timerfd` read 6 expirations in one read; 6 pings read in one `recv`; the peer saw 6.61 s of silence (it noted a 3 s timeout); the SIGTERM sent while frozen was handled 4 ms after the thaw; `FreezerState` frozen/running as expected; the freeze call took 0.506 s (WSL was busy with the lead's image build) and the thaw call 7 ms. Scripts were scratch (`game.py`, `peer.py`, `run.sh` in the session scratchpad), not committed. This is not a Flatpak and not a Wayland client.
- *Thaw about 200 ms for a large game, memory reclaim after about 30 s, audio detach*: `docs/tasks/T-466-...md` ("Found", lead-11 Dell study) and `03` section 4.1 (sound stops because the pulse client stops feeding the stream); written as "planned (T-466)" and "study", not as measured here.

**To verify (VM)** (not done: no finished disk was available, the lead's 0.0.65 build was running; the doc says "not checked on the console yet" for each, and its advice holds either way): (1) does a Qt and an SDL Wayland client receive `wl_keyboard.leave` / a focus-lost event when the Hub opens (the shell's `app focus ... false` log line exists, but Qt's `ShellSurfaceItem` may or may not move the Wayland keyboard focus), and does the focus-in arrive right after the thaw; (2) frame callbacks after the thaw; (3) a real Flatpak game frozen and thawed (both scopes), with the sound heard afterwards; (4) the freeze/thaw time on the VM. Procedure: extend `scripts/vm-key-client.qml` to log `onActiveChanged` and each frame (see inbox), open the Hub with Guide, wait 6 s, Resume, read the journal lines.

**Revert test:** n/a (docs only). `dev.ps1 docs` ALL GREEN (text, board, developer guide lint with its self-checks, spec lint). No code outside `docs/` touched, so no full `test`. `lost-tests.sh` unaffected (no test files touched).

**Developer surface** is `public-format`: the new text describes what a running app experiences (freeze, clocks, sockets). Nothing new was made reachable; `Session1.Freeze`/`Thaw` are described only as the console's own call for tests (root and the shell), and no stability tag was added.
