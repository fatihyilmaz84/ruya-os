# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines, the long form of owner decisions and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-10 (lead-9 handoff)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1-2 (shell core, profiles, devices):** pages, Settings, keyboard, first-boot wizard, Turkish, themes, glass, sounds, power saving, boot experience; **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, Guide key, launching apps, display, usage, Bluetooth. **The shell is the compositor (T-130).**
- **Real games:** per-profile Wayland sockets (T-164) and GPU buffers for apps (T-358) are built; SuperTuxKart renders through the shell on the Dell. Not started: sound for profile apps (B-007), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-435** (builders: ACBR window and orphaned scopes; then T-429, T-427, T-428, T-431); lead: T-366 ([lead] Ruya Input spike, ADR-024; then T-367, T-381 GE-Proton, T-380), and the Dell second pass T-355 once Play works (T-386, image 0.0.61). **Builder lanes**: T-147, then the first rows of `STATUS-backlog.md` in order (T-362, T-423, T-424, T-422, T-378, T-299, T-364, T-339); one "VM (this task)" at a time. T-283, T-284, T-287, T-288 wait for the lead's design pass T-282; T-397..T-399 wait for T-366 and T-396. **Plan audit 2026-11-10:** 76 task files carry a ruling under their header (overlaps cut, dependencies fixed); the Depends column now lists only dependencies that are not `done`.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents (at most two at a time, own worktrees, different areas), has each branch reviewed by `ruya-reviewer` and merges it (`docs/LEAD.md`). Dispatched builders never edit this file; one "VM (this task)" runs at a time. A builder the owner starts directly takes NEXT alone in the main checkout and does the bookkeeping (`CLAUDE.md`).

Open work only (the front of the board; the rest is in `STATUS-backlog.md`), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-435](tasks/T-435-acbr-shows-no-window-on-the-dell.md) | ACBR (Electron) starts on the Dell but never shows a window; orphaned app scopes | in-progress | — |
| [T-393](tasks/T-393-options-menu-design.md) | **[lead]** Design: the Options (context) menu: component, contents per surface, motion, focus | todo | — |
| [T-396](tasks/T-396-controller-ownership-and-layout-spec.md) | **[lead]** Spec: who owns the UI, the family's confirm button, action glyphs (ADR-027) | todo | T-366 |
| [T-366](tasks/T-366-ruya-input-spike-engine-and-design.md) | **[lead]** Ruya Input: spike, engine decision and the design (06-input.md, Input1 draft) | todo | — |
| [T-367](tasks/T-367-a-game-sees-the-pad.md) | **[lead]** A game sees the pad: a virtual pad per controller, for the signed-in profile only, routed by focus | todo | T-366 |
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | blocked | — |
| [T-282](tasks/T-282-design-decisions-contrast-themes-dialogs.md) | **[lead]** Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery | todo | — |
| [T-261](tasks/T-261-controller-families-and-drivers-audit.md) | **[lead]** Controller families and drivers audit (DualSense, Xbox, 8BitDo, Switch), detection table, hardware checklist | todo | — |

Later (ordered): [`STATUS-backlog.md`](STATUS-backlog.md) holds the rest of the open board, same columns; `lint-board.ps1` reads both. A planner or the lead moves rows up when they become ready.

**VM queue** (one image build runs them all; `scripts/vm-queue.ps1`; history in `STATUS-parked.md`): **0.0.62 passed on 2026-11-10** (lead-10: session check/display/restart, app flow driven by hand (T-147), sounds, security (T-424), devices bluetooth/twopads/inputd/system, audio, storage scan, reboot saved output; two stale check patterns fixed in ec989d8). Dell on 0.0.62 (rollback 0.0.61). Left for the next image: `scripts/dell-glass-check.sh` on the Dell (T-421, T-434: GPU at Home still, Settings in use, the picker; 0.0.62 lacks T-434), `vm-session-check.sh` (T-435), `subset-icons.sh` (T-297), the sample re-run, the greenboot drill.

**Dell look-at list:** the long list with task ids is in `STATUS-parked.md`, "Dell look-at list (moved 2026-11-10, lead-8)"; the next Dell pass also checks 0.0.61: STK from Games with A (T-386), the picker after an app (T-387), the T-376 hw items.

## Inbox

One line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

Triaged 2026-11-10 (lead-9): the lines before are verbatim in [`STATUS-parked.md`](STATUS-parked.md), "Inbox triage 2026-11-10 (lead-9)"; they became T-427 (Bluetooth leftovers), T-428 (Store follow-ups), T-429 (test harness), T-430 (GlassShadow/AppArt masks, L0 memory), T-147 item 6 (launch follow-ups), T-282 item 12 (keyboard over glass), or owner questions (CPU per game, `core.hooksPath`).

- (T-147 reviews) Launch and quick-menu follow-ups: a running app with no Library card behind Home cannot be resumed (offer Resume or Switch to in the quick menu while apps are behind Home); `Notifications.requeue` counts `shownCount` twice; an `AppExited` before the ok answer can end a launch on an older instance's exit, and Close before ok has no instance to stop; the Running pill on the Games grid (Home only today); the Home shrink-into-card transition (04 §5.1, a `pageMs` fade today); older device toasts are not capped at 30 characters; a Steam launch path in Session1, and one line in Details saying why a Steam game has no Play; consider showing Close on the splash before 20 s; add the state pill over a saturated tint to the contrast gate.
- (T-434 reviews) Glass follow-ups: WallpaperLayer's page blur still runs a full-size MultiEffect (give it the quarter-size treatment once the Dell confirms the saving); PIN pad and TextEntry keys use see-through `glass` over a scrim on every tier, and the Home hero's SecondaryButton sits over sharp art: confirm none lies directly on L0 on a page; the `Theme.blurMax > 0 ? glass : glassOpaque` ternary is in three files (a `glassOnL0` token needs a 04 §2 entry); the 1/3 blurMax and the pill number await the Dell run.
- (lead-9, second triage) The lines from T-423, T-421 and T-424 are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-10 (lead-9, second)"; they became T-431 (image hardening), T-432 (SELinux domains), T-433 (quick-xml, zbus 6, CI actions), T-434 (glass cost, Performance rows), T-435 (ACBR window, orphaned scopes), T-430 and T-282 additions, T-425 (release profile) and the next-image list.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | The Dell (Intel UHD 630, 8 GB, Secure Boot) boots the installer ISO to the shell, greenboot green, `vm-session-check.sh` 45 PASS (0.0.44). No frame times yet. Checks: the Dell look-at list. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123, T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting. |
| B-006 | Controllers for games and the input service (ADR-024, replaces the old InputPlumber line) | Linux + controllers | Now the tasks T-366..T-374 (spike first); games see no pad today (physical nodes are shell-only). Key repeat, stick repeat, long-press, PIN pairing, player assignment go to T-366's design and ADR-017's tasks. |
| B-007 | `ruya-devices` remainder: `ambient`/`media` levels on app streams (sound for profile apps is done: T-365, a pulse server per profile) | `ruya-session` in the image | Audio and network are done and VM-verified (ADR-010). Media access on `/run/media/ruya-shell/...` for profile users belongs to the Media task. |

## Open owner decisions

Long forms and decided records: `STATUS-parked.md` ("Decided", and "Decided records moved 2026-11-10 (lead-9)").

- **From the plan audit (2026-11-10), yours to decide:**
  - **Backups on USB hold account tokens (T-215):** leave credential files out by a list (recommended), or encrypt the archive with the PIN.
  - **The admin PIN typed in a browser (ADR-029):** admin actions on Ruya Web ask for it, so it travels over the LAN (TLS) and a LAN device can try PINs. Accept with a lockout that cannot lock the TV out (recommended, T-404 designs it), or confirm admin actions on the TV instead.
  - **Another pad taking over an idle session (T-396/T-397):** removed from the plan (ADR-027 allows takeover only when the owner's pads are gone). Say if you want the idle takeover.
  - **Release security (T-426, later):** who holds the image signing key, disk encryption, and whether some Flathub permissions are refused for every Store app.
- **Save locations list (ADR-028, T-400):** Ludusavi's manifest licence (PCGamingWiki data); use, ask, or our own.
- **Telemetry (T-224/T-225).** The consent flow is decided; the backend, retention, privacy notice and a data-processing agreement are yours, later.
- **Parked by you, nothing built:** `.play` packages (T-228, ADR-014 accepted, questions in `05-play-packages.md` §16) and the Epic Games Store (T-270, Proposed ADR-018: first-party Store app on Legendary, the Heroic Flatpak, or nothing).
- **Pad pictures and glyph licence (T-199).** Sony/Microsoft/Nintendo pad art needs a legal decision (we draw our own); ControllerCons (SIL OFL) says "cannot be redistributed or sold": ask the author. Recommended: our glyphs Apache-2.0, a notice in About.
- **Brand (T-269).** The splash shows "RuyaOS" in Inter; a logo is yours; recommended: keep the wordmark until one exists.
- **Drive formats (T-332; the feature is approved).** Proposed: add `dosfstools` and `ntfsprogs` only if missing (GPL, small); offer exFAT (default), ext4, FAT32, NTFS. Say if you object.
- **Small ones:** whether "CPU per game" is wanted in the ledger or `ListSessions` (today only the journal has it; a format change, T-363); Dolby/DTS names need a licence (T-219); update size vs rechunking (T-195); HDR and VRR after the spikes (T-218/T-222); Flatpak runtime in a dev image (T-214); the dev ISO erases every disk and carries the SSH key (B-002); whether any first-party app is preinstalled (T-248).
- **Also:** a spare low-tier PC for KPIs (ADR-002); one admin or several (recommended: one); Turkish wording review; WSL `ext4` errors: move the VHD off C:.

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-10 · Opus 5.5 · Lead (lead-9: T-423 CI gates, T-421 Dell glass, T-424 security baseline, T-147 launch and quick menu merged; T-427..T-435 planned from the Inbox) · test 1063 QML + 89 skips ALL GREEN; no image; 0.0.61 VM: vm-security-check PASS. CI red fixed (host-dependent battery test, two T-421 races, a yanked crate); CI image job manual-only (owner); gh signed in. Review: T-147 deleted 9 tests silently, T-424 baseline hid weaknesses. Owner: drift rests after 30 s. Process: lost-tests.sh in review and self-check; fuzzy tryCompare rule; builder file prune.

- 2026-11-10 · Fable 5 · Planning (plan audit: rules, board, 159 open tasks; no code) · 76 task files got a ruling under the header (overlaps in input, saves, runners, permissions, Web cut to one owner each; about 60 dependency fixes); T-315 stale claim reset; T-258, T-403, T-413 blocked; new T-422 plan lint, T-423 CI gates, T-424 security baseline, T-425 dev/release image, T-426 release-security epic; 5 owner questions. Process: Depends column = open dependencies; sizes, hand-off threshold and roles made consistent; template has Complexity and a security line; planning horizon rule. `dev.ps1 docs` green.

- 2026-11-10 · Opus 5.5 · Lead (lead-8: T-363, T-377, T-359, T-386 Play starts games, T-387 glass after an app merged; T-379 not reproducible; planned ADR-025..ADR-031 (GE-Proton, downloads, controller ownership, games and saves, Web, Companion, developer platform) and T-378..T-419) · test 1029 QML + 84 skips ALL GREEN; VM 0.0.60 queue PASS after three check fixes; Dell 0.0.60 (glass and launch bugs found there). Process: vm-queue.ps1, dell-update.sh, image-chain SKIP_BUILD, a pre-commit lint hook (needs core.hooksPath).

- 2026-11-09 · Opus 5.5 · Lead (lead-7: T-340, T-348, T-376, T-361, T-360 merged; lead T-365 profile sound, T-375 BlueZ kernel HID; plans ADR-024 Ruya Input T-366..T-374, T-359..T-364, T-376, T-377; Hub analysis) · test 1012 QML ALL GREEN; VM 0.0.59 check/display PASS, restart FAIL then fixed (zbus unixexec); Dell 0.0.59: STK sound as ruya-p1, bluetoothd 10-12 % to 0. Process: lints refuse conflict markers and jq; stalled-builder rule.

- 2026-11-09 · Opus 5.5 · Lead (lead-6: T-164 per-profile Wayland sockets, T-322 output policy, T-347 card profiles, T-285 hint bar merged; T-358 GPU buffers by the lead; T-355 first pass; T-357 written) · `test` 1001 QML + 77 skips ALL GREEN; VM 0.0.57/0.0.58 PASS; Dell 0.0.58: STK through the shell on the UHD 630 at 15 % CPU (was llvmpipe 563 %) via our patched Qt linux-dmabuf v4 plugin. Process: `image-chain.sh`; builders run `test` in the foreground (two stalled).


