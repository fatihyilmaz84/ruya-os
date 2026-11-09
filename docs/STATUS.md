# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines, the long form of owner decisions and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-08 (Sonnet 5.5, planning)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1-2 (shell core, profiles, devices):** pages, Settings, keyboard, first-boot wizard, Turkish, themes, glass, sounds, power saving, boot experience; **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, Guide key, launching apps, display, usage, Bluetooth. **The shell is the compositor (T-130).**
- **Not started:** per-profile Wayland sockets (T-164: an app's window appears in the shell; Play does nothing yet), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-358** ([lead], GPU buffers for games: STK renders in software, T-355 first pass); then T-355's second pass on the Dell. **Builder lanes**: the first rows of `STATUS-backlog.md` in order (T-347, T-348, ...); one "VM (this task)" at a time. T-283, T-284, T-287, T-288 wait for the lead's design pass T-282.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents (at most two at a time, own worktrees, different areas), has each branch reviewed by `ruya-reviewer` and merges it (`docs/LEAD.md`). Dispatched builders never edit this file; one "VM (this task)" runs at a time. A builder the owner starts directly takes NEXT alone in the main checkout and does the bookkeeping (`CLAUDE.md`).

Open work only (the front of the board; the rest is in `STATUS-backlog.md`), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-358](tasks/T-358-compositor-linux-dmabuf-gpu-buffers.md) | **[lead]** The compositor gives apps GPU buffers: linux-dmabuf-v1 | in-progress | T-164 |
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | in-progress | — |
| [T-282](tasks/T-282-design-decisions-contrast-themes-dialogs.md) | **[lead]** Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery | todo | — |
| [T-261](tasks/T-261-controller-families-and-drivers-audit.md) | **[lead]** Controller families and drivers audit (DualSense, Xbox, 8BitDo, Switch), detection table, hardware checklist | todo | — |

Later (ordered): [`STATUS-backlog.md`](STATUS-backlog.md) holds the rest of the open board, same columns; `lint-board.ps1` reads both. A planner or the lead moves rows up when they become ready.

**VM queue** (one image build runs them all; history in `STATUS-parked.md`): **0.0.57 passed on 2026-11-09** (lead-6, image-chain 10 + 17 min; T-164 `vm-session-check.sh display` 30 PASS and `check` 38 PASS; the Dell runs 0.0.57). Left for the next build: T-322 `vm-audio-check.sh` (section T-322, `AUDIO_SAVED_OUTPUT_OK`), `vm-storage-check.ps1` step `scan` (T-331), `vm-devices-check.sh twopads|inputd|bluetooth` (T-334..T-337), `vm-devices-check.sh system` with a FAT stick (T-226), `subset-icons.sh` in WSL (T-297), the sample re-run, the greenboot drill.

**Dell look-at list** (one pass with the next ISO; the long text with task ids is in `STATUS-parked.md`, "Moved from STATUS 2026-11-08"):

- *Boot:* Esc at power-on, the splash-to-shell gap, no text before the shell, `bootloader-update` status (T-269, T-280, T-299).
- *Screen:* DPMS wake time and a clean wake (virtio-gpu logged 3 `Could not queue DRM page flip` right after the wake key), display modes with `display-capture.sh` and an unsupported mode that reverts (T-198), a DisplayPort cable for 1440p144, frame times with glide, liquid pill, backdrop, halo and picture mask and the 30 s idle pause (T-204, T-205, T-281), five themes, a 4K wallpaper copy from a real stick (T-208), the rounded corners on the real GPU (T-323), the gear cog (T-206).
- *Sound (image 0.0.55 or newer):* the ambient bed audible on the small speaker (T-330) and ducking under cues; Settings > Audio sliders and "Sound theme"; first-start volume and which sink is the default after a reboot (T-322). Silent? The probe commands are in `STATUS-parked.md`.
- *Pads:* T-203 checks 1-3 (cold boot with the bonded pad; bond-less pairing with PS + Create; a phone in pairing mode is never left bonded), a second pad beside the first and why pad 2 dropped after 21 s (T-338), DualSense disconnect/reconnect (T-202), a B press in the first second after wake is swallowed (T-293), controller-only play counts past 10 min (T-247), icons, toasts, Rename/Forget, 8BitDo (T-199, T-223, T-260).
- *Settings:* My profile and Manage profiles (T-324). *Fixtures to capture:* `/sys/class/hwmon` and `thermal_zone` (T-200), `ruya-sysinfo --example dump` against `lscpu`/`free`/`lspci` (T-226).

## Inbox

One line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

- (T-336 reviews, lead-5) Secure Pairable/Discoverable of an adapter that appears after the service started; stop a window's scan on the window's adapter when a user scan on another adapter took over (primary flip between StartScan and the window); answer `unavailable` for StartScan/Pair when the primary is off but another adapter is on; sysinfo (T-289) should use `bluetooth::primary_index`/`Raw::primary()`; the `BatteriesChanged` test of T-300 is still missing.
- (T-330 builder, lead-5) Ogg beds get no level or bass check (needs a decoder: planning call); the bundled theme grew 1.1 -> 2.5 MB (image size). Decoder follow-ups are T-346.
- (T-322 review, lead-6) Toast "Sound moved to <name>" for a new output (with T-348); re-apply the output policy when the first non-empty output list arrives (boot race with WirePlumber); `vm-reboot-check.ps1`: the saved output is the default after a reboot; choosing the speaker on the Dell rejects an inactive-profile HDMI the policy never picked (fine after T-347); a headset hot-plug overrides a saved choice (documented in 03: confirm); the round-2 builder stalled twice without a HANDOFF (the lead ran the test).
- (T-355 Dell, lead-6) **Critical path for real games, in this order:** (1) **T-358**: the compositor must give clients GPU buffers (`linux-dmabuf-v1` server side; Fedora's Qt ships no compositor dmabuf plugin): STK renders on llvmpipe at 560 % CPU though `/dev/dri` is in its sandbox; spike: build Qt's `linux-dmabuf-unstable-v1` compositor integration into the image, or our own (evidence, lead-6: the image's qt6-qtwayland 6.11.2 ships only `wayland-egl`, `drm-egl-server-buffer`, `dmabuf-server-buffer`, `shm-emulation`, `vulkan-server`, `eglstream-controller` server plugins; the Dell's shell loads `wayland-egl`, yet Mesa 26.2 clients still get `fd -1`, so the old wl_drm path gives them no device); (2) profile apps have no sound server (B-007): STK "Could not open the default sound device"; (3) `zxdg_output_manager_v1` missing (STK disables display scaling, likely the low resolution the owner saw); (4) a Flatpak game runs in its own `app-flatpak-*.scope`, outside `ruya-app-*` (accounting 28 ms CPU for a 45 min run): usage, limits, T-165 freeze and the kill path must follow the scope.
- (T-164 reviews, lead-6) T-165 must decide a hidden profile's running app: suspend or stop, tell the new profile (Home hint or toast) and give a way to close it; a locked profile's client is closed on its next surface (whole-client verdict); `ProfileSockets` leaks an idle listening fd each time the profile list empties briefly (skip the sync on an empty list); the compositor's `focus` log line named no item while the System list had the focus, and logs `appId`/`title` before they arrive; the VM test client runs as `org.ruyaos.ld-linux-x86-64` (pass an app id).
- (lead-5) `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` fails under load (nav gap 23 against 24 px at 1290 px wide; passes alone and on rerun): make the gap check independent of font metrics or settle longer.

Triaged 2026-11-08 (lead-5): earlier lines are verbatim in [`STATUS-parked.md`](STATUS-parked.md).

- (T-331 reviews, lead-5) A host tempdir test for `FsSource::list` (cap + stop on a real directory larger than `max`; only the `FakeTree` copy of the loop is tested); screenshots of the Scanning state and the Other / empty rows; the scan cache is not refreshed by writes that change no udisks property (a Rescan row or re-scan on pane open); a drive with six categories adds seven rows (a collapsed 'Show details' or a modal would need a new component); `StoragePane` busy retry runs every 1.5 s while another client scans. The 'what you will lose' line of T-333 reads `Storage.scans[id]`, `scan(id)`, `cancelScan(id)`. VM: `vm-storage-check.ps1` step `scan` is on the queue.

- (T-349 reviews, lead-5) Merged with T-356 (959+ QML green). Dell A/B still to run: build 'before' from `0a3e4f4`, 'after' from main, `scripts/page-open-bench.py` (how-to in dev-setup); the `topSettled()` gate of `reapIfDone` has no test of its own; `tst_profile_admin` sets `modalsBuilt = true` by hand; the comment in `StoragePane.qml` lines 137-138 ("created then, hidden") is out of date since panes are lazy; the Store page feels slow with many dummy items: measure with the probe (Store -> Games, Home -> Store).

- (T-356 review, lead-5) `test_every_page_owns_the_focus` (tst_pages) takes about 35 s: a short-fade switch for tests; it should also cover the admin-only `profiles` Settings category and check that the requested category opened (SettingsPage falls back to My profile silently); the focus rule is in 04 section 4 (the task said 7). **After T-349 merges:** its `Loader`s are parented to the modal layer and are `visible: true` while inactive, so `Shell.modalShown()` would stay true and switch the safety net off: make `modalShown()` skip Loaders without a visible item and add a net test with a Settings pane loaded. `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` (gap 23-25 px against 24) fails in about half of the full runs on this host and passes alone: font/DPI dependent; find the real margin.

- (owner question 2026-11-09) Card styles: the owner sees three card types (Home, Store, Games). By design (04 5.2, T-281): one card family in three sizes (Games hero 400x225, Home shelf 320x180, Store compact 288x162) with the same radius, ring, glare and glow; the visible difference is the caption (over the art on Home/Games, below it in the Store). Tomorrow: `ruya-design-reviewer` + `ruya-ux-reviewer` cross-page review of the Home/Games/Store cards from screenshots, decide whether the Store caption placement and the three sizes are justified or should unify, then answer the owner. Also: the Store page feels slow with many dummy items (measure with the T-349 probe).

- (T-334 reviews, lead-5) The battery chips and the "More devices" list show the UPower name, so two like pads still read "Wireless Controller" twice (`ListBatteries` would need the Bluetooth address); `ControllerOnboarding` "Found nearby" can list two like-named pads with nothing to tell them apart; the rename keyboard is titled "Controller name" (title it with the shown name); an "Identify" action (rumble or light bar) per paired pad would tell the pads apart on the sofa; `ruya-devices --session` has no BlueZ signal loop, so no VM check drives the window's own pump (a fake that wakes the loop); T-264's registry should use `DeviceIcons.addressTail` or an ordinal as the tie-break so "Player 2" and the pane agree; the row label now strips format characters (`plain(name)`), the unused `name` property in the device row can go. VM: `vm-devices-check.sh twopads` is on the queue.

- (T-335 review, lead-5) Journal labels: also replace `"` and Unicode format characters in aliases (reuse `pairing::is_format_char`); a late pairing stranger (pairs after the window ended) stays bonded and untrusted: decide whether it is removed (own task); log radio changes we did not cause (rfkill, Powered seen changing) and the pairable state after a BlueZ restart (helps T-338); the other `eprintln!` failure lines (scan, agent registration, Pairable off, `dbus.rs`) could go through `log::info`.
- (T-337 review, lead-5) A pad that connects with a button already held and later releases it is now ignored (fixed); `vm-devices-check.sh inputd` could join the default check once `/dev/uinput` works for root in the image.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | The Dell (Intel UHD 630, 8 GB, Secure Boot) boots the installer ISO to the shell, greenboot green, `vm-session-check.sh` 45 PASS (0.0.44). No frame times yet. Checks: the Dell look-at list. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123, T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat, stick repeat, long-press and context menu (spec 02 §4.3), Bluetooth PIN pairing, player assignment, button test, remapping (T-136, T-217), pad activity for the idle clock. |
| B-007 | `ruya-devices` remainder: `ambient`/`media` levels on app streams, PipeWire for profile apps | `ruya-session` in the image | Audio and network are done and VM-verified (ADR-010). Media access on `/run/media/ruya-shell/...` for profile users belongs to the Media task. |

## Open owner decisions

Long forms: `STATUS-parked.md`.

- **Xbox Wireless Adapter (T-261, research T-354).** Investigated first, nothing built. Proposed, **undecided, yours:** may the console offer a button where the player downloads Microsoft's dongle firmware from Microsoft's own server (RuyaOS redistributes nothing)? Legal and terms risk; no button before you answer.
- **Telemetry (T-224/T-225).** The consent flow is decided; the backend, retention, privacy notice and a data-processing agreement are yours, later.
- **Parked by you, nothing built:** `.play` packages (T-228, ADR-014 accepted, questions in `05-play-packages.md` §16) and the Epic Games Store (T-270, Proposed ADR-018: first-party Store app on Legendary, the Heroic Flatpak, or nothing).
- **Pad pictures and glyph licence (T-199).** Sony/Microsoft/Nintendo pad art needs a legal decision (we draw our own); ControllerCons (SIL OFL) says "cannot be redistributed or sold": ask the author. Recommended: our glyphs Apache-2.0, a notice in About.
- **Brand (T-269).** The splash shows "RuyaOS" in Inter; a logo is yours; recommended: keep the wordmark until one exists.
- **Drive formats (T-332; the feature is approved).** Proposed: add `dosfstools` and `ntfsprogs` only if missing (GPL, small); offer exFAT (default), ext4, FAT32, NTFS. Say if you object.
- **Small ones:** Dolby/DTS names need a licence (T-219); update size vs rechunking (T-195); HDR and VRR after the spikes (T-218/T-222); Flatpak runtime in a dev image (T-214); the dev ISO erases every disk and carries the SSH key (B-002); whether any first-party app is preinstalled (T-248).
- **Also:** a spare low-tier PC for KPIs (ADR-002); one admin or several (recommended: one); Turkish wording review; WSL `ext4` errors: move the VHD off C:.
- **Decided 2026-11-08 (owner; text in `STATUS-parked.md`):** ADR-022 public surface, ADR-015 runtime extension, ADR-016 no browser first (T-258 parked), ADR-019 multitasking, ADR-020 game data hub, telemetry consent, high first-start volume once (T-347). Earlier decisions: `STATUS-parked.md`, "Decided".

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-09 · Sonnet 5.5 · Lead (lead-5 part 2: T-356 focus-loss dead end, T-349 lazy Settings, T-331 drive scan merged after a checkpoint; T-164 open) · `test` 987 QML + 77 skips ALL GREEN; ISO built only when needed (owner rule), lead efficiency rules in LEAD.md. Found with the owner: covered pages stole the window focus (T-356). Process: reviewers must run the revert check; waits stay inside one turn.

- 2026-11-09 · Sonnet 5.5 · Lead (lead-5: T-330, T-336, T-335, T-337, T-334 merged, T-166 suspend verified, T-262 wake mechanism; planning batches T-331..T-356, ADR-015/016/019/020/022 accepted; checkpoint with T-356, T-349, T-331, T-164 on WIP branches) · `test` ALL GREEN; VM `0.0.55`/`0.0.56` queues PASS, both ISO checks PASSED; Dell on 0.0.56 (oci-archive route). Found with the owner: the dead-end focus bug (T-356; inputd innocent). Process: Dell upgrades need no owner; builders asked to kill processes are refused.


- 2026-11-08 · Sonnet 5.5 · Lead (build loop from `d09da99`: T-290, T-291, T-293, T-294, T-297, T-286, T-300, T-301, T-312, T-313, T-321, T-323 (corners), T-324 (profile settings) merged; 8 of 13 needed a round 2; T-330 in flight) · `test` 931 QML + 73 skips; VM `0.0.54`: usage 33, session 37 + restart 22 (exposure 1.1), store 70, library 34, bluetooth 21, display, power-saving incl. wake. Found: the ambient bed never played (FLAC rate code 0), the Dell sound path (HDMI-first was wrong), `lint-text` skipped lone-CR files. Process: Opus builders for owner-visible fixes; ID clash with the other planner (T-314/T-315 renumbered).

- 2026-11-08 · Sonnet 5.5 · Planning (Inbox triage, docs only) · 33 Inbox lines emptied: 20 tasks T-282..T-301 (lead: T-282 design decisions, T-298 CI gate; builder: contrast rows, glass sheet and dialogs, hints, plain text, display x2, system info, session, store, Activity, power saving, sound themes, time zone, VM scripts, lint, image, Bluetooth service and UI), notes merged into T-147/T-164/T-166/T-211, 7 dropped as done, 2 owner decisions added (pad glyph licence, wordmark). STATUS 34 KB to about 14 KB; full lines in STATUS-parked.md. Next: T-164, then the builder lanes at the top of the backlog.


- 2026-11-07 · Sonnet 5.5 · Lead (build loop from `e73e081`: T-200, T-214, T-206, T-204, T-209, T-208, T-205, T-190, T-223, T-203, T-194, T-199, T-213, T-226, T-260 merged; most needed a round 2, T-203/T-226 found real security/privacy defects) · `test` 674 QML + 57 skips, `shots` 111 green (basic render loop). VM `0.0.48/.50`: devices 106, store 71, library 35, storage, sample 28 PASS; ISOs `0.0.49`/`0.0.50` verified (whole disk), on F:. CI fixes (clippy cast, qmllint property-override). Board split, ~30 backlog tasks written. Process: shots loop, member lint, QEMU overlay cleanup.



