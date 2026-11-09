# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines, the long form of owner decisions and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-09 (Opus 5.5, lead-7)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1-2 (shell core, profiles, devices):** pages, Settings, keyboard, first-boot wizard, Turkish, themes, glass, sounds, power saving, boot experience; **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, Guide key, launching apps, display, usage, Bluetooth. **The shell is the compositor (T-130).**
- **Real games:** per-profile Wayland sockets (T-164) and GPU buffers for apps (T-358) are built; SuperTuxKart renders through the shell on the Dell. Not started: sound for profile apps (B-007), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-355** ([lead], second pass on the Dell: STK now renders on the GPU (T-358); frame times, pads, split screen, suspend, saves), then profile-app sound (B-007). **Builder lanes**: the first rows of `STATUS-backlog.md` in order (T-348, ...); one "VM (this task)" at a time. T-283, T-284, T-287, T-288 wait for the lead's design pass T-282.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents (at most two at a time, own worktrees, different areas), has each branch reviewed by `ruya-reviewer` and merges it (`docs/LEAD.md`). Dispatched builders never edit this file; one "VM (this task)" runs at a time. A builder the owner starts directly takes NEXT alone in the main checkout and does the bookkeeping (`CLAUDE.md`).

Open work only (the front of the board; the rest is in `STATUS-backlog.md`), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | in-progress | — |
| [T-282](tasks/T-282-design-decisions-contrast-themes-dialogs.md) | **[lead]** Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery | todo | — |
| [T-261](tasks/T-261-controller-families-and-drivers-audit.md) | **[lead]** Controller families and drivers audit (DualSense, Xbox, 8BitDo, Switch), detection table, hardware checklist | todo | — |

Later (ordered): [`STATUS-backlog.md`](STATUS-backlog.md) holds the rest of the open board, same columns; `lint-board.ps1` reads both. A planner or the lead moves rows up when they become ready.

**VM queue** (one image build runs them all; history in `STATUS-parked.md`): **0.0.58 passed on 2026-11-09** (lead-6; image-chain build 23 + qcow2 17 min; fresh disk with `-Audio`: `vm-session-check.sh display` and `check` ALL PASSED, `vm-audio-check.sh` AUDIO_SAVED_OUTPUT_OK, AUDIO_FIRST_VOLUME_OK (1.00), AUDIO_VOLUME_KEPT_OK; the Dell runs 0.0.58). Left for the next build: `vm-storage-check.ps1` step `scan` (T-331), `vm-devices-check.sh twopads|inputd|bluetooth` (T-334..T-337), `vm-devices-check.sh system` with a FAT stick (T-226), `subset-icons.sh` in WSL (T-297), the sample re-run, the greenboot drill, `vm-reboot-check.ps1` saved-output case (not written yet).

**Dell look-at list** (one pass with the next ISO; the long text with task ids is in `STATUS-parked.md`, "Moved from STATUS 2026-11-08"):

- *Boot:* Esc at power-on, the splash-to-shell gap, no text before the shell, `bootloader-update` status (T-269, T-280, T-299).
- *Screen:* DPMS wake time and a clean wake (virtio-gpu logged 3 `Could not queue DRM page flip` right after the wake key), display modes with `display-capture.sh` and an unsupported mode that reverts (T-198), a DisplayPort cable for 1440p144, frame times with glide, liquid pill, backdrop, halo and picture mask and the 30 s idle pause (T-204, T-205, T-281), five themes, a 4K wallpaper copy from a real stick (T-208), the rounded corners on the real GPU (T-323), the gear cog (T-206).
- *Sound (image 0.0.55 or newer):* the ambient bed audible on the small speaker (T-330) and ducking under cues; Settings > Audio sliders and "Sound theme"; first-start volume and which sink is the default after a reboot (T-322). Silent? The probe commands are in `STATUS-parked.md`.
- *Pads:* T-203 checks 1-3 (cold boot with the bonded pad; bond-less pairing with PS + Create; a phone in pairing mode is never left bonded), a second pad beside the first and why pad 2 dropped after 21 s (T-338), DualSense disconnect/reconnect (T-202), a B press in the first second after wake is swallowed (T-293), controller-only play counts past 10 min (T-247), icons, toasts, Rename/Forget, 8BitDo (T-199, T-223, T-260).
- *Settings:* My profile and Manage profiles (T-324). *Fixtures to capture:* `/sys/class/hwmon` and `thermal_zone` (T-200), `ruya-sysinfo --example dump` against `lscpu`/`free`/`lspci` (T-226).

## Inbox

One line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

Triaged 2026-11-09 (lead-7): the earlier lines are verbatim in [`STATUS-parked.md`](STATUS-parked.md), "Inbox triage 2026-11-09 (lead-7)"; they became T-359..T-364, notes in T-165 and T-282, or stay parked there (Ogg bed checks, D-pad glyph, Identify action, late pairing stranger, `inputd` default check, Dell A/B bench).

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

- 2026-11-09 · Opus 5.5 · Lead (lead-6: T-164 per-profile Wayland sockets, T-322 output policy, T-347 card profiles, T-285 hint bar merged; T-358 GPU buffers by the lead; T-355 first pass; T-357 written) · `test` 1001 QML + 77 skips ALL GREEN; VM 0.0.57/0.0.58 PASS; Dell 0.0.58: STK through the shell on the UHD 630 at 15 % CPU (was llvmpipe 563 %) via our patched Qt linux-dmabuf v4 plugin. Process: `image-chain.sh`; builders run `test` in the foreground (two stalled).

- 2026-11-09 · Sonnet 5.5 · Lead (lead-5 part 2: T-356 focus-loss dead end, T-349 lazy Settings, T-331 drive scan merged after a checkpoint; T-164 open) · `test` 987 QML + 77 skips ALL GREEN; ISO built only when needed (owner rule), lead efficiency rules in LEAD.md. Found with the owner: covered pages stole the window focus (T-356). Process: reviewers must run the revert check; waits stay inside one turn.

- 2026-11-09 · Sonnet 5.5 · Lead (lead-5: T-330, T-336, T-335, T-337, T-334 merged, T-166 suspend verified, T-262 wake mechanism; planning batches T-331..T-356, ADR-015/016/019/020/022 accepted; checkpoint with T-356, T-349, T-331, T-164 on WIP branches) · `test` ALL GREEN; VM `0.0.55`/`0.0.56` queues PASS, both ISO checks PASSED; Dell on 0.0.56 (oci-archive route). Found with the owner: the dead-end focus bug (T-356; inputd innocent). Process: Dell upgrades need no owner; builders asked to kill processes are refused.


- 2026-11-08 · Sonnet 5.5 · Lead (build loop from `d09da99`: T-290, T-291, T-293, T-294, T-297, T-286, T-300, T-301, T-312, T-313, T-321, T-323 (corners), T-324 (profile settings) merged; 8 of 13 needed a round 2; T-330 in flight) · `test` 931 QML + 73 skips; VM `0.0.54`: usage 33, session 37 + restart 22 (exposure 1.1), store 70, library 34, bluetooth 21, display, power-saving incl. wake. Found: the ambient bed never played (FLAC rate code 0), the Dell sound path (HDMI-first was wrong), `lint-text` skipped lone-CR files. Process: Opus builders for owner-visible fixes; ID clash with the other planner (T-314/T-315 renumbered).

- 2026-11-08 · Sonnet 5.5 · Planning (Inbox triage, docs only) · 33 Inbox lines emptied: 20 tasks T-282..T-301 (lead: T-282 design decisions, T-298 CI gate; builder: contrast rows, glass sheet and dialogs, hints, plain text, display x2, system info, session, store, Activity, power saving, sound themes, time zone, VM scripts, lint, image, Bluetooth service and UI), notes merged into T-147/T-164/T-166/T-211, 7 dropped as done, 2 owner decisions added (pad glyph licence, wordmark). STATUS 34 KB to about 14 KB; full lines in STATUS-parked.md. Next: T-164, then the builder lanes at the top of the backlog.
