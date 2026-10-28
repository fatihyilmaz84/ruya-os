# RuyaOS — session log archive

Older entries of the `docs/STATUS.md` session log, newest first. STATUS keeps only the latest five; the lead moves the rest here at each review. Nobody needs to read this file to start a task.

- 2026-10-24 · Opus 5.5 · Lead (disk space) · `build.sh` removes untagged images it did not use (WSL use 78 → 30 GB); `smoke-test.ps1 -Work` gives one shared `work.qcow2`; fixed a stale `RUYA_BOOT_OK` read when the old QEMU held `serial.log`. `.vhdx` shrink is an owner step (`dev-setup.md`).

### 2026-10-24 · Opus 5.5 · Lead
Lead review of `2aab79e..64b7e3f` (disk-space scripts, T-119, T-131, T-110), and planning.

Verification: `dev.ps1 test` ALL GREEN (152 QML passed, 12 skipped offscreen; Rust unchanged). `dev.ps1 shots` ALL GREEN (164; one `TEST WINDOW LOST ACTIVATION` logged and recovered by the guard); `24-profile-delete-confirm.png` reviewed: fine. VM: **not run**, the WSL disk is still marked as needing fsck (dmesg), so no image build was attempted. CI not checked (nothing pushed).

Review findings (0 fixed, 1 filed): no test weakened, contracts and the mock agree, Outcomes honest about the unverified VM criterion and D-Bus client. Note for T-134: `DBusStoreBackend::startJob` records the job id only when the reply is handled, so a `JobFinished` that is dispatched before the reply watcher fires would be dropped; check against the real service and, if seen, buffer unknown-job signals.

Planning: Inbox 2 (both WSL) became an owner decision (disk repair, blocks all image tasks). ADR-011 accepted: `ruya-store` drives the `flatpak` CLI, pure Rust. New **T-134** (store service in the VM). T-130 stays lead, waiting on the disk. NEXT stays T-129 (host only).

- 2026-10-24 · Sonnet 5.5 · T-119 · Nested pages: `pageStack` entries `{key, params}`, one slot with a live page per entry (replaces the `Loader`), lower pages hidden/disabled but kept, focus item restored on pop, `extraPages`, sign-out destroys all. `test` ALL GREEN (138), `shots` ALL GREEN (149, one earlier run lost desktop focus). No visual change. Lead review due after 3 more builder tasks.

### 2026-10-24 · Opus 5.5 · Lead
Lead review of `1e5ae5e..4b811c6` (T-123 lead, T-118, T-127, T-128), and planning.

Verification:
- `dev.ps1 test` ALL GREEN: Rust 53 tests (54 with the review test), clippy both targets; 133 QML tests + 11 screenshot tests skipped offscreen.
- `dev.ps1 shots`: 144 passed on the first run, no `TEST WINDOW LOST ACTIVATION`. No screen changed in the range (T-128's Settings -> Audio change is Linux-only and was checked by its builder in the VM), so no screenshot re-reviewed.
- VM: image `0.0.11-lead` (HEAD + the review fix), fresh disk: `RUYA_BOOT_OK`; `vm-profiles-check.sh create`, `lifecycle`, `state`: rename and delete over the bus, `ruya-p2` and its home removed, `profiles.toml` 0600, `next_id` kept. CI not checked (nothing pushed).

Review findings (1 fixed, 1 filed): contracts, mocks and clients agree; no test weakened; Outcomes honest (T-128 says plainly the `Sfx` deferral was not tried).
- **Fixed (`review:` T-118):** `DeleteProfile` ran `userdel` before saving the store, so a failed save left a listed profile without its Unix user (the gap T-118 recorded). Now the store is saved first and a failed `userdel` puts the profile back; new test `failing_store_write_keeps_the_unix_user` fails on the old order. Spec 03 §1.1 updated.
- **Filed:** `ruya-devices` starts `pw-dump` every second forever (idle CPU on a console) → **T-133** (event-driven, `pw-dump --monitor`).
- Checked and fine: T-128's user unit hardening (3.4), the policy (only `ruya-shell` owns and calls, root calls), `Type=simple` with the name requested in code; T-127's guard only changes the test host; T-123's spike rule is inert by default.

Planning (Inbox 3 → 0): T-118 UI → **T-131** (rename/delete in Settings → Profiles, with a VM criterion that exercises `DBusProfilesBackend` for the first time); T-118 delete order → fixed above; T-128's open items → network part **T-132** (`ruya-devices` over NetworkManager's D-Bus API, polkit rule, VM link up/down), Bluetooth and app-stream levels stay in B-007 (the latter needs `ruya-session`), the `Sfx` deferral dropped as a task (no warning in T-128's boot; it moves into T-130's hints because start-up order changes there). New **T-133** (above). Queue: 9 builder `todo` + T-130 (lead); 6 ready now. NEXT stays T-119. `ruya-store` (B-004) needs a lead design call first (libflatpak bindings vs the `flatpak` CLI), recorded in `LEAD-NOTES.md`.

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
