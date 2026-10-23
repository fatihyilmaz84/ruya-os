# RuyaOS — Status

**Read this first in every session; update it last.** The rules are in the root `CLAUDE.md`, the roles (Opus lead, Sonnet builders) in `docs/LEAD.md`, the task format in `docs/tasks/README.md`.

Last updated: 2026-10-23 (Sonnet 5.5, T-124)

## Where we are

- **Phase 0 (foundation):** **verified in a VM on 2026-10-22.** The image builds, passes lint, boots to the shell, updates, and rolls back both manually and automatically (greenboot). Only the real-hardware item is left (B-002).
- **Phase 1–2 (shell core, profiles):** in progress on the Windows host against mock services. Done: pages, motion, toasts/OSD, settings, on-screen keyboard, profile management, first-boot wizard, token lint. The repo is public on GitHub and CI (`lint`, `services`, `shell`, `image`) is green on `main` (T-122). Profiles, the wizard and Settings → Profiles are **vm-verified** over the real bus (T-120), and power actions (T-107) work in the VM. The sound path is **vm-verified** (T-121). `ruya-profiles` is hardened to exposure 1.6 (T-126). The audio contract and Settings → Audio are built against a mock (T-114; the `ruya-devices` service is B-007). The keyboard Guide key (Super) works (T-124, vm). Next: the PIN-pad lockout state (T-125), then the compositor spike (T-123, lead) for the Phase 1 exit criterion "overlay over a running app".
- **Host:** Windows, plus a Fedora 44 WSL distribution for image builds and QEMU/WHPX for boot tests (`docs/dev-setup.md`). Work that needs a GPU, controllers or real audio output still waits in the Blocked table. The VM can be driven by keys and screenshots, and given a sound card (`docs/dev-setup.md`).

Verification legend: **host** = built and tested on the Windows host · **vm** = built into the image and verified booted in QEMU · **unverified** = written, but not run · **hw** = verified on real hardware.

## Board

**NEXT → T-125**

**Lead review due:** after 1 more builder task (reviewed up to the lead commit of 2026-10-23, see `docs/LEAD-NOTES.md`). Builders: when your task makes this condition true, end your reply by recommending a lead session.

| ID | Title | Status | Depends | Verified |
|---|---|---|---|---|
| [T-125](tasks/T-125-pinpad-lockout-state.md) | PIN pad: a visible locked-out state | todo | — | |
| [T-123](tasks/T-123-compositor-spike.md) | **[lead]** Compositor spike in the VM: shell as QtWaylandCompositor, overlay over a client (ADR-002) | todo | — | |
| [T-109](tasks/T-109-translations.md) | Translations en/tr, live switching, Turkish keyboard layout | todo | T-103, T-106 | |
| [T-118](tasks/T-118-profile-rename-delete.md) | Profiles1: RenameProfile and DeleteProfile (contract, service, mock; no UI) | todo | T-115, T-126 | |
| [T-119](tasks/T-119-nested-pages.md) | Page host: nested pages that keep their state | todo | T-101 | |
| [T-110](tasks/T-110-store-contract-and-mock.md) | Store contract and mock backend | todo | — | |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 | |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — | |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 | |

The order above is the recommended order. When the NEXT task is blocked, take the first `todo` row whose dependencies are all `done`. If no row qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`); never invent work.

## Inbox

Follow-ups, debt and ideas waiting for a planner session. Builders: add one line per item, `- (source) what, and why it matters`. Don't write task files for these unless your own task needs one. A planner session turns them into tasks, drops them with a reason, or escalates them. **Run a planner when this list has 5+ items.**
- (T-114) `Power::test_guide_long_press` failed once in `dev.ps1 shots` (real window, 3.2 s timer) and passed on the re-run: a possible flake under window/focus load; if it recurs, look at how the test waits for the hold timer.

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
| T-126 | `ruya-profiles.service` hardened: minimal `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `UMask=0077`, `ProtectProc=invisible` and more; `vm-profiles-check.sh create` | **vm** (image `0.0.6-lead2`, fresh disk: `RUYA_BOOT_OK`, both profiles created over the bus, account file modes intact, exposure 6.0 → 1.6) · `userdel`: not exercised yet (T-118) | T-126 |

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| ~~B-001~~ | **Done 2026-10-22 (vm).** Image built (lint clean, fatal warnings), booted to the shell, update 0.0.3→0.0.4, manual rollback, and greenboot automatic rollback from a broken image | — | Session log 2026-10-22 (Opus); recipe in `docs/dev-setup.md` |
| B-002 | Install on a real low-tier machine; first frame-time numbers (§8 item 8) | Hardware | A dev installer ISO now exists (`output/bootiso/`, contains the dev SSH key; for test machines only). Also decide there: a failed boot takes about 100 s (90 s greenboot check + 120 s VM marker), so automatic rollback takes about 7 minutes; consider a shorter required-check timeout once real boot times are known (spec 02 §8 KPI: shell < 15 s on the low tier). |
| B-003 | Compositor spike: shell as QtWaylandCompositor, overlay over a running game (ADR-002) | Linux with a GPU | Decides the product architecture; do it as soon as Linux is available. Also check there: the volume-key `Shortcut`s (T-108) work with an app focused. |
| B-004 | `ruya-store` Rust service over libflatpak/AppStream | ~~Linux~~ nothing: WSL builds and the VM can run it now | Contract from T-110. **Becomes a task once T-110 lands** (VM-verified, like T-120). |
| ~~B-005~~ | **Done 2026-10-23 (vm).** Profiles, the first-boot wizard, lockout and Settings → Profiles work against the real `ruya-profiles` over the system bus (T-120) | — | Other services follow the same way once they exist; the VM drive scripts are in `docs/dev-setup.md` ("Seeing and driving the VM"). |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), with grab/re-emit | Linux + controllers | Also owns the key-repeat model (400 ms delay then accelerating repeat, stick repeat speed) and Accept long-press / context menu from spec 02 §4.3; the shell only sees key events. |
| B-007 | `ruya-devices` service (PipeWire, NetworkManager, BlueZ) | A design decision (lead), no longer Linux: the VM has PipeWire (T-121) | Audio contract from T-114. **Open design question:** PipeWire runs per user (today `ruya-shell`'s session); apps will run as profile users (`ruya-session`). Decide whose PipeWire owns the outputs (system-wide PipeWire, per-user with a shared sink, or a user service in the shell session) before writing the task. Contract: `api/dbus/org.ruyaos.Devices1.xml` (T-114); the shell's `Audio` defaults to the mock on every OS until the service exists, so **flip the default in `Audio::create` to D-Bus on Linux** (like `Profiles`) in the same task. Include then: defer `Sfx` loading until a sink exists (the start-up `QSoundEffect` warnings, T-121) and add `pipewire-utils` for debugging. |
| ~~B-008~~ | **Done 2026-10-22 (vm).** greenboot (0.16, Rust) works on bootc once its units are enabled: 4 failed boots of a broken image, then GRUB fell back. The NVIDIA 615.78 kmod builds and is signed in the image; the private key is removed | — | Loading on real NVIDIA hardware and Secure Boot/MOK are still unverified (needs hardware) |

## Open owner decisions

- **ADR-002** (compositor): recommendation A. The functional part of the spike is now T-123 (lead, in the VM); the performance part still needs hardware (B-003).
- **Real hardware (B-002):** is a spare low-tier PC available to install the dev ISO on? It unblocks the Phase 0 hardware item, the first KPI numbers and later the ADR-002 performance check. Recommendation: yes, any x86-64 mini-PC with an Intel or AMD iGPU; it must be a test machine (the ISO has the dev SSH key).
- **libdvdcss / AACS** (DVD/Blu-ray decryption): not included; needs an explicit owner decision.
- **One admin or several?** `00-overview` §2 (MVP) says "one admin", `03` §1.1 says "Admin (one or more)". The service supports several; the UI offers only Standard and Guest when adding a profile (T-105). Options: (a) keep one admin in the UI for the MVP, as the overview says; (b) let an admin create more admins and fix the overview. Recommendation: (a), and revisit after the first user test. Not blocking: T-118 does not depend on it.
- **Publishing:** decided. The owner pushed `main` to https://github.com/fatihyilmaz84/ruya-os.git on 2026-10-23 (history scanned for secrets first; the dev SSH key in `image/bib/config.toml` is git-ignored). The repo is **public** (its Actions API answers without login) and carries `LICENSE.md` and `LICENSES/` per ADR-008. Later pushes still need the owner's go-ahead. At planning time, T-117 was committed locally but not pushed.

## Session log (newest first)

Each entry: date · model · tasks · what happened · verification · follow-ups. Keep entries short and factual.

### 2026-10-23 · Opus 5.5 · Lead (worker cost)
The owner asked whether builder sessions need speed and token optimizations. From the transcripts of the last four sessions:
- Almost all cost is **cache reads of a growing context**: sessions that took several tasks in a row ended at 250k–470k tokens of context, and one 4-task session read 158M cached tokens, against 25M for a 2-task one. Wall time goes mostly to image builds and VM runs (required) and to waiting for approvals.
- Smaller items: `STATUS.md` was 44 KB and read whole by every builder (most of it old log); each full-HD screenshot Read stays in context for the rest of the session.

Changes: old log entries moved to `docs/STATUS-log.md` (STATUS now 23 KB; the lead keeps the newest five); `dev.ps1 shots` writes half-size review copies to `output\shell-shots\review\`, and builders review those; `CLAUDE.md` has a "Read lean" rule and says a fresh session per task is cheaper. Recommendation to the owner: start a new session for each task instead of "continue with next task".

Verification: `dev.ps1 test` ALL GREEN; `dev.ps1 shots` 131 passed and wrote 16 review copies (legible at 960×540). T-114 and T-124 (committed meanwhile) are not reviewed yet.

### 2026-10-23 · Sonnet 5.5 · T-124
Keyboard Guide key:
- `Shell.isGuideKey` (`HomePage`, `Super_L`, `Super_R`, `Meta`) feeds the one Guide code path: open on press, hold for the power choices, close from the overlay. `Key_Menu` stopped being Guide (it was a stand-in from the first scaffold; nothing depended on it); spec 02 4.2 now says Super.

Verification: `dev.ps1 test` ALL GREEN (7 new test rows), `shots` green. Image `0.0.6-t124` built in WSL, `RUYA_BOOT_OK`; in the VM `meta_l` opened and closed the overlay (screenshots `output/vm-shots/t124-*.png`). Unverified: holding Super in the VM, the Windows key on the host.

Follow-ups: none. NEXT is T-125. The lead review is due after 1 more builder task.

### 2026-10-23 · Sonnet 5.5 · T-114
Audio contract and Settings → Audio:
- `api/dbus/org.ruyaos.Devices1.xml` (interface `org.ruyaos.Devices1.Audio`: `ListSinks`, `SetDefaultSink`, `SetChannelVolume`, `MasterVolume`, `Muted`, `ChannelVolumes`, two signals); shell `Audio` extended over a mock (HDMI + Analog, hot-plug policy of 03 §2.3) and a new D-Bus client; `AudioPane.qml`; "Audio output: <name>" toast; `Sfx` volume follows the UI channel; Volume Up unmutes, Volume Down stays muted.
- The Volume OSD now reacts to master changes only (a channel slider must not show it).
- `Audio` defaults to the mock on Linux too, because `ruya-devices` does not exist (B-007 says to flip it with the service).

Verification: `dev.ps1 test` ALL GREEN (11 new tests in `tst_audio.qml`); `dev.ps1 shots` green on the second run (the first had one red timer-based `Power::test_guide_long_press`, unrelated; Inbox line), `22-settings-audio.png` reviewed. Unverified: the D-Bus client against a service, PipeWire, how the cues sound.

Follow-ups: one Inbox line. NEXT is T-124. The lead review is due after 2 more builder tasks.

### 2026-10-23 · Opus 5.5 · Lead
Lead review of `9ca4b25..c06c77a` (T-115, T-116, T-106, T-117, T-122, T-107, T-120, T-121, two Sonnet plannings, the lead's image work), planning, and T-126.

Verification:
- `dev.ps1 test` ALL GREEN: Rust 23 tests, clippy Windows + Linux, 101 QML tests + 9 screenshot tests skipped offscreen; `dev.ps1 shots` 110 passed, screenshots of the changed screens reviewed (setup welcome and admin, power confirm, power choices, Guide overlay).
- Image `0.0.6-lead1` from HEAD: lint clean, `RUYA_BOOT_OK`; profile creation over the real bus works.
- Secret scan of all 31 commits: no private keys, tokens or the dev public key; `image/bib/config.toml` never committed (git-ignored); only placeholders in `config.toml.example`.
- CI: not checked this session (last known run 39935813084 green; this commit adds a `lint` step that has not run on GitHub yet).

Review findings (2 fixed, 0 filed):
- **Fixed:** `dev-setup.md` "Audio in the VM" (T-121) had backslash escapes turned into control characters (`\v`, a tab, `\r`) in six commands; repaired. This is the second byte-corruption on `main` (after T-107's cp1252), so per `LEAD.md` it became an automated check: `scripts/lint-text.ps1` (invalid UTF-8, control characters, tabs) runs first in `dev.ps1 test` and in the CI `lint` job; shown to fail on probes. The two `CLAUDE.md` pitfalls were merged into one.
- **Fixed:** `dev.ps1 shots` left screenshots that no test writes any more (four stale PNGs from T-101/T-103); it now clears the folder first.
- Otherwise the range is sound: contracts, service, mock and client agree (T-115); no test weakened; T-107's polkit rule is narrow (one user, six action ids, no `-ignore-inhibit`) and its builder found and fixed a real hole (every `rootfs` file was 0777 in the image).

Planning (Inbox 4 → 0):
- Keyboard Guide → **T-124** (lead decision recorded there: the shell maps keyboard keys; Super, not Home, which spec 02 also gives to fast scroll).
- PIN pad while locked out → **T-125**.
- `ruya-profiles` exposure 6.0 → **T-126**, done by the lead this session.
- `QSoundEffect` start-up race and `pipewire-utils` → moved to blocker **B-007**, which now waits on a lead design decision (whose PipeWire owns the outputs once apps run as profile users) instead of on "Linux".
- New **T-123 [lead]**: ADR-002 compositor spike, functional part in the VM.
- B-004 (`ruya-store` service) is no longer blocked by the host; it becomes a task after T-110.
- New lesson in `PLANNING.md`: service-facing tasks get a VM acceptance criterion; T-118 got one.
Queue: 11 `todo` tasks, 9 ready now. NEXT stays T-114.

T-126 (lead task): see its row in Done and its Outcome. Image `0.0.6-lead2`: `RUYA_BOOT_OK`, exposure 6.0 → 1.6.

Escalated: real hardware (B-002), in Open owner decisions.

### 2026-10-23 · Sonnet 5.5 · T-121
Audio in the VM:
- `smoke-test.ps1 -Audio [-AudioBackend dsound|wav]` adds an HDA card; `vm-audio-check.sh` (guest) and `vm-audio-bursts.py` (host, analyses the recorded wav).
- PipeWire, WirePlumber and pipewire-pulse run for `ruya-shell` with no image change; `wpctl` lists the HDA sink and the shell's stream; the recording shows one burst per cue (select 120 ms, navigate 45 ms, back 110 ms).
- The three `QSoundEffect ... not supported` lines at the first start are a race with WirePlumber (absent when the shell restarts in the same session); a mono-to-stereo cue test did not change them and was reverted.
- Found and fixed: three lone `0xA7` bytes (`§` written as cp1252 by my T-107 Python edit) had reached `main` in two specs and `Shell.qml`; repaired, pitfall added to `CLAUDE.md`.

Verification: `dev.ps1 test` ALL GREEN; VM `RUYA_BOOT_OK` with and without `-Audio`. Unverified: how it sounds, real outputs, volume control into PipeWire (T-114).

Follow-ups: one Inbox line. NEXT is T-114. The lead review is due; the Inbox has 4 items.

### 2026-10-23 · Sonnet 5.5 · T-120
Profiles and the wizard in the VM, over the real bus:
- New scripts: QEMU monitor port on `smoke-test.ps1`/`run-vm.ps1`; `vm-screenshot.ps1`, `vm-keys.ps1`, `vm-lib.ps1`; guest-side `vm-inject-key.py` (uinput `KEY_HOMEPAGE`, with hold) and `vm-profiles-check.sh`.
- Driven by keys in the T-107 image on a persistent disk: wizard (name via the physical keyboard path, PIN twice) → admin created (D-Bus listing, `profiles.toml` 0600 with a hash only, Unix user and home) → reboot → picker → wrong PINs (attempts left) → lockout (retry time) → sign-in → Settings → Profiles: add profile (with a wrong admin PIN first: attempts left from `CreateProfile`), change PIN, remove PIN, each confirmed over D-Bus.
- Also verified the T-107 hops that were open: a 3.2 s Guide hold opens the power choices, and Power off → Confirm made QEMU exit.
- Nothing needed fixing. Findings in the Inbox: keyboard Guide mapping, PIN pad feedback while locked, `ruya-profiles` exposure 6.0 MEDIUM.

Verification: **vm** (screenshots reviewed; no code changed, so no new host test). B-005 closed; T-105/T-106/T-115 D-Bus notes now **vm**.

Follow-ups: three Inbox lines. NEXT is T-121 (audio in the VM). The lead review is due.

Later the same day, after the owner approved the push (history scanned for secrets first): `main` pushed (`de6112e..c63590e`), and the first run of the new workflow, [39935813084](https://github.com/fatihyilmaz84/ruya-os/actions/runs/39935813084), was green in all four jobs (`image` 14 min), so **T-122 is closed**. `688b613` (T-120) is committed but not pushed yet.

Older entries: [`STATUS-log.md`](STATUS-log.md).
