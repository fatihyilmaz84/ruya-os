# RuyaOS — Status

**Read this first in every session; update it last.** The rules are in the root `CLAUDE.md`, the task format in `docs/tasks/README.md`.

Last updated: 2026-10-22 (Sonnet 5.5)

## Where we are

- **Phase 0 (foundation):** scaffolded, but the image has **never been built or booted**, because this host has no Linux. See blockers B-001, B-002 and B-008.
- **Phase 1–2 (shell core, profiles):** in progress on the Windows host against mock services.
- **Host constraints:** Windows-only development. The owner has said to continue on this machine. Linux-only work waits in the Blocked table.

Verification legend: **host** = built and tested on the Windows host · **unverified** = written, but cannot run here (Linux/image/D-Bus) · **hw** = verified on real hardware.

## Board

**NEXT → T-104**

| ID | Title | Status | Depends | Verified |
|---|---|---|---|---|
| [T-104](tasks/T-104-on-screen-keyboard.md) | On-screen keyboard | todo | — | |
| [T-105](tasks/T-105-profile-management.md) | Manage profiles from Settings | todo | T-103, T-104 | |
| [T-106](tasks/T-106-first-boot-setup.md) | First-boot setup (OOBE) | todo | T-102, T-104, T-105 | |
| [T-107](tasks/T-107-power-actions.md) | Power actions (suspend/restart/off) | todo | T-101 | |
| [T-109](tasks/T-109-translations.md) | Translations en/tr, live switching | todo | T-103 | |
| [T-114](tasks/T-114-audio-contract-and-settings.md) | Audio contract and Settings → Audio | todo | T-103, T-108 | |
| [T-110](tasks/T-110-store-contract-and-mock.md) | Store contract and mock backend | todo | — | |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-101, T-110 | |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — | |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 | |

The order above is the recommended order. When the NEXT task is blocked, take the first `todo` row whose dependencies are all `done`. If no row qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`); never invent work.

## Inbox

Follow-ups, debt and ideas waiting for a planner session. Builders: add one line per item, `- (source) what, and why it matters`. Don't write task files for these unless your own task needs one. A planner session turns them into tasks, drops them with a reason, or escalates them. **Run a planner when this list has 5+ items.**

- (T-102) The PIN-pad shake and tile pulse use literal durations and ignore reduced motion. Move them to Theme tokens that honour `DeviceSettings.reducedMotion`.
- (T-102) Once, after adding a new C++ `QML_ELEMENT` type, the tests failed with "DeviceSettings is not defined" and passed on the next build (stale incremental registration). Investigate the CMake dependency between `tst_ruyashell` and the module's type registration; at least document the workaround. Happened again in T-108 (`Audio`); the workaround (build twice) is now in `shell/CLAUDE.md`.
- (T-108) `tst_system_ui.qml::test_toast_queue` failed once (final `verify(tiles.activeFocus)`) on a loaded machine right after a rebuild, then passed 8 times. If it recurs, make that check a `tryVerify` and find out why focus was late.
- (T-108) The volume-key `Shortcut`s are verified only in a QtQuickTest window on Windows; check them under the real compositor (B-003) with an app focused.
- (T-103) Key repeat acceleration and long-press (spec 4.3) are not implemented; holding Left/Right on a SliderRow steps at the OS repeat rate.
- (T-108) Stepping volume while muted does not unmute; decide the UX when T-114 builds the audio settings.

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

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-001 | Build the image, boot it in QEMU, run the update/rollback drill (01-platform §8 items 1–7) | Linux builder (WSL2 + Podman, a Linux VM, or CI with a GitHub remote) | `scripts/*.sh`, `docs/dev-setup.md`. Highest-value unblock. |
| B-002 | Install on a real low-tier machine; first frame-time numbers (§8 item 8) | Hardware + B-001 | |
| B-003 | Compositor spike: shell as QtWaylandCompositor, overlay over a running game (ADR-002) | Linux with a GPU | Decides the product architecture; do it as soon as Linux is available |
| B-004 | `ruya-store` Rust service over libflatpak/AppStream | Linux | Contract from T-110 |
| B-005 | Shell ↔ services over a real D-Bus (Profiles first) | Linux | Recipe in `docs/dev-setup.md` ("Against the real profiles service") |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), with grab/re-emit | Linux + controllers | |
| B-007 | `ruya-devices` service (PipeWire, NetworkManager, BlueZ) | Linux | Audio contract from T-114 |
| B-008 | Verify greenboot auto-rollback on bootc and the NVIDIA kmod build step | B-001 | Known risk: greenboot vs greenboot-rs packaging on the target Fedora |

## Open owner decisions

- **ADR-002** (compositor): recommendation A, pending spike B-003.
- **libdvdcss / AACS** (DVD/Blu-ray decryption): not included; needs an explicit owner decision.
- **Publishing:** no git remote yet. Pushing or creating a GitHub repo is the owner's call (it would unblock CI → B-001).

## Session log (newest first)

Each entry: date · model · tasks · what happened · verification · follow-ups. Keep entries short and factual.

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
