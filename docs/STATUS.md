# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines, the long form of owner decisions and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-08 (Sonnet 5.5, planning)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1-2 (shell core, profiles, devices):** pages, Settings, on-screen keyboard, first-boot wizard, Turkish, themes, glass, sounds, power saving, boot experience. **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, the Guide key, launching apps (T-162), display, usage, Bluetooth. **The shell is the compositor (T-130).**
- **Not started:** per-profile Wayland sockets (T-164: an app's window appears in the shell; Play does nothing yet), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-164** ([lead], the critical path: needs the Dell as the GL test). **Builder lanes** (planned 2026-11-08, in this order, the first rows of `STATUS-backlog.md`): T-281 is in progress; then T-296, T-297, T-290, T-291, T-285, T-286, T-293, T-292, T-294, T-295, T-300 (then T-301), T-287 (then T-288, T-289), T-299 (a "VM (this task)": one at a time). T-283 and T-284 wait for the lead's design pass T-282.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents (at most two at a time, own worktrees, different areas), has each branch reviewed by `ruya-reviewer` and merges it (`docs/LEAD.md`). Dispatched builders never edit this file; one "VM (this task)" runs at a time. A builder the owner starts directly takes NEXT alone in the main checkout and does the bookkeeping (`CLAUDE.md`).

Open work only (the front of the board; the rest is in `STATUS-backlog.md`), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | in-progress | — |
| [T-282](tasks/T-282-design-decisions-contrast-themes-dialogs.md) | **[lead]** Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery | todo | — |
| [T-261](tasks/T-261-controller-families-and-drivers-audit.md) | **[lead]** Controller families and drivers audit (DualSense, Xbox, 8BitDo, Switch), detection table, hardware checklist | todo | — |
| [T-164](tasks/T-164-per-profile-wayland-sockets.md) | **[lead]** Per-profile Wayland sockets | todo | T-162 |

Later (ordered): [`STATUS-backlog.md`](STATUS-backlog.md) holds the rest of the open board, same columns; `lint-board.ps1` reads both. A planner or the lead moves rows up when they become ready.

**VM queue** (the lead runs them with one image build; long form of the old paragraph: `STATUS-parked.md`, "Moved from STATUS 2026-11-08"): **0.0.55 passed on 2026-11-08** (lead-5; image 15 min + disk 18 min + ISO 19 min with the WSL disk on F:; boot OK; sounds ALL PASS with `-Audio`: bed stream running, no `QAudioFormat not valid`, no second copy of the theme; usage 33, session 37, library 34, store 70, devices bluetooth 21, boot 21, display 40, storage all steps; power-saving all but the known page-flip error after the wake key on virtio-gpu: the Dell decides). Left: `vm-iso-check.ps1` on the 0.0.55 ISO (running), `subset-icons.sh` in WSL (T-297), `vm-devices-check.sh system` with a FAT stick (T-226 `ReadWritePaths`), sample re-run, the greenboot drill. **0.0.56 passed** (sounds 23 with the new bed, boot 21, devices bluetooth 23 incl. the two-adapter fake and the new journal lines, inputd 6; boot OK; T-166 marker and the udev wakeup rule are in 0.0.57). Left: `vm-iso-check.ps1` on the 0.0.56 ISO, `subset-icons.sh` (T-297), FAT-stick `vm-devices-check.sh system`, sample re-run, the greenboot drill. New checks arrive with T-332 (storage format), T-334 and T-336 (two pads, two adapters), T-337 (stuck key), T-339 (scripts) and T-340 (session).

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
- (lead-5) `tst_battery_cluster::test_the_chip_shrinks_to_plus_n_in_a_narrow_room` fails under load (nav gap 23 against 24 px at 1290 px wide; passes alone and on rerun): make the gap check independent of font metrics or settle longer.

Triaged 2026-11-08 (lead-5): earlier lines are verbatim in [`STATUS-parked.md`](STATUS-parked.md).

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

Long form: `STATUS-parked.md` ("Moved from STATUS 2026-11-08" and "Open owner decisions before the 2026-11-08 trim").

- **Telemetry (T-224/T-225).** Consent: explicit first-boot Share / Don't share, nothing sent before the answer (recommended); backend, retention, privacy notice and a data-processing agreement are yours. T-220 and the first-boot screen follow the recommendation until you answer.
- **`.play` packages (T-228).** Decided 2026-11-06, parked until you say start: ADR-014 accepted, no emulators, Proton/Steam runtime, firmware or discs shipped, the image preinstalls the Wine runner. Questions: `05-play-packages.md` §16.
- **First-party apps (T-248).** Proposed ADR-015 (T-250: runtime extension `org.ruyaos.Platform` with RuyaKit versus a module per app) and ADR-016 (T-258: browser engine or none first); which apps first. T-249 and T-250 can start anytime.
- **Controller drivers and firmware (T-261).** Xbox Wireless Adapter needs out-of-tree drivers and non-redistributable firmware; proposed: ship none until you decide.
- **Epic Games Store (T-270).** Proposed ADR-018: first-party Store app driving Legendary through the Wine runner, versus the Heroic Flatpak, versus nothing. Recommendation: first-party after T-229/T-244, neutral text, no logo. Parked by you; nothing is built.
- **Multitasking (T-273).** Proposed ADR-019: one foreground app, others frozen, LRU close under memory pressure. For you: Guide short = quick menu with switcher and double-press = previous app (recommended); background apps opt in; a frozen online game warns once.
- **Controller brand art and pad glyph licence (T-199).** Sony/Microsoft/Nintendo pad pictures need a legal decision (we draw our own). ControllerCons (SIL OFL) says "cannot be redistributed or sold": ask the author first. Our own pad glyphs: Apache-2.0 with a notice in About (recommended).
- **Brand: logo and boot wordmark (T-269).** The splash shows "RuyaOS" in Inter; a logo is yours; recommendation: keep the Inter wordmark until one exists.
- **Game data hub (T-302).** Proposed ADR-020 (`org.ruyaos.Hub1`): other apps read now-playing and captures off by default, asked per app, revocable (recommended); a shared read-only ROM folder besides per-profile ones (yes); captures local in v1 (yes); saves stay on the console, drives hold ROMs, captures and backups.
- **Drive formats (T-332, asked for 2026-11-08; the feature is approved).** `exfatprogs` and `ntfs-3g` ship. Proposed: add `dosfstools` (FAT32) and `ntfsprogs` (mkntfs) only if missing; offer exFAT (default), ext4, FAT32, NTFS. GPL, small. Say if you object; T-332 checks the image first.
- **Public developer surface (ADR-022, T-352).** Proposed charter: three tiers (shell-private, one narrow `Platform1` door for sandboxed apps, data-only formats), approve the candidate capability list once (lifecycle, achievements, play stats and now-playing, notifications, controller extras, text input, read-only display/theme/age flag, storage picker; never profiles, update, install, system settings, telemetry); the lead places tasks inside it. Recommended: yes; stability promises only from the first release. Decide with ADR-015.
- **Small ones:** Dolby/DTS names need a licence (T-219); update size vs rechunking (T-195); HDR and VRR after the spikes (T-218/T-222); Flatpak runtime in a dev image (T-214); the dev ISO erases every disk and carries the SSH key (B-002).
- **Also:** a spare low-tier PC for KPIs (ADR-002); one admin or several (recommended: one); Turkish wording review; libdvdcss/AACS not included; WSL `ext4` errors: move the VHD off C:.
- Decided (record in `STATUS-parked.md`): storage shows the internal disk; Steam, RetroArch and media apps are separate Store apps; blur and shadows stay the default; agents in worktrees with a reviewer verdict; icon set Material Symbols; the lead pushes `main` after the secret scan.

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.


- 2026-11-08 · Sonnet 5.5 · Lead (build loop from `d09da99`: T-290, T-291, T-293, T-294, T-297, T-286, T-300, T-301, T-312, T-313, T-321, T-323 (corners), T-324 (profile settings) merged; 8 of 13 needed a round 2; T-330 in flight) · `test` 931 QML + 73 skips; VM `0.0.54`: usage 33, session 37 + restart 22 (exposure 1.1), store 70, library 34, bluetooth 21, display, power-saving incl. wake. Found: the ambient bed never played (FLAC rate code 0), the Dell sound path (HDMI-first was wrong), `lint-text` skipped lone-CR files. Process: Opus builders for owner-visible fixes; ID clash with the other planner (T-314/T-315 renumbered).

- 2026-11-08 · Sonnet 5.5 · Planning (Inbox triage, docs only) · 33 Inbox lines emptied: 20 tasks T-282..T-301 (lead: T-282 design decisions, T-298 CI gate; builder: contrast rows, glass sheet and dialogs, hints, plain text, display x2, system info, session, store, Activity, power saving, sound themes, time zone, VM scripts, lint, image, Bluetooth service and UI), notes merged into T-147/T-164/T-166/T-211, 7 dropped as done, 2 owner decisions added (pad glyph licence, wordmark). STATUS 34 KB to about 14 KB; full lines in STATUS-parked.md. Next: T-164, then the builder lanes at the top of the backlog.


- 2026-11-07 · Sonnet 5.5 · Lead (build loop from `e73e081`: T-200, T-214, T-206, T-204, T-209, T-208, T-205, T-190, T-223, T-203, T-194, T-199, T-213, T-226, T-260 merged; most needed a round 2, T-203/T-226 found real security/privacy defects) · `test` 674 QML + 57 skips, `shots` 111 green (basic render loop). VM `0.0.48/.50`: devices 106, store 71, library 35, storage, sample 28 PASS; ISOs `0.0.49`/`0.0.50` verified (whole disk), on F:. CI fixes (clippy cast, qmllint property-override). Board split, ~30 backlog tasks written. Process: shots loop, member lint, QEMU overlay cleanup.

- 2026-11-06 · Sonnet 5.5 · Planning (owner request: `.play` packages; no code) · Wrote spec `05-play-packages.md` (format, runners bundled/system/newest, closed permissions, signing and trust tiers, updates), Proposed ADR-014 (a container that installs as a sandboxed Flatpak, amends ADR-005) and epic T-228 with T-229..T-244. Epic is `blocked` on the owner (ADR-014, D1-D3). Open: Xwayland or Wine Wayland (none today), Proton nesting, emulator content policy. Inbox untouched.


- 2026-11-06 · Sonnet 5.5 · Lead (T-162 by the lead; no lanes; range had only docs) · `ruya-session` runs in the image: `systemd-run --machine=` per app, status file, scope-aware Stop/kill, linger; unit exposure 1.1; deleting a profile ends its manager. VM `0.0.44-t162`: smoke OK, session check 45 PASS, devices 57. `test` 381 QML + 30 skips, Rust green. VM found: SELinux refuses PID 1 a service's pipe; Flatpak apps live in their own scope; PipeWire was not masked for profiles. New F: drive formatted NTFS, holds the ISO. Process: image/CLAUDE.md quirk.
