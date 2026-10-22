# RuyaOS — Status

**Read this first in every session; update it last.** The rules are in the root `CLAUDE.md`, the task format in `docs/tasks/README.md`.

Last updated: 2026-10-23 (Sonnet 5.5, T-116)

## Where we are

- **Phase 0 (foundation):** **verified in a VM on 2026-10-22.** The image builds, passes lint, boots to the shell, updates, and rolls back both manually and automatically (greenboot). Only the real-hardware item is left (B-002).
- **Phase 1–2 (shell core, profiles):** in progress on the Windows host against mock services.
- **Host:** Windows, plus a Fedora 44 WSL distribution for image builds and QEMU/WHPX for boot tests (`docs/dev-setup.md`). Work that needs a GPU, controllers or audio still waits in the Blocked table.

Verification legend: **host** = built and tested on the Windows host · **vm** = built into the image and verified booted in QEMU · **unverified** = written, but not run · **hw** = verified on real hardware.

## Board

**NEXT → T-107**

| ID | Title | Status | Depends | Verified |
|---|---|---|---|---|
| [T-107](tasks/T-107-power-actions.md) | Power actions (suspend/restart/off) | todo | T-101 | |
| [T-114](tasks/T-114-audio-contract-and-settings.md) | Audio contract and Settings → Audio | todo | T-103, T-108 | |
| [T-109](tasks/T-109-translations.md) | Translations en/tr, live switching, Turkish keyboard layout | todo | T-103, T-106 | |
| [T-118](tasks/T-118-profile-rename-delete.md) | Profiles1: RenameProfile and DeleteProfile (contract, service, mock; no UI) | todo | T-115 | |
| [T-119](tasks/T-119-nested-pages.md) | Page host: nested pages that keep their state | todo | T-101 | |
| [T-110](tasks/T-110-store-contract-and-mock.md) | Store contract and mock backend | todo | — | |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 | |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — | |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 | |

The order above is the recommended order. When the NEXT task is blocked, take the first `todo` row whose dependencies are all `done`. If no row qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`); never invent work.

## Inbox

Follow-ups, debt and ideas waiting for a planner session. Builders: add one line per item, `- (source) what, and why it matters`. Don't write task files for these unless your own task needs one. A planner session turns them into tasks, drops them with a reason, or escalates them. **Run a planner when this list has 5+ items.**

- (B-001) **B-005 is unblocked.** The VM runs the real shell against the real `ruya-profiles` over the system bus, with an empty profile store, so it now shows the first-boot wizard (T-106 landed; its D-Bus path is unverified). Plan a task to verify Profiles over D-Bus in the VM (picker, PIN, lockout, CreateProfile, SetPin) and fix what breaks.
- (B-001) A failed boot takes about 100 s (90 s greenboot check + 120 s VM marker), so automatic rollback takes about 7 minutes. Consider a shorter required-check timeout once real-hardware boot times are known (spec 02 §8 KPI: shell < 15 s on the low tier).
- (B-001) The image is 4.7 GB. A switch reuses layers (0.0.3→broken needed 931 bytes; 0.0.3→0.0.4 about 2 minutes because the NVIDIA layer was rebuilt). Measure real update sizes and plan chunked images (spec 01 §4) before release.
- (B-001) The VM has no audio device, so UI sound (PipeWire, QSoundEffect formats) is unverified on Linux. Add an `-audiodev` to a VM profile, or test on hardware.
- (B-001) CI (`.github/workflows/ci.yml`) predates today's fixes: it never ran, still uses `scripts/smoke-test.sh` (Linux/KVM), and doesn't run the update/greenboot drill. The repo now has a remote (2026-10-23), so the workflow runs on every push to `main`; its first results were not looked at. Review it.


_(empty: handled in the 2026-10-22 planning session; see its log entry)_

### Done

A session can't know its own commit hash before committing, so new rows put the task id in the Commit column; find the commit with `git log --grep=T-xxx`. Every commit message names its task.

| ID | Title | Verified | Commit |
|---|---|---|---|
| T-001 | Consolidated specs and review (`docs/specs`, `docs/REVIEW.md`) | n/a | 7aa6054 |
| T-002 | Phase 0 scaffold: bootc image, cage session unit, greenboot check, hello shell, `ruya-inputd`, scripts, CI | shell + inputd mapping: host · image/session/CI: **unverified** | 7aa6054 |
| T-003 | ADR-008 licences; ADR-009 codecs + NVIDIA in the image | **unverified** (image) | 56e4a55 |
| T-004 | Native Windows shell build (MSVC + Qt 6.10.3) | host | d91c11f |
| T-005 | `ruya-profiles` service + `org.ruyaos.Profiles1` contract | core: host (15 tests) · D-Bus serving, `useradd`, unit, policy: **unverified** | 717b039 |
| T-006 | Shell profile picker, PIN pad, Profiles client (mock + D-Bus), Qt Quick tests | mock path: host (13 tests) · D-Bus client: **unverified** | eb0b28d |
| T-007 | AI contributor workflow: `CLAUDE.md` files, `scripts/dev.ps1`, task backlog, this board | host (`dev.ps1 test` green) | handoff commit |
| T-101 | Page navigation framework (`Shell.openPage`, `Page.qml`, five placeholder pages) | host (`dev.ps1 test` green, new `tst_pages.qml` + screenshot reviewed) | ac93198 |
| T-102 | Reduced motion and effects quality tiers (`DeviceSettings`, `--reduced-motion`, `--effects`) | host (`dev.ps1 test` green, new `tst_motion.qml` + screenshot reviewed) | T-102 |
| T-108 | Toasts (`Notifications`, `ToastLayer`), volume OSD, mock `Audio` singleton, volume keys | host (`dev.ps1 test` green, new `tst_system_ui.qml` + screenshot reviewed) | T-108 |
| T-103 | Settings page (two panes), reusable controls, Display & motion and About panes, `SystemInfo` | host (`dev.ps1 test` green, new `tst_settings.qml` + 2 screenshots reviewed) | T-103 |
| T-104 | On-screen keyboard (`TextEntry`: D-pad typing, shift, symbols, email/url layouts, mask, max length) | host (`dev.ps1 test` green, new `tst_textentry.qml` + screenshot reviewed) | T-104 |
| T-105 | Settings → Profiles: add profile, change/remove PIN; mock mirrors `service.rs`; PinPad collect modes | mock path: host (`dev.ps1 test` green, new `tst_profile_admin.qml` + screenshot reviewed) · D-Bus `CreateProfile`/`SetPin` + attempts probe: **unverified** | T-105 |
| T-115 | Profiles1: `CreateProfile`/`SetPin` replies carry `attempts_left` and `retry_after_secs`; `SwitchTo` probe removed | service + adapter types: host (`dev.ps1 rust` green, 2 new tests) · shell mock path: host (`dev.ps1 test` green) · D-Bus reply parsing: **unverified** | T-115 |
| T-106 | First-boot setup wizard (`Setup.qml`: welcome, language, network placeholder, create admin, done); `DeviceSettings.language`; `RUYA_MOCK_PROFILES=empty`; shared `ProfileStatus` messages | mock path: host (`dev.ps1 test` green, new `tst_setup.qml` with 8 tests + 2 screenshots reviewed) · real `ruya-profiles` over D-Bus: **unverified** | T-106 |
| T-117 | Reduced motion honoured by the PIN-pad shake and tile pulse; literal durations/colours moved into `Theme` tokens; token lint in `dev.ps1 shell` | host (`dev.ps1 test` green, new test fails without the guard, lint failure demonstrated; 3 screenshots reviewed by eye) | T-117 |
| T-116 | First build after adding or removing a C++ QML type is green (stale `qmltyperegistrar` under the Visual Studio generator; build step `InvalidateStaleQmlTypes.cmake`) | host (`dev.ps1 test` green; 3 add/remove probe cycles via `scripts\repro-first-build.ps1`, all green on the first run) · Linux/Ninja: not run | T-116 |

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| ~~B-001~~ | **Done 2026-10-22 (vm).** Image built (lint clean, fatal warnings), booted to the shell, update 0.0.3→0.0.4, manual rollback, and greenboot automatic rollback from a broken image | — | Session log 2026-10-22 (Opus); recipe in `docs/dev-setup.md` |
| B-002 | Install on a real low-tier machine; first frame-time numbers (§8 item 8) | Hardware | A dev installer ISO now exists (`output/bootiso/`, contains the dev SSH key; for test machines only) |
| B-003 | Compositor spike: shell as QtWaylandCompositor, overlay over a running game (ADR-002) | Linux with a GPU | Decides the product architecture; do it as soon as Linux is available. Also check there: the volume-key `Shortcut`s (T-108) work with an app focused. |
| B-004 | `ruya-store` Rust service over libflatpak/AppStream | Linux | Contract from T-110 |
| B-005 | Shell ↔ services over a real D-Bus (Profiles first) | **Unblocked:** the VM runs the real shell, `ruya-profiles` and the system bus | Can be done in the VM over SSH now; needs a task (planner) |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), with grab/re-emit | Linux + controllers | Also owns the key-repeat model (400 ms delay then accelerating repeat, stick repeat speed) and Accept long-press / context menu from spec 02 §4.3; the shell only sees key events. |
| B-007 | `ruya-devices` service (PipeWire, NetworkManager, BlueZ) | Linux | Audio contract from T-114 |
| ~~B-008~~ | **Done 2026-10-22 (vm).** greenboot (0.16, Rust) works on bootc once its units are enabled: 4 failed boots of a broken image, then GRUB fell back. The NVIDIA 615.78 kmod builds and is signed in the image; the private key is removed | — | Loading on real NVIDIA hardware and Secure Boot/MOK are still unverified (needs hardware) |

## Open owner decisions

- **ADR-002** (compositor): recommendation A, pending spike B-003.
- **libdvdcss / AACS** (DVD/Blu-ray decryption): not included; needs an explicit owner decision.
- **One admin or several?** `00-overview` §2 (MVP) says "one admin", `03` §1.1 says "Admin (one or more)". The service supports several; the UI offers only Standard and Guest when adding a profile (T-105). Options: (a) keep one admin in the UI for the MVP, as the overview says; (b) let an admin create more admins and fix the overview. Recommendation: (a), and revisit after the first user test. Not blocking: T-118 does not depend on it.
- **Publishing:** decided. The owner pushed `main` to https://github.com/fatihyilmaz84/ruya-os.git on 2026-10-23 (history scanned for secrets first; the dev SSH key in `image/bib/config.toml` is git-ignored). Whether the repo is public and which licence file it carries (ADR-008) were not checked in that session. Later pushes still need the owner's go-ahead.

## Session log (newest first)

Each entry: date · model · tasks · what happened · verification · follow-ups. Keep entries short and factual.

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
