# RuyaOS — session log archive

Older entries of the `docs/STATUS.md` session log, newest first. STATUS keeps only the latest five; the lead moves the rest here at each review. Nobody needs to read this file to start a task.

### 2026-10-23 · Sonnet 5.5 · T-107
Power actions:
- `Power` singleton over a mock and a logind D-Bus backend; Power page (three rows), shared `PowerConfirm` (Cancel focused first), Guide overlay with a power choice list; holding Guide for 2 s opens it; refusals toast.
- Image: polkit rule `50-ruyaos-power.rules` (user `ruya-shell`, six `login1` action ids) and `scripts/vm-power-check.sh`.
- Found and fixed: the overlay's accept-all key handler had disabled Up/Down in its list, and a held Guide's autorepeat closed the overlay; **every file shipped from `image/rootfs` was mode 0777 in the image** (Windows checkout + `COPY`), which also made the new polkit rule world-writable. `rootfs` is now installed with `cp --no-preserve=mode` in a `RUN` that fails the build on anything group/world-writable (a later-layer `chmod` was not enough for directories).

Verification: `dev.ps1 test` → ALL GREEN (11 new tests); `shots` reviewed. Image `0.0.5-t107d`: lint clean, `RUYA_BOOT_OK`; in the VM the shell's user is authorized for all six actions, an ordinary user is refused, `CanPowerOff` is `yes` / `challenge`, and a real `PowerOff` as `ruya-shell` ended QEMU. Unverified: the running shell calling logind (no key scripts yet), a real suspend/wake.

Follow-ups: Inbox line for T-120. NEXT is T-120. The lead review is due (range `9ca4b25..HEAD`): recommend a lead session.

### 2026-10-23 · Sonnet 5.5 · T-122
CI refresh:
- Read the three runs on `main` through the public API: `shell`, `services` and `image` were green in all of them (image 16–23 min); nothing to fix. This is the first Linux/Fedora-Qt run of the shell, so no API newer than Qt 6.8 is in use.
- Token lint extracted to `scripts/lint-tokens.ps1` (called by `dev.ps1` and by a new `lint` CI job); workflow got `permissions: contents: read`, a cancelling `concurrency` group, `workflow_dispatch`, timeouts. `image` stays on every push (reasoning in the task Outcome). `dev-setup.md` has the local-check-to-CI table.

Verification: `dev.ps1 test` → ALL GREEN; a `duration: 120` probe made the lint exit 1. **Unverified:** the changed workflow on GitHub and the lint script under Linux `pwsh`; nothing was pushed (owner's call).

Follow-ups: after the push, read the new run and close T-122. NEXT is T-107. The lead review is due (range `9ca4b25..HEAD`): recommend a lead session.

### 2026-10-23 · Opus 5.5 · Lead role set up
The owner asked for Opus sessions to lead and Sonnet sessions to build. Added:
- `docs/LEAD.md`: roles and authority, plus the lead procedure (orient, verify independently, review each commit against a checklist, plan, direction and ADRs, one lead-only task, handoff, owner report);
- `docs/LEAD-NOTES.md`: handoff between lead sessions, with the review range, ranked concerns and quality signals;
- the `Owner: lead` task marker; builders skip such tasks;
- a "Lead review due" line on the board;
- builders stop when they find uncommitted work they didn't make (concurrent sessions).

`CLAUDE.md`, `PLANNING.md`, the task README and template, `README.md` and `AGENTS.md` were updated to match.

The ISO from the previous session was built: `output/bootiso/install.iso` (3.5 GB, image 0.0.4, dev SSH key, test machines only).

Verification: `dev.ps1 test` ALL GREEN.

Follow-ups: the first lead session has an agenda in `LEAD-NOTES.md` (review `9ca4b25..HEAD`, secret scan of the public history, VM rebuild, ADR-002 spike).

### 2026-10-23 · Sonnet 5.5 · Planning
Planner session (`docs/tasks/PLANNING.md`). The Inbox had 5 items; now empty. No product code written.

New tasks: **T-120** (verify Profiles, the wizard, lockout and Settings → Profiles in the VM over the real bus; adds VM screenshot and key-sending scripts through the QEMU monitor; closes B-005), **T-121** (audio in the VM: sound device, PipeWire for the shell session, UI cues load), **T-122** (CI: read the first GitHub results, make it green, add the token lint).

Inbox items handled:
- B-005 unblocked, verify Profiles over D-Bus in the VM → **T-120** (it also verifies the T-105, T-106 and T-115 D-Bus paths).
- VM has no audio device → **T-121**. Partly stale: `run-vm.ps1` already has `-audiodev dsound` and the image ships PipeWire; only the headless `smoke-test.ps1` has no sound card, and nobody had checked the session's PipeWire.
- CI predates the fixes → **T-122**. First data point: the `services` and `shell` jobs passed on the first push (which is also the first Linux build and offscreen test run of the shell on Fedora's Qt); the `image` job was still building.
- Slow failed-boot rollback (about 100 s per failed boot) → **merged into B-002** (hardware boot times first), dropped from the Inbox.
- Image size and update sizes (4.7 GB, chunked images) → **dropped as a task for now**: it is a release topic (Phase 6, spec 01 §4); listed in the candidates below so it is not lost.

Existing tasks re-checked against what was built (T-106, T-115, T-116, T-117 landed since the last planning):
- T-107: the polkit rule can be verified in the VM now (acceptance criteria added: boot with `RUYA_BOOT_OK`, `pkcheck`, `CanPowerOff`), hints on tokens and the overlay's inline action model.
- T-109: `DeviceSettings.language` and the wizard exist; added a live-switch criterion for the wizard, the audit list (Setup, `ProfileStatus`), the "stored text does not retranslate" pitfall, and the endonym rule.
- T-119: hint about the `Loader.onLoaded` wiring (objectName, `u`, `overlay`, margins) that every stack entry needs.
- T-110: `B-4` → `B-004`; the build-twice note is gone since T-116.
- T-111, T-113, T-114: token-lint hints; T-113 no longer conditional on T-108; T-113 notes that `Tile` now derives its accent from `Theme.tileAccent(key)`.
- T-112, T-118: still accurate.

Queue: 12 `todo` tasks (T-122, T-107, T-120, T-121, T-114, T-109, T-118, T-119, T-110, T-111, T-112, T-113). Ready now: 9 (all but T-111, T-113, T-121). NEXT is T-122 (cheap, and the repo is public), then T-107 and T-120, which both need an image build, so they can share one.

Candidates for the next planning session (each wants a pattern first or is not urgent): Settings → Network and Bluetooth & controllers (after T-114 sets the `Devices1` pattern); profile rename/delete UI (after T-118 lands); Storage settings and the device-inserted toast; controller button-test screen; focus restore per profile (spec 02 §4.3); Accessibility settings (text scale, high contrast, focus-ring size); pointer visibility; FPS/KPI capture scripts; **update sizes and chunked images** (spec 01 §4; measure with two builds in WSL, release topic); guest user handling and the session service (needs T-120's VM workflow).

Verification: docs only; `dev.ps1 test` run before the commit.

### 2026-10-23 · Sonnet 5.5 · T-117
Reduced motion and tokens:
- The PIN-pad shake and the tile pulse do not run under reduced motion (guards at the call sites, `objectName`s for tests); their sizes and durations are `Theme` tokens.
- All other literal durations and colours outside `Theme.qml` became tokens (scrims, panel, error/warning text, white fills, default tint, tile accents via `Theme.tileAccent(key)`); values unchanged.
- `Test-Tokens` in `dev.ps1 shell` fails on a literal non-zero `duration:`, a quoted hex colour or `Qt.rgba(`; `// token-ok: <reason>` opts out (none used).

Verification: `dev.ps1 test` → ALL GREEN (88 tests); the new test was shown to fail without the guard and the lint was shown to fail on `duration: 120`; `dev.ps1 shots` reviewed by eye. Easing types and backdrop drift periods are still literals (not in scope).

Follow-ups: none. NEXT is T-107 (power actions). Planning session still due (Inbox: 5 items).

### 2026-10-23 · Sonnet 5.5 · T-106
First-boot setup:
- `Setup.qml`: five steps (welcome, language, network placeholder, create admin with keyboard + PIN pad, done), progress dots, Back keeps state. The shell shows it while no profile exists and keeps it up until Done, so the picker never flashes.
- `DeviceSettings.language` (`en`/`tr`, validated, persisted); `RUYA_MOCK_PROFILES=empty` for a human run; the status-to-message mapping moved to a `ProfileStatus` singleton shared with Settings → Profiles.

Verification: `dev.ps1 test` → ALL GREEN (8 new tests); `dev.ps1 shots` reviewed (`11-setup-welcome.png`, `12-setup-admin.png`). The new QML singleton built green on the first run (T-116). Unverified: the wizard against the real service over D-Bus, a real controller.

Follow-ups: none new. The Inbox has 5 items, so a planning session is due (B-005 now has something to verify). NEXT is T-117.

### 2026-10-23 · Sonnet 5.5 · T-116
Fixed the "type X is not defined" first-build failure:
- **Cause.** In the Visual Studio generator, the rule that collects the metatypes JSON and the `qmltyperegistrar` rule are in one MSBuild `CustomBuild` batch. MSBuild decides what is stale before the batch runs, so the registrar was skipped on the first incremental build and the stale registration/`.qmltypes` were used. The mirror case, removing a type, broke the compile.
- **Fix.** The `ruyashell_invalidate_stale_qmltypes` target (`shell/cmake/InvalidateStaleQmlTypes.cmake`) deletes the registrar outputs when `CMakeLists.txt` or a module header is newer. Visual Studio generators only. `scripts\repro-first-build.ps1` reproduces and guards it.
- Pitfall notes in `shell/CLAUDE.md` and root `CLAUDE.md` updated.

Verification: `dev.ps1 test` → ALL GREEN; 3 add/remove probe cycles green on the first run; an unchanged tree still takes about 5 s. Two false starts are recorded in the task Outcome (a guard that deleted the outputs on every build, and one that missed removal). Unverified: Linux/Ninja (untouched).

Follow-ups: none. NEXT is T-106 (first-boot setup).

### 2026-10-22 · Opus 5.5 · B-001, B-008 (first real image builds and boots)
The owner installed WSL and QEMU. Set up a Fedora 44 WSL distribution (Podman, no Podman Machine), WHPX QEMU, a dev SSH key, and a git-ignored `image/bib/config.toml`.

Results:
- The **first build** passed (31 min).
- **Smoke test:** first `RUYA_BOOT_FAIL`, although the shell was running; fixed, now `RUYA_BOOT_OK`.
- **Update** 0.0.3→0.0.4: OK.
- **Manual rollback:** OK.
- **greenboot automatic rollback:** 4 failed boots of a broken image, then GRUB fell back to 0.0.3 by itself.

Found and fixed:
- **Readiness check.** `wait-shell-ready` searched the unit's log, but pam_systemd moves the compositor to `session-N.scope`. It now matches `_UID` of `ruya-shell`. Unfixed, greenboot would have rolled back every healthy boot.
- **greenboot was installed but disabled.** Its units are now enabled, and its DNS check is disabled because offline boots would roll back.
- **Test disks too small for an A/B update.** `image/bib/disk.toml` sets a 40 GiB root.
- **Lint warnings** fixed (`/run` leftovers, the `akmods` user, `/var` without tmpfiles). Lint now runs with `--fatal-warnings`.
- **Dead sysusers lines** for `video`/`render` removed (bootc keeps those groups in `/usr/lib/group`; logind ACLs suffice).
- **Host quirks** worked around and documented: WHPX hangs on guest reset (QEMU uses `-no-reboot`), WSL localhost forwarding doesn't work (the registry is reached via WSL's IP), and PS 5.1 argument quoting.

New scripts: `scripts/smoke-test.ps1`, `scripts/vm-reboot-check.ps1`. The full recipe and a problem log are in `docs/dev-setup.md`. `CLAUDE.md` and `image/CLAUDE.md` now require image changes to boot-test.

Verification: vm (as above). `dev.ps1 test` ALL GREEN.

Unverified: real hardware, NVIDIA loading, Secure Boot/MOK, audio, controllers.

### 2026-10-22 · Sonnet 5.5 · T-115
Profiles1 contract extension:
- `CreateProfile` and `SetPin` return `attempts_left` and `retry_after_secs` (XML, `service.rs` returning `Outcome`, `dbus.rs` with a shared `retry_secs` helper, shell D-Bus client);
- `DBusProfilesBackend::probeAttempts` (the `SwitchTo(id, "")` workaround) deleted.

Verification: `dev.ps1 rust` and `dev.ps1 test` → ALL GREEN; two new service tests for attempts and retry time. D-Bus reply parsing unverified (no bus here).

Follow-ups: none. NEXT is T-116.

### 2026-10-22 · Sonnet 5.5 · Planning
Planner session (`docs/tasks/PLANNING.md`). Inbox had 10 items; now empty. No product code written.

New tasks: T-115 (contract: attempts in replies; the reviewer's priority item), T-116 (first-build registration failure), T-117 (reduced motion for feedback animations plus a token lint), T-118 (profile rename/delete: contract, service, mock), T-119 (nested pages in the page host; shared infrastructure split out of T-111 per the planning lessons).

Inbox items handled:
- PIN shake / tile pulse ignoring reduced motion → T-117.
- First-build "type not defined" (T-102, T-108) → T-116 (and the pitfall note in `shell/CLAUDE.md` stays until it lands).
- Late `activeFocus` checks flaking when the window is inactive → **dropped**: `dev.ps1 test` is offscreen now, so the class of failure is gone from the gate; the `hasFocus` helper in `tst_system_ui.qml` is harmless and may be deleted whenever that file is edited.
- Volume `Shortcut`s unverified under a compositor → noted on blocker B-003.
- Priority: replace the `SwitchTo` probe by a contract extension → T-115, ordered first because T-106 reuses the same error handling.
- No delete/rename/second admin in the UI → T-118 covers rename and delete (contract, service, mock); the UI for them is left for the next planning session, once T-118 lands. A second admin is **escalated** (Open owner decisions: the overview says one admin, 03 §1.1 says one or more).
- Toasts covering Settings row values → **dropped**: they last 4 s and sit in the safe area; revisit only after seeing them on a real TV.
- `TextEntry` mouse/touch → **dropped** (pointer input is a "Later" item; spec 02 §4.3 pointer rules are unimplemented by design). Non-Latin layouts → merged into T-109 (Turkish letters, which also needs the keyboard layout to follow the language).
- Key-repeat acceleration and long-press → noted on blocker B-006 (it belongs to the input daemon replacement).
- Stepping volume while muted → merged into T-114.

Existing tasks corrected against what was built: T-106 (mock reset API exists, `DeviceSettings.language` added there, uses `collect-confirm` and `TextEntry`), T-107 (modal and Guide-press timing notes), T-109 (depends on T-106, audit list, Turkish keyboard layout, System pane, ephemeral default language `en` for tests), T-111 (depends on T-119; TextEntry exists; stale page-host hint replaced), T-113 (mock reset), T-114 (mute semantics, Audio pane).

Queue: 13 `todo` tasks, 9 of them with all dependencies done today (T-115, T-116, T-106, T-117, T-107, T-114, T-119, T-110, T-112), the rest one step behind. That is above the 8–12 target on purpose: four are S-sized and two are chain links.

Candidates for the next planning session (not written yet, because each needs a pattern first): Settings → Network and Bluetooth & controllers (contract `Devices1` network/bluetooth parts after T-114 sets the pattern), Storage settings and the device-inserted toast, the profile rename/delete UI after T-118, the controller button-test screen, focus restore per profile (spec 02 §4.3), Accessibility settings (text scale, high contrast, focus-ring size), pointer visibility, FPS/KPI capture scripts.

Verification: docs only; `dev.ps1 test` run before the commit.

### 2026-10-22 · Sonnet 5.5 · T-105
Manage profiles from Settings:
- `createProfile`/`setPin` through the backend interface, mock (rules mirror `service.rs` and `lockout.rs`), D-Bus backend and `Profiles`; `Profiles.resetMockForTests` for tests (and T-106);
- `PinPad` modes `collect` / `collect-confirm`; `ProfilesPane` with `ProfileAddFlow` and `ChangePinFlow`; `Page.overlay` + `modalLayer` for page-owned modals; scrollable `SettingsPane` that keeps focus;
- signals carry attempts left / retry seconds (the contract replies don't, so the D-Bus backend probes `SwitchTo(id, "")`).

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`10-settings-profiles.png`). D-Bus paths unverified. One red run was caused by a locked Windows session, not code (QML timers stall without rendering): check `Get-Process LogonUI` before debugging timing failures.

Follow-ups: see Inbox. NEXT is T-106 (first-boot setup).

### 2026-10-22 · Sonnet 5.5 · T-104
On-screen keyboard:
- `TextEntry.qml`: data-driven layout (letters and symbols pages, text/email/url), nearest-key vertical navigation, one-shot Shift, mask, `maxLength`, modal with focus restore;
- Return/Escape are the same keys for a controller and a keyboard, so a "typed on a physical keyboard" mode makes Return = Done and Escape = Cancel (see the Outcome).

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`9-text-entry.png`).

Follow-ups: see Inbox. NEXT is T-105 (first consumer of `TextEntry`).

### 2026-10-22 · Sonnet 5.5 · T-103
Settings page:
- two-pane `SettingsPage` (9 categories, Coming soon for those without content), `SettingsPane` row container;
- reusable controls in `qml/controls/` (`SettingRow`, `ToggleRow`, `ChoiceRow`, `SliderRow`) on a `SettingControl` base;
- Display & motion bound live to `DeviceSettings`; About with a new `SystemInfo` singleton (Qt version);
- `Page.version`, `Sfx` cue counters; `tst_pages.qml` adjusted because Settings is no longer a placeholder.

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`7-settings-display.png`, `8-settings-about.png`).

Follow-ups: see Inbox. NEXT is T-104.

### 2026-10-22 · Sonnet 5.5 · T-108
Toasts and volume OSD:
- `Notifications` queue (max 3 visible, auto-dismiss) and `ToastLayer`; `VolumeOsd`; mock `Audio` singleton;
- volume keys are application `Shortcut`s at the `Shell` root, so modals cannot swallow them and focus never moves;
- picker and Guide overlay are z 20, toasts z 10, OSD z 30.

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`14-toast-and-osd.png`). `Shortcut` behaviour under a real compositor is unverified.

Follow-ups: new C++ QML types need a second build before the first run is clean (recorded in `shell/CLAUDE.md`, cause unknown). NEXT is T-103.

### 2026-10-22 · Sonnet 5.5 · T-102
Reduced motion and effects quality tiers:
- `DeviceSettings` C++ singleton (reduced motion, effects tier, overscan; `QSettings`, in-memory under test);
- `Theme` tokens follow it (durations 0, `blurMax` 64/32/0, `glassOpaque`, `safeArea`); backdrop drift stops with reduced motion or on the performance tier; the shelf blur is hidden at tier 0;
- `--reduced-motion` and `--effects <tier>` session-only flags.

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`6-performance-tier.png`). The flags were smoke-run by hand.

Follow-ups: the PIN-pad shake and tile pulse still use literal durations and ignore reduced motion (noted in the task Outcome). NEXT is T-108; T-103 is now unblocked too.

### 2026-10-22 · Sonnet 5.5 · T-101
Page navigation framework:
- `Shell.openPage/closePage` over a `pageStack`; `Page.qml` base and five placeholder pages;
- home tiles carry keys; Back restores tile focus; the Guide overlay works over pages and "Switch profile" clears the stack;
- the Guide key handler moved to the `Shell` root so pages need not handle it.

Verification: `dev.ps1 test` → ALL GREEN; `dev.ps1 shots` reviewed (`5-page-settings.png`, `4-overlay.png`). Transition motion itself is not asserted.

Follow-ups: none. NEXT is T-102.

### 2026-10-22 · Opus 5.5 · T-007
Set up the AI handoff:
- root and area `CLAUDE.md` files;
- `scripts/dev.ps1` (one entry point for check/build/test/run/shots);
- the task format and 14 tasks (T-101–T-114) with testable acceptance criteria;
- this board.

Found and fixed that qmllint exits 0 on warnings: `--max-warnings 0` is now used locally and in CI.

Verification: `dev.ps1 test` → ALL GREEN (Rust 21 tests, clippy Windows + Linux, shell build, qmllint, 12 QML tests + 1 screenshot test skipped without `RUYA_SHOTS_DIR`).

Follow-ups: none beyond the board.

### 2026-10-22 · Opus 5.5 · T-004, T-005, T-006
- Native MSVC shell build.
- `ruya-profiles` (argon2id PINs, lockout, admin-gated creation, atomic store, zbus adapter, hardened unit and bus policy).
- Shell picker, PIN pad and overlay "Switch profile", backed by a Profiles client (mock + QtDBus).

The tests caught two real focus bugs and one layering bug; all fixed. D-Bus paths are unverified.

### 2026-10-22 · Opus 5.5 · T-001, T-002, T-003
- Consolidated the three research docs into `docs/specs` and recorded the review in `docs/REVIEW.md`.
- Scaffolded Phase 0.
- Owner decisions recorded: fully open source (ADR-008); ship all codecs and drivers (ADR-009); continue on the Windows host.
