# RuyaOS — Status

**Read this first in every session; update it last.** The rules are in the root `CLAUDE.md`, the roles (Opus lead, Sonnet builders) in `docs/LEAD.md`, the task format in `docs/tasks/README.md`.

Last updated: 2026-10-24 (Opus 5.5, lead; T-129)

## Where we are

- **Phase 0 (foundation):** **verified in a VM on 2026-10-22.** The image builds, passes lint, boots to the shell, updates, and rolls back both manually and automatically (greenboot). Only the real-hardware item is left (B-002).
- **Phase 1–2 (shell core, profiles):** in progress on the Windows host against mock services. Done: pages, motion, toasts/OSD, settings, on-screen keyboard, profile management, first-boot wizard, token lint. The repo is public on GitHub and CI (`lint`, `services`, `shell`, `image`) is green on `main` (T-122). Profiles, the wizard and Settings → Profiles are **vm-verified** over the real bus (T-120), and power actions (T-107) work in the VM. The sound path is **vm-verified** (T-121). `ruya-profiles` is hardened to exposure 1.6 (T-126). The audio contract and Settings → Audio are built against a mock (T-114); audio ownership is decided (ADR-010) and the `ruya-devices` audio service is T-128. The keyboard Guide key (Super) works (T-124, vm). The PIN pad shows a locked-out state (T-125, host). The shell is translated into Turkish with live switching (T-109, host). The compositor spike (T-123, lead) showed ADR-002 option A working in the VM: `ruya-shell` as the Wayland compositor on KMS, the Guide overlay over a running client, input returned on close; the owner accepted A as the product direction (performance on hardware later, B as the fallback); T-130 (lead) replaces cage next.
- **Host:** Windows, plus a Fedora 44 WSL distribution for image builds and QEMU/WHPX for boot tests (`docs/dev-setup.md`). Work that needs a GPU, controllers or real audio output still waits in the Blocked table. The VM can be driven by keys and screenshots, and given a sound card (`docs/dev-setup.md`).

Verification legend: **host** = built and tested on the Windows host · **vm** = built into the image and verified booted in QEMU · **unverified** = written, but not run · **hw** = verified on real hardware.

## Board

**NEXT → T-112**

**Lead review due: after 2 more builder tasks** (reviewed up to the lead commit of 2026-10-24 "lead review 2aab79e..64b7e3f", see `docs/LEAD-NOTES.md`). Builders: when your task makes this condition true, end your reply by recommending a lead session.

| ID | Title | Status | Depends | Verified |
|---|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage (ADR-002 A), app layer and key routing | todo | T-123 | |
| [T-110](tasks/T-110-store-contract-and-mock.md) | Store contract and mock backend | done | — | host (D-Bus client **unverified**) |
| [T-129](tasks/T-129-network-contract-and-settings.md) | Network: `Devices1` network contract, mock, Settings → Network | done | T-114 | host (D-Bus client **unverified**) |
| [T-132](tasks/T-132-devices-network-service.md) | `ruya-devices`: network part over NetworkManager, in the VM | todo | T-129, T-128 | |
| [T-133](tasks/T-133-devices-pipewire-events.md) | `ruya-devices`: follow PipeWire by events, no 1 s poll | todo | T-128 | |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — | |
| [T-134](tasks/T-134-store-service-core.md) | `ruya-store` service over the `flatpak` CLI, in the VM (needs the WSL disk repaired) | todo | T-110 | |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 | |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 | |

The order above is the recommended order. When the NEXT task is blocked, take the first `todo` row whose dependencies are all `done`. If no row qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`); never invent work.

## Inbox

Follow-ups, debt and ideas waiting for a planner session. Builders: add one line per item, `- (source) what, and why it matters`. Don't write task files for these unless your own task needs one. A planner session turns them into tasks, drops them with a reason, or escalates them. **Run a planner when this list has 5+ items.**

- (T-131) **WSL disk corruption blocks image builds and VM checks.** The Fedora WSL `ext4` disk logs `ext4_dirblock_csum_verify` / `Directory block failed checksum` (inodes under `depmod`) and remounts read-only during `build.sh` (nvidia-kmod step); `wsl --shutdown` helps only until the next build. Needs an owner-approved `e2fsck` repair (or a fresh Fedora 44 WSL distro and `dnf install podman git qemu-img`) before any image task can be verified.
- (T-131) VM criterion of T-131 is **unverified**: rename and delete through the running shell with `vm-keys.ps1`, then `vm-profiles-check.sh state`; first runtime check of `DBusProfilesBackend::renameProfile/deleteProfile`. Redo after the WSL disk is repaired.

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
| T-127 | `dev.ps1 shots`: `WindowGuard` in the test host re-activates the test window before each test and logs `TEST WINDOW LOST ACTIVATION` when the desktop takes focus | host (`test` and `shots` green; lead `shots` 144 passed, no loss) · manual click-away: unverified | T-127 |
| T-118 | Profiles1: `RenameProfile` and `DeleteProfile` (contract, service rules, `Accounts::remove` with `userdel --remove`, mock, shell backend and facade; no UI) | service + mock: host (`dev.ps1 rust` and `test` green, 6 service tests, `test_mock_lifecycle_rules_match_service`) · **vm** (image `0.0.9-t118`: `RUYA_BOOT_OK`, rename and delete over the bus, user and home removed, ids not reused; `userdel` needs no extra capability) · the shell's `DBusProfilesBackend` calls: **unverified** (compiled only) | T-118 |
| T-119 | Page host: one live page item per stack entry, `openPage(key, params)`, `currentParams`, `Shell.extraPages`; lower pages keep state and focus | host (`dev.ps1 test` and `shots` green, 5 new tests in `tst_pages.qml`) | T-119 |
| T-129 | `Devices1.Network` contract, `Network` singleton (mock + D-Bus client), Settings → Network (join WPA/open, wrong password, enterprise refused, cable status, forget, rescan) | host (`test` 164 and `shots` 177 green, new `tst_network.qml`, `23-settings-network.png` reviewed) · D-Bus client: **unverified** (no service, T-132) | T-129 |
| T-131 | Settings → Profiles: rename and delete (action rows, `ProfileManageFlow`, delete confirm reusing `PowerConfirm`) | host (`test` and `shots` green, 6 new tests in `tst_profile_admin.qml`); **VM criterion unverified** (WSL disk corrupt, see Inbox) | T-131 |

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| ~~B-001~~ | **Done 2026-10-22 (vm).** Image built (lint clean, fatal warnings), booted to the shell, update 0.0.3→0.0.4, manual rollback, and greenboot automatic rollback from a broken image | — | Session log 2026-10-22 (Opus); recipe in `docs/dev-setup.md` |
| B-002 | Install on a real low-tier machine; first frame-time numbers (§8 item 8) | Hardware | A dev installer ISO now exists (`output/bootiso/`, contains the dev SSH key; for test machines only). Also decide there: a failed boot takes about 100 s (90 s greenboot check + 120 s VM marker), so automatic rollback takes about 7 minutes; consider a shorter required-check timeout once real boot times are known (spec 02 §8 KPI: shell < 15 s on the low tier). |
| B-003 | Compositor performance: the Guide overlay (blurred) over a running game at ≥ 55 FPS on the mid tier (ADR-002) | Hardware with a GPU | **Functional part done in the VM (T-123):** option A works. Left here: frame rates, dmabuf clients on a real GPU, blur over a client surface, gamescope nesting. Also check there: the volume-key `Shortcut`s (T-108) work with an app focused. |
| B-004 | `ruya-store` Rust service over libflatpak/AppStream | ~~Linux~~ nothing: WSL builds and the VM can run it now | Contract from T-110. **Becomes a task once T-110 lands** (VM-verified, like T-120). |
| ~~B-005~~ | **Done 2026-10-23 (vm).** Profiles, the first-boot wizard, lockout and Settings → Profiles work against the real `ruya-profiles` over the system bus (T-120) | — | Other services follow the same way once they exist; the VM drive scripts are in `docs/dev-setup.md` ("Seeing and driving the VM"). |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), with grab/re-emit | Linux + controllers | Also owns the key-repeat model (400 ms delay then accelerating repeat, stick repeat speed) and Accept long-press / context menu from spec 02 §4.3; the shell only sees key events. |
| B-007 | `ruya-devices` service (NetworkManager, BlueZ; the **audio part is done**, T-128) | ~~a design decision~~ decided: ADR-010 (lead, 2026-10-23) | Audio part is now **T-128** (one PipeWire in `ruya-shell`'s session; `ruya-devices` is a user unit of `ruya-shell`; it flips `Audio::create` to D-Bus on Linux and covers the `QSoundEffect` start-up warnings and `pipewire-utils`). Network contract and UI: T-129; the NetworkManager part: T-132. Left here: the BlueZ part, applying `ambient`/`media` levels to app streams, and exposing PipeWire to profile apps (the last two need `ruya-session`, after T-130). |
| ~~B-008~~ | **Done 2026-10-22 (vm).** greenboot (0.16, Rust) works on bootc once its units are enabled: 4 failed boots of a broken image, then GRUB fell back. The NVIDIA 615.78 kmod builds and is signed in the image; the private key is removed | — | Loading on real NVIDIA hardware and Secure Boot/MOK are still unverified (needs hardware) |

## Open owner decisions

- **WSL ext4 corrupts on this host, even on a fresh distro (blocks every image/VM task: T-130, T-131 VM check, T-132, T-133, T-134):** on 2026-10-24 the lead unregistered the distro and recreated it (fresh `FedoraLinux-44`, `podman git qemu-img`, sparse VHD); 18 minutes into the first `build.sh` the new filesystem logged `ext4_lookup: iget: checksum invalid`, aborted its journal and went read-only (podman storage). So the cause is not the old disk image: suspects are the host's RAM (`.wslconfig` gives WSL 20 GB; a memory test or lowering it, or removing XMP/EXPO) or the SSD holding the VHD on C: (Windows logs repeated `disk` hardware errors at logical block 0x0 for disk 3 since 15:47, both SSDs report Healthy). Owner steps to try, in order: (1) run Windows Memory Diagnostic or memtest86; (2) `memory=8GB` in `.wslconfig` and `nestedVirtualization` off, rebuild; (3) move the distro's VHD to the other SSD (`wsl --export`/`--import` with a path on that drive; D: has about 67 GB free, a build needs about 40 GB). Host-only tasks continue.

- **ADR-002** (compositor): **decided 2026-10-23 by the owner: option A** is the product direction; performance is confirmed later on hardware (B-003), with option B (gamescope + shell client) as the fallback. Follow-up: T-130 (lead).
- **Real hardware (B-002):** is a spare low-tier PC available to install the dev ISO on? It unblocks the Phase 0 hardware item, the first KPI numbers and later the ADR-002 performance check. Recommendation: yes, any x86-64 mini-PC with an Intel or AMD iGPU; it must be a test machine (the ISO has the dev SSH key).
- **libdvdcss / AACS** (DVD/Blu-ray decryption): not included; needs an explicit owner decision.
- **One admin or several?** `00-overview` §2 (MVP) says "one admin", `03` §1.1 says "Admin (one or more)". The service supports several; the UI offers only Standard and Guest when adding a profile (T-105). Options: (a) keep one admin in the UI for the MVP, as the overview says; (b) let an admin create more admins and fix the overview. Recommendation: (a), and revisit after the first user test. Not blocking: T-118 does not depend on it.
- **Turkish wording review:** the Turkish UI strings (`shell/i18n/ruyashell_tr.ts`, 140 messages, T-109) were written by an AI builder. Can you, or a native speaker you trust, review them before the first release (tone; terms such as "kontrolcüler", "askıya al")? Not blocking any task. Recommendation: review once the Settings panes settle (after T-129), so it's done once.
- **Publishing:** decided. The owner pushed `main` to https://github.com/fatihyilmaz84/ruya-os.git on 2026-10-23 (history scanned for secrets first; the dev SSH key in `image/bib/config.toml` is git-ignored). The repo is **public** (its Actions API answers without login) and carries `LICENSE.md` and `LICENSES/` per ADR-008. Later pushes still need the owner's go-ahead. At planning time, T-117 was committed locally but not pushed.

## Session log (newest first)


Each entry: date · model · tasks · what happened · verification · follow-ups. Keep entries short and factual.
- 2026-10-24 · Sonnet 5.5 · T-110 · `org.ruyaos.Store1` contract (all §4.3 methods, `(status, job)` replies, job signals), `Store` singleton with mock (12 apps, simulated installs, `RUYA_MOCK_FAST`) and D-Bus client, 7 new tests. `test` ALL GREEN (152). D-Bus client unverified (B-004 service not built). Lead review due after 1 more builder task.

- 2026-10-24 · Sonnet 5.5 · T-131 · Rename and delete in Settings → Profiles: Accept on a row shows Rename/Delete rows; `ProfileManageFlow` (name entry or confirm, then PIN, then service); `PowerConfirm` got a custom-title mode; focus follows the list update. `test` ALL GREEN (144), `shots` ALL GREEN (156), `24-profile-delete-confirm.png` reviewed. **VM criterion not run:** three image builds died when the WSL ext4 disk went read-only (checksum errors); logged in the Inbox. Lead review due after 2 more builder tasks.

- 2026-10-24 · Sonnet 5.5 · T-119 · Nested pages: `pageStack` entries `{key, params}`, one slot with a live page per entry (replaces the `Loader`), lower pages hidden/disabled but kept, focus item restored on pop, `extraPages`, sign-out destroys all. `test` ALL GREEN (138), `shots` ALL GREEN (149, one earlier run lost desktop focus). No visual change. Lead review due after 3 more builder tasks.

- 2026-10-24 · Opus 5.5 · Lead (disk space, owner report) · Every image build left the previous image untagged (WSL: 163 images, 70 GB reclaimable, `ext4.vhdx` 88 GB on C:) and every task made its own `tNNN.qcow2` (21 GB on D:). `build.sh` now removes untagged images its build did not use (one run: 29 removed, WSL use 78 → 30 GB, cache kept); `smoke-test.ps1 -Work` gives one shared persistent `work.qcow2` and warns about other copies; `dev-setup.md` and `image/CLAUDE.md` say so. Also fixed: `smoke-test.ps1` could report the previous run's `RUYA_BOOT_OK` when the old QEMU still held `serial.log` (seen once with `-TimeoutSec 5`). Verified: `-Work` fresh and reuse boots `RUYA_BOOT_OK`, 5 s timeout now fails. The `.vhdx` does not shrink by itself (owner step in `dev-setup.md`).

- 2026-10-24 · Opus 5.5 · T-129 (done by the lead as host-only work while the WSL disk is unrepaired) · Network contract, mock, D-Bus client and Settings → Network. `test` ALL GREEN (164), `shots` ALL GREEN (177). D-Bus client unverified. Settings test updated: Network is no longer the "Coming soon" example.

### 2026-10-24 · Opus 5.5 · Lead
Lead review of `2aab79e..64b7e3f` (disk-space scripts, T-119, T-131, T-110), and planning.

Verification: `dev.ps1 test` ALL GREEN (152 QML passed, 12 skipped offscreen; Rust unchanged). `dev.ps1 shots` ALL GREEN (164; one `TEST WINDOW LOST ACTIVATION` logged and recovered by the guard); `24-profile-delete-confirm.png` reviewed: fine. VM: **not run**, the WSL disk is still marked as needing fsck (dmesg), so no image build was attempted. CI not checked (nothing pushed).

Review findings (0 fixed, 1 filed): no test weakened, contracts and the mock agree, Outcomes honest about the unverified VM criterion and D-Bus client. Note for T-134: `DBusStoreBackend::startJob` records the job id only when the reply is handled, so a `JobFinished` that is dispatched before the reply watcher fires would be dropped; check against the real service and, if seen, buffer unknown-job signals.

Planning: Inbox 2 (both WSL) became an owner decision (disk repair, blocks all image tasks). ADR-011 accepted: `ruya-store` drives the `flatpak` CLI, pure Rust. New **T-134** (store service in the VM). T-130 stays lead, waiting on the disk. NEXT stays T-129 (host only).

Older entries: [`STATUS-log.md`](STATUS-log.md).
