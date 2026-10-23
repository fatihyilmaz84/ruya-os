# RuyaOS — Status

**Read this first in every session; update it last.** The rules are in the root `CLAUDE.md`, the roles (Opus lead, Sonnet builders) in `docs/LEAD.md`, the task format in `docs/tasks/README.md`.

Last updated: 2026-10-24 (Sonnet 5.5, T-128)

## Where we are

- **Phase 0 (foundation):** **verified in a VM on 2026-10-22.** The image builds, passes lint, boots to the shell, updates, and rolls back both manually and automatically (greenboot). Only the real-hardware item is left (B-002).
- **Phase 1–2 (shell core, profiles):** in progress on the Windows host against mock services. Done: pages, motion, toasts/OSD, settings, on-screen keyboard, profile management, first-boot wizard, token lint. The repo is public on GitHub and CI (`lint`, `services`, `shell`, `image`) is green on `main` (T-122). Profiles, the wizard and Settings → Profiles are **vm-verified** over the real bus (T-120), and power actions (T-107) work in the VM. The sound path is **vm-verified** (T-121). `ruya-profiles` is hardened to exposure 1.6 (T-126). The audio contract and Settings → Audio are built against a mock (T-114); audio ownership is decided (ADR-010) and the `ruya-devices` audio service is T-128. The keyboard Guide key (Super) works (T-124, vm). The PIN pad shows a locked-out state (T-125, host). The shell is translated into Turkish with live switching (T-109, host). The compositor spike (T-123, lead) showed ADR-002 option A working in the VM: `ruya-shell` as the Wayland compositor on KMS, the Guide overlay over a running client, input returned on close; the owner accepted A as the product direction (performance on hardware later, B as the fallback); T-130 (lead) replaces cage next.
- **Host:** Windows, plus a Fedora 44 WSL distribution for image builds and QEMU/WHPX for boot tests (`docs/dev-setup.md`). Work that needs a GPU, controllers or real audio output still waits in the Blocked table. The VM can be driven by keys and screenshots, and given a sound card (`docs/dev-setup.md`).

Verification legend: **host** = built and tested on the Windows host · **vm** = built into the image and verified booted in QEMU · **unverified** = written, but not run · **hw** = verified on real hardware.

## Board

**NEXT → T-119**

**Lead review due: after 1 more builder task** (reviewed up to the lead commit of 2026-10-23 "lead review beafbc6..da2d1be", see `docs/LEAD-NOTES.md`). Builders: when your task makes this condition true, end your reply by recommending a lead session.

| ID | Title | Status | Depends | Verified |
|---|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage (ADR-002 A), app layer and key routing | todo | T-123 | |
| [T-127](tasks/T-127-shots-window-focus.md) | `dev.ps1 shots`: focus failures caused by the desktop say so, and recover | done | — | host |
| [T-128](tasks/T-128-devices-audio-service.md) | `ruya-devices`: audio part of `Devices1` over PipeWire, in the VM (ADR-010) | done | T-114, T-121 | vm |
| [T-119](tasks/T-119-nested-pages.md) | Page host: nested pages that keep their state | todo | T-101 | |
| [T-110](tasks/T-110-store-contract-and-mock.md) | Store contract and mock backend | todo | — | |
| [T-129](tasks/T-129-network-contract-and-settings.md) | Network: `Devices1` network contract, mock, Settings → Network | todo | T-114 | |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — | |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 | |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 | |

The order above is the recommended order. When the NEXT task is blocked, take the first `todo` row whose dependencies are all `done`. If no row qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`); never invent work.

## Inbox

Follow-ups, debt and ideas waiting for a planner session. Builders: add one line per item, `- (source) what, and why it matters`. Don't write task files for these unless your own task needs one. A planner session turns them into tasks, drops them with a reason, or escalates them. **Run a planner when this list has 5+ items.**

- (T-118) Settings -> Profiles UI for rename and delete (confirmation, admin PIN) has no task; the service and `Profiles` facade are ready.
- (T-118) `delete_profile`: if the store write fails after `userdel` succeeded, the profile stays listed without a Unix user; decide whether to reorder (save first) or reconcile on start.

- (T-128) Network/Bluetooth parts of `ruya-devices`, applying `ambient`/`media` levels to app streams, and an `Sfx` start-up deferral (QSoundEffect warnings) are open; B-007 tracks the first two.

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
| T-105 | Settings → Profiles: add profile, change/remove PIN; mock mirrors `service.rs`; PinPad collect modes | mock path: host (`dev.ps1 test` green, new `tst_profile_admin.qml` + screenshot reviewed) · D-Bus `CreateProfile`/`SetPin`: **vm** (T-120; the attempts probe was replaced in T-115) | T-105 |
| T-115 | Profiles1: `CreateProfile`/`SetPin` replies carry `attempts_left` and `retry_after_secs`; `SwitchTo` probe removed | service + adapter types: host (`dev.ps1 rust` green, 2 new tests) · shell mock path: host (`dev.ps1 test` green) · D-Bus reply parsing: **vm** (T-120: attempts left and retry time shown from `SwitchTo` and `CreateProfile` replies) | T-115 |
| T-106 | First-boot setup wizard (`Setup.qml`: welcome, language, network placeholder, create admin, done); `DeviceSettings.language`; `RUYA_MOCK_PROFILES=empty`; shared `ProfileStatus` messages | mock path: host (`dev.ps1 test` green, new `tst_setup.qml` with 8 tests + 2 screenshots reviewed) · real `ruya-profiles` over D-Bus: **vm** (T-120: wizard by keys creates the admin, profile and Unix user checked) | T-106 |
| T-121 | Audio in the VM: `smoke-test.ps1 -Audio` (HDA card; dsound or wav capture), `vm-audio-check.sh`, `vm-audio-bursts.py`; PipeWire, WirePlumber and pipewire-pulse run for `ruya-shell`, the HDA sink and the shell's stream are listed by `wpctl`, one recorded burst per UI cue | **vm** (recording analysed; the start-up `QSoundEffect` warning is explained, not removed) · how it sounds, real outputs, volume control reaching PipeWire: **unverified** | T-121 |
| T-122 | CI: token lint extracted to `scripts/lint-tokens.ps1` and run as a `lint` job; `permissions: contents: read`, cancelling `concurrency`, `workflow_dispatch`, timeouts; local-check-to-CI table in `dev-setup.md` | host (`dev.ps1 test` green, lint probe failed as expected) · GitHub run 39935813084: `lint`, `services`, `shell`, `image` all green | T-122 |
| T-120 | Profiles, wizard, lockout and Settings → Profiles verified in the VM over the real system bus; VM screenshot/keys scripts (QEMU monitor, guest-side uinput Guide key); closes B-005 | **vm** (39 screenshots, D-Bus and on-disk state pasted in the task Outcome); no shell, service or image change needed | T-120 |
| T-117 | Reduced motion honoured by the PIN-pad shake and tile pulse; literal durations/colours moved into `Theme` tokens; token lint in `dev.ps1 shell` | host (`dev.ps1 test` green, new test fails without the guard, lint failure demonstrated; 3 screenshots reviewed by eye) | T-117 |
| T-116 | First build after adding or removing a C++ QML type is green (stale `qmltyperegistrar` under the Visual Studio generator; build step `InvalidateStaleQmlTypes.cmake`) | host (`dev.ps1 test` green; 3 add/remove probe cycles via `scripts\repro-first-build.ps1`, all green on the first run) · Linux/Ninja: not run | T-116 |
| T-107 | Power actions: `Power` singleton (mock + logind D-Bus), Power page, `PowerConfirm`, Guide overlay power choices, Guide long-press; polkit rule for `ruya-shell`; `image/rootfs` installed with safe modes | mock path: host (`dev.ps1 test` green, new `tst_power.qml`, 2 screenshots reviewed) · polkit rule, logind `Can*` and `PowerOff` as `ruya-shell`, refusal for another user, `RUYA_BOOT_OK`: **vm** (`scripts/vm-power-check.sh`) · the running shell's Power off through logind, and the Guide long press: **vm** (T-120 session) · a real suspend/wake: **unverified** | T-107 |
| T-114 | Audio: `org.ruyaos.Devices1.Audio` contract; mock and D-Bus backends; Settings → Audio (outputs, master, UI/Ambient/Media, mute); hot-plug policy and "Audio output" toast; `Sfx` follows the UI channel; volume keys while muted | mock path: host (`dev.ps1 test` green, new `tst_audio.qml` with 11 tests, `22-settings-audio.png` reviewed) · `DBusAudioBackend` and the contract against a real service: **unverified** (no `ruya-devices` yet, B-007) | T-114 |
| T-124 | Keyboard Guide key: Super (left, right, Meta) opens/closes the overlay and its hold opens the power choices, one shared `isGuideKey` path; `Key_Menu` is no longer Guide; spec 02 4.2 fixed | host (`dev.ps1 test` green, 7 new test rows, `shots` green) · **vm** (image `0.0.6-t124`: `RUYA_BOOT_OK`, `vm-keys.ps1 meta_l` opens and closes the overlay, screenshots in the Outcome) · holding Super in the VM: unverified | T-124 |
| T-125 | PIN pad: locked-out state (`locked`: keys and digits dimmed with `Theme.disabledOpacity`, input ignored, countdown is the only message), screenshot `15-pin-locked.png` | host (`dev.ps1 test` green, extended `Lockout` test, `shots` green, screenshot reviewed) | T-125 |
| T-109 | Translations: `qt_add_translations` (en, tr), live switching through `DeviceSettings.language`, Settings -> System language row, Turkish on-screen keyboard, `--reverse` RTL check, translation lint | host (`dev.ps1 test` and `shots` green, `tst_i18n.qml` + `test_turkish_layout`, 3 screenshots reviewed) · **vm** (image `0.0.7-t109`: `RUYA_BOOT_OK`) · language switching in the VM: unverified | T-109 |
| T-126 | `ruya-profiles.service` hardened: minimal `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `UMask=0077`, `ProtectProc=invisible` and more; `vm-profiles-check.sh create` | **vm** (image `0.0.6-lead2`, fresh disk: `RUYA_BOOT_OK`, both profiles created over the bus, account file modes intact, exposure 6.0 → 1.6) · `userdel`: not exercised yet (T-118) | T-126 |
| T-123 | Compositor spike (ADR-002 A): `shell/spike/Compositor.qml` (shell as QtWaylandCompositor, Guide overlay over a client, key routing), `ruya-shell --load`, `ruya-compositor-spike@.service` (not enabled), `scripts/vm-compositor-spike.sh`, `.containerignore` | **vm** (image `0.0.8-t123`: `RUYA_BOOT_OK` with cage; spike: client fullscreen, overlay over it, keys to client / overlay / client again, client exit, back to cage; screenshots and log in the Outcome) · performance, real GPUs, Flatpak apps: **unverified** | T-123 |
| T-128 | `ruya-devices` audio service (`Devices1.Audio` over `pw-dump`/`wpctl`), user unit of `ruya-shell`, D-Bus policy, shell uses D-Bus by default on Linux, `vm-devices-check.sh` | host (`dev.ps1 test` green, 24 new Rust tests) · **vm** (image `0.0.10-t128`: `RUYA_BOOT_OK`, check script all pass, Settings -> Audio lists the HDA sink, Master slider moves `wpctl`, exposure 3.4) · hot-plug in the VM: unverified | T-128 |
| T-118 | Profiles1: `RenameProfile` and `DeleteProfile` (contract, service rules, `Accounts::remove` with `userdel --remove`, mock, shell backend and facade; no UI) | service + mock: host (`dev.ps1 rust` and `test` green, 6 service tests, `test_mock_lifecycle_rules_match_service`) · **vm** (image `0.0.9-t118`: `RUYA_BOOT_OK`, rename and delete over the bus, user and home removed, ids not reused; `userdel` needs no extra capability) · the shell's `DBusProfilesBackend` calls: **unverified** (compiled only) | T-118 |

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| ~~B-001~~ | **Done 2026-10-22 (vm).** Image built (lint clean, fatal warnings), booted to the shell, update 0.0.3→0.0.4, manual rollback, and greenboot automatic rollback from a broken image | — | Session log 2026-10-22 (Opus); recipe in `docs/dev-setup.md` |
| B-002 | Install on a real low-tier machine; first frame-time numbers (§8 item 8) | Hardware | A dev installer ISO now exists (`output/bootiso/`, contains the dev SSH key; for test machines only). Also decide there: a failed boot takes about 100 s (90 s greenboot check + 120 s VM marker), so automatic rollback takes about 7 minutes; consider a shorter required-check timeout once real boot times are known (spec 02 §8 KPI: shell < 15 s on the low tier). |
| B-003 | Compositor performance: the Guide overlay (blurred) over a running game at ≥ 55 FPS on the mid tier (ADR-002) | Hardware with a GPU | **Functional part done in the VM (T-123):** option A works. Left here: frame rates, dmabuf clients on a real GPU, blur over a client surface, gamescope nesting. Also check there: the volume-key `Shortcut`s (T-108) work with an app focused. |
| B-004 | `ruya-store` Rust service over libflatpak/AppStream | ~~Linux~~ nothing: WSL builds and the VM can run it now | Contract from T-110. **Becomes a task once T-110 lands** (VM-verified, like T-120). |
| ~~B-005~~ | **Done 2026-10-23 (vm).** Profiles, the first-boot wizard, lockout and Settings → Profiles work against the real `ruya-profiles` over the system bus (T-120) | — | Other services follow the same way once they exist; the VM drive scripts are in `docs/dev-setup.md` ("Seeing and driving the VM"). |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), with grab/re-emit | Linux + controllers | Also owns the key-repeat model (400 ms delay then accelerating repeat, stick repeat speed) and Accept long-press / context menu from spec 02 §4.3; the shell only sees key events. |
| B-007 | `ruya-devices` service (NetworkManager, BlueZ; the **audio part is done**, T-128) | ~~a design decision~~ decided: ADR-010 (lead, 2026-10-23) | Audio part is now **T-128** (one PipeWire in `ruya-shell`'s session; `ruya-devices` is a user unit of `ruya-shell`; it flips `Audio::create` to D-Bus on Linux and covers the `QSoundEffect` start-up warnings and `pipewire-utils`). Network contract and UI: T-129. Left here: the NetworkManager and BlueZ parts of the service, and exposing PipeWire to profile apps (`ruya-session`). |
| ~~B-008~~ | **Done 2026-10-22 (vm).** greenboot (0.16, Rust) works on bootc once its units are enabled: 4 failed boots of a broken image, then GRUB fell back. The NVIDIA 615.78 kmod builds and is signed in the image; the private key is removed | — | Loading on real NVIDIA hardware and Secure Boot/MOK are still unverified (needs hardware) |

## Open owner decisions

- **ADR-002** (compositor): **decided 2026-10-23 by the owner: option A** is the product direction; performance is confirmed later on hardware (B-003), with option B (gamescope + shell client) as the fallback. Follow-up: T-130 (lead).
- **Real hardware (B-002):** is a spare low-tier PC available to install the dev ISO on? It unblocks the Phase 0 hardware item, the first KPI numbers and later the ADR-002 performance check. Recommendation: yes, any x86-64 mini-PC with an Intel or AMD iGPU; it must be a test machine (the ISO has the dev SSH key).
- **libdvdcss / AACS** (DVD/Blu-ray decryption): not included; needs an explicit owner decision.
- **One admin or several?** `00-overview` §2 (MVP) says "one admin", `03` §1.1 says "Admin (one or more)". The service supports several; the UI offers only Standard and Guest when adding a profile (T-105). Options: (a) keep one admin in the UI for the MVP, as the overview says; (b) let an admin create more admins and fix the overview. Recommendation: (a), and revisit after the first user test. Not blocking: T-118 does not depend on it.
- **Turkish wording review:** the Turkish UI strings (`shell/i18n/ruyashell_tr.ts`, 140 messages, T-109) were written by an AI builder. Can you, or a native speaker you trust, review them before the first release (tone; terms such as "kontrolcüler", "askıya al")? Not blocking any task. Recommendation: review once the Settings panes settle (after T-129), so it's done once.
- **Publishing:** decided. The owner pushed `main` to https://github.com/fatihyilmaz84/ruya-os.git on 2026-10-23 (history scanned for secrets first; the dev SSH key in `image/bib/config.toml` is git-ignored). The repo is **public** (its Actions API answers without login) and carries `LICENSE.md` and `LICENSES/` per ADR-008. Later pushes still need the owner's go-ahead. At planning time, T-117 was committed locally but not pushed.

## Session log (newest first)

Each entry: date · model · tasks · what happened · verification · follow-ups. Keep entries short and factual.

- 2026-10-24 · Sonnet 5.5 · T-128 · `ruya-devices` audio service (core + `wpctl`/`pw-dump` + zbus), user unit, bus policy, shell D-Bus by default on Linux with a name watcher. `test` ALL GREEN; image `0.0.10-t128` `RUYA_BOOT_OK`; `vm-devices-check.sh` all pass; Settings -> Audio drives `wpctl` in the VM; exposure 3.4. Sfx deferral not done; hot-plug unverified. Lead review due after 1 more builder task.

- 2026-10-24 · Sonnet 5.5 · T-127 · `WindowGuard` in `tst_main.cpp`, called first in every `init()`: re-activates the test window or fails with a clear message; also logs `TEST WINDOW LOST ACTIVATION` and re-activates the moment focus goes. `test` ALL GREEN (133 passed, same count); `shots` green twice (144 passed), losses logged and recovered in both. One earlier run failed `Power::test_guide_short_press_opens_overlay` mid-test before the loss logging existed. Manual "click another window" check not done (**unverified**).

### 2026-10-23 · Sonnet 5.5 · T-118
Profiles1 rename and delete:
- `RenameProfile` (admin or self) and `DeleteProfile` (admin only; refuses the last admin and the active profile) in the contract, `service.rs`, `dbus.rs`, mock, `DBusProfilesBackend` and `Profiles`. `Accounts::remove` runs `userdel --remove` before the store changes; failure leaves the store alone. Ids are never reused; a deleted profile's lockout state is dropped.
- Known gap: if the store write fails after `userdel` succeeded, the profile is restored in memory but its Unix user is gone (see the Outcome).

Verification: `dev.ps1 rust` and `test` ALL GREEN (133 QML tests); image `0.0.9-t118` `RUYA_BOOT_OK`; `vm-profiles-check.sh lifecycle` output in the Outcome. Unverified: the shell's D-Bus client calls at runtime. No screenshots (no UI).

Follow-ups: UI for rename/delete needs a planning session (no task yet). NEXT is T-127. Lead review due after 3 more builder tasks.

### 2026-10-23 · Opus 5.5 · T-123 (lead task)
Compositor spike, ADR-002 option A, in the VM:
- `ruya-shell --load shell/spike/Compositor.qml` is a QtWaylandCompositor on KMS (eglfs, llvmpipe) hosting the unchanged `Shell`, client toplevels fullscreen above it, and the Shell's Guide overlay moved above the clients. A `Keys` handler on the client item takes Guide (Super, `KEY_HOMEPAGE`) before the client sees it.
- Image `0.0.8-t123`: `RUYA_BOOT_OK` with cage (the spike unit is not enabled). Then, via `scripts/vm-compositor-spike.sh`: keys reach the test client; Guide opens the overlay over it; keys while open don't reach it; closing returns them; client exit gives the shell back; `stop` restores cage and the device ACLs.
- Product-path findings in ADR-002: eglfs opens input devices itself (needs a `uaccess` rule or logind device opening; `input` is an altfiles group on bootc); llvmpipe clients must use shm; key routing should move to C++.
- Also: `.containerignore` (a podman `COPY shell` raced with a Windows build in `shell/build-win`).

Verification: `dev.ps1 test` ALL GREEN; VM screenshots and log in the T-123 Outcome. Unverified: performance, real GPUs, Flatpak clients, blur over a client.

Escalated: accept ADR-002 option A as the product direction. **The owner accepted it the same day** (performance on hardware later, option B as the fallback); the lead wrote **T-130** (compositor session replaces cage, `Owner: lead`).

### 2026-10-23 · Opus 5.5 · Lead
Lead review of `beafbc6..da2d1be` (T-114, T-124, T-125, T-109, the lead's worker-cost change), and planning.

Verification:
- `dev.ps1 test` ALL GREEN: Rust 23 tests, clippy both targets, 132 QML tests + 11 screenshot tests skipped offscreen.
- `dev.ps1 shots`: first run 141 passed, 2 failed (`Power::test_confirm_and_cancel`, `test_guide_short_press_opens_overlay`, both on `activeFocus`), re-run 143 passed. Third such desktop-focus failure in a day, each in a different test: now **T-127**. Reviewed `22-settings-audio`, `15-pin-locked`, `16-settings-tr`, `16b-keyboard-tr`: layout, focus ring and text fine (the Audio pane's Mute row is cut at the bottom until focused, which scrolls it in: acceptable).
- VM: not re-run by the lead. T-124 and T-109 booted their own images (`0.0.6-t124`, `0.0.7-t109`, `RUYA_BOOT_OK`); T-114 and T-125 changed no image file. CI not checked.

Review findings (1 fixed, 0 filed): contracts, mock and client agree (T-114); no test weakened; Outcomes honest.
- **Fixed:** the translation lint only caught `unfinished` entries, so a new `qsTr` string without an `lupdate` refresh would have shipped untranslated with every check green. `lint-translations.ps1 -LUpdateProject` (used by `dev.ps1`) now refreshes temporary copies from the sources first and also fails on `vanished`/`obsolete` entries; shown to fail on a probe, tracked files untouched. CI's `lint` job (no build) still checks the committed files only.
- **Fixed (docs):** `services/CLAUDE.md` still said image steps can't be built here; it now requires the VM check.

Decision: **ADR-010 audio ownership** (lead, Accepted): one PipeWire in `ruya-shell`'s session; profile apps get a socket to it via `ruya-session`; `ruya-devices` is a user unit of `ruya-shell`. Unblocks B-007's audio part.

Planning (Inbox 4 → 0): the two `shots` focus flakes → **T-127**; the RTL item → dropped as a task (no RTL language in the MVP), kept as a rule in `shell/CLAUDE.md` "RTL check"; the Turkish review → escalated (Open owner decisions). New: **T-128** `ruya-devices` audio service (VM-verified), **T-129** network contract, mock and Settings → Network. Queue: 10 `todo` + T-123 (lead), 7 ready now. NEXT stays T-118.

### 2026-10-23 · Opus 5.5 · Lead (worker cost)
The owner asked whether builder sessions need speed and token optimizations. From the transcripts of the last four sessions:
- Almost all cost is **cache reads of a growing context**: sessions that took several tasks in a row ended at 250k–470k tokens of context, and one 4-task session read 158M cached tokens, against 25M for a 2-task one. Wall time goes mostly to image builds and VM runs (required) and to waiting for approvals.
- Smaller items: `STATUS.md` was 44 KB and read whole by every builder (most of it old log); each full-HD screenshot Read stays in context for the rest of the session.

Changes: old log entries moved to `docs/STATUS-log.md` (STATUS now 23 KB; the lead keeps the newest five); `dev.ps1 shots` writes half-size review copies to `output\shell-shots\review\`, and builders review those; `CLAUDE.md` has a "Read lean" rule and says a fresh session per task is cheaper. Recommendation to the owner: start a new session for each task instead of "continue with next task".

Verification: `dev.ps1 test` ALL GREEN; `dev.ps1 shots` 131 passed and wrote 16 review copies (legible at 960×540). T-114 and T-124 (committed meanwhile) are not reviewed yet.

### 2026-10-23 · Sonnet 5.5 · T-109
Translations (en, tr) with live switching:
- `qt_add_translations` + `shell/i18n/*.ts` (140 messages, 0 unfinished, enforced by the new `scripts/lint-translations.ps1`); `DeviceSettings.language` installs the translator and calls `retranslate()`; Settings -> System has the Language row; the Turkish on-screen keyboard (ç ğ ı ö ş ü, Shift i -> İ); `--reverse` RTL check.
- Found and fixed: models carrying translated text reset `currentIndex` on a language change (Settings categories, home tiles); they now hold keys and the label is a binding (rule in `shell/CLAUDE.md`).
- Build dependency: `qt6-qttools-devel qt6-linguist` in CI, the image's shell stage and `dev-setup.md`.

Verification: `dev.ps1 test` ALL GREEN; `shots` green (the first run hit the known `Power` flake); 3 screenshots reviewed. Image `0.0.7-t109` built in WSL, `RUYA_BOOT_OK` (language switching in the VM unverified).

Follow-ups: two Inbox lines. NEXT is T-118. The lead review is due now.

### 2026-10-23 · Sonnet 5.5 · T-125
PIN-pad lockout state:
- `PinPad.locked` (`lockSecs > 0`): `press()` ignores digits, Del and OK while locked; the dots and all keys use the new `Theme.disabledOpacity` (0.4, also used by the OK key when too few digits); the message is only the countdown. When the timer reaches 0 the pad works again with no other action (focus never leaves the key grid). `open()` resets the countdown when a different profile opens (it belongs to the profile that was locked).
- Collect modes (Change PIN old PIN, admin PIN) close the pad before the service replies, so they cannot show a locked pad; their `locked-out` reply is reported by `ProfilesPane` with the countdown, as before. Nothing to change there.

Verification: `dev.ps1 test` ALL GREEN; `shots` green on the re-run (the first runs hit the known focus flakes, see Inbox); `15-pin-locked.png` reviewed.

Follow-ups: one Inbox line. NEXT is T-109 (T-123 is lead's). The lead review is due now.

Older entries: [`STATUS-log.md`](STATUS-log.md).
