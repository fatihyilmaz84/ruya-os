# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines, the long form of owner decisions and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-10 (lead-10 handoff)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1-2 (shell core, profiles, devices):** pages, Settings, keyboard, first-boot wizard, Turkish, themes, glass, sounds, power saving, boot experience; **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, Guide key, launching apps, display, usage, Bluetooth. **The shell is the compositor (T-130).**
- **Real games:** per-profile Wayland sockets (T-164) and GPU buffers for apps (T-358) are built; SuperTuxKart renders through the shell on the Dell. Not started: sound for profile apps (B-007), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-464** (a frozen game thawed behind another game; T-453 in flight), then T-463 (faster test run). T-462, T-458, T-452 merged. Owner, 2026-11-10: Ruya Hub first, then Ruya Input. Builders, in order: T-464, T-463, T-465 (image; a second lane may take it), T-466, then T-454, T-455 (each edits QuickMenu.qml or Shell.qml: **one at a time**); a second lane takes T-427, T-431, T-433, then the first rows of `STATUS-backlog.md`. Lead: T-461 (XWayland spike), T-366 (Ruya Input spike; then T-367, T-456, T-381, T-380), the Dell pass T-355. T-283, T-284, T-287, T-288 wait for T-282; T-397..T-399 wait for T-366 and T-396. The Depends column lists only dependencies that are not `done`.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents (at most two at a time, own worktrees, different areas), has each branch reviewed by `ruya-reviewer` and merges it (`docs/LEAD.md`). Dispatched builders never edit this file; one "VM (this task)" runs at a time. A builder the owner starts directly takes NEXT alone in the main checkout and does the bookkeeping (`CLAUDE.md`).

Open work only (the front of the board; the rest is in `STATUS-backlog.md`), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-461](tasks/T-461-xwayland-compatibility-spike.md) | **[lead]** Spike: XWayland as a compatibility layer (ADR-034), two X11-only games on the Dell | todo | — |
| [T-366](tasks/T-366-ruya-input-spike-engine-and-design.md) | **[lead]** Ruya Input: spike, engine decision and the design (06-input.md, Input1 draft) | todo | — |
| [T-367](tasks/T-367-a-game-sees-the-pad.md) | **[lead]** A game sees the pad: a virtual pad per controller, for the signed-in profile only, routed by focus | todo | T-366 |
| [T-393](tasks/T-393-options-menu-design.md) | **[lead]** Design: the Options (context) menu: component, contents per surface, motion, focus | todo | — |
| [T-396](tasks/T-396-controller-ownership-and-layout-spec.md) | **[lead]** Spec: who owns the UI, the family's confirm button, action glyphs (ADR-027) | todo | T-366 |
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | blocked | — |
| [T-282](tasks/T-282-design-decisions-contrast-themes-dialogs.md) | **[lead]** Design decisions queue: glass text contrast, theme looks, dialogs, Tab, display recovery | todo | — |
| [T-261](tasks/T-261-controller-families-and-drivers-audit.md) | **[lead]** Controller families and drivers audit (DualSense, Xbox, 8BitDo, Switch), detection table, hardware checklist | todo | — |

Later (ordered): [`STATUS-backlog.md`](STATUS-backlog.md) holds the rest of the open board, same columns; `lint-board.ps1` reads both. A planner or the lead moves rows up when they become ready.

**VM queue** (one image build runs them all; `scripts/vm-queue.ps1`; history in `STATUS-parked.md`): **0.0.64 passed on 2026-11-11** (lead-11, main at 6cd6b20: the default list plus devices check/security; three check bugs fixed: the shell's sweep thawed the session check's Freeze, DeleteProfile of the signed-in profile, the compositor log's new pid field; the idle-spawn check waits for quiet and names spawns). **The Dell runs 0.0.64** (rollback 0.0.63; shell and compositor up; `dell-glass-check.sh` PASS on the High tier (T-434), the Dell itself stays on Performance; `bootloader-update` red as before, T-299). Left for 0.0.64, on the Dell: the Hub over a frozen STK with sound (T-457), Close of Asteroid Shooter from the Hub (T-459), the FrameMeter with STK (T-451), Resume from Home for ACBR (T-435); also `vm-app-check.sh flow` by hand, `subset-icons.sh` (T-297), the sample re-run, the greenboot drill.

**Dell look-at list:** the long list with task ids is in `STATUS-parked.md`, "Dell look-at list (moved 2026-11-10, lead-8)"; the next Dell pass also checks 0.0.61: STK from Games with A (T-386), the picker after an app (T-387), the T-376 hw items.

## Inbox

One line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

Triaged 2026-11-10 (lead-9): the lines before are verbatim in [`STATUS-parked.md`](STATUS-parked.md), "Inbox triage 2026-11-10 (lead-9)"; they became T-427 (Bluetooth leftovers), T-428 (Store follow-ups), T-429 (test harness), T-430 (GlassShadow/AppArt masks, L0 memory), T-147 item 6 (launch follow-ups), T-282 item 12 (keyboard over glass), or owner questions (CPU per game, `core.hooksPath`).

- (T-147 reviews) Launch and quick-menu follow-ups: a running app with no Library card behind Home cannot be resumed (offer Resume or Switch to in the quick menu while apps are behind Home); `Notifications.requeue` counts `shownCount` twice; an `AppExited` before the ok answer can end a launch on an older instance's exit, and Close before ok has no instance to stop; the Running pill on the Games grid (Home only today); the Home shrink-into-card transition (04 §5.1, a `pageMs` fade today); older device toasts are not capped at 30 characters; a Steam launch path in Session1, and one line in Details saying why a Steam game has no Play; consider showing Close on the splash before 20 s; add the state pill over a saturated tint to the contrast gate.
- (T-462) `GlassSheet` bakes L0 once on opening: a picker opened within `pageMs` of a page keeps a half-faded wallpaper blur until it closes; re-bake when `wallpaperBlur`/`backdropBlur` settles (T-430 or a glass task).
- (T-462) `dev.ps1 shots > file` loses the Write-Host lines under PowerShell 5.1: log runs with `*>` or `Tee-Object` (T-429).
- (T-458) Closing is shell state (`closingInstances`), not the service's `stopping`: Session.cpp does not refresh the running list after Stop, so a shell restart mid-close shows Running; refresh after Stop and read `state == "stopping"`.
- (T-458 review) Mock paths and tests for Stop answering `unknown-instance` (`stopRefused`) and for a "killed" exit whose record is gone (the silent branch of `closeEnded`).
- (T-458) A Force close action in the Hub for a game still listed after the kill (the warning toast says "Restart the console"; Scope 4 left it out): owner's call.
- (T-458 UX) The closing screen has no hint bar; a lone "Guide Menu" hint would show the Hub is reachable (optional).
- (T-452 review) Hub Performance follow-ups: a test that RAM/VRAM take the worse state when used and total differ; `pendingChoice` keeps its target until close if an ok SetOutput lands elsewhere; a `listBox` height binding loop at QuickMenu.qml:750 (seen in tst_hub_pause); the interval as a Settings row if wanted; confirm the copy "(last reading)".
- (T-452 UX) Quick-menu panel text size and contrast at 10 ft (readings are small, as in the other panels); reading rows take focus but do nothing.
- (T-452 design) Gate `textDim` on the Hub pill fill and `focusFill` in `tst_theme_contrast`, so "textDim only on opaque surfaces" is checked for Hub rows.
- (lead-11 Dell study) Superfluous Returnz segfaults at start on 0.0.64 (status 139 after 5 s): was it running before?
- (lead-11 Dell study) The compositor takes 4-11 % of a core while a game is in front; BombSquad and Asteroid Shooter busy-loop at their menus (116 %, 100 %): measure with T-455.
- (lead-11) T-453 round 1 reviewers: Hub reading rows take focus but do nothing (UX); the listBox height binding loop (QuickMenu.qml ~811) shows in tst_hub_performance and tst_hub_pause.
- (lead-10) Untriaged follow-ups from T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450, T-459, T-460, T-428 and the Dell launch test are verbatim in `STATUS-parked.md`, "Inbox lines lead-10 (untriaged)": plan them at the next planning pass (some feed T-452..T-455, T-461, T-462).

- (lead-9, second triage) The lines from T-423, T-421 and T-424 are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-10 (lead-9, second)"; they became T-431 (image hardening), T-432 (SELinux domains), T-433 (quick-xml, zbus 6, CI actions), T-434 (glass cost, Performance rows), T-435 (ACBR window, orphaned scopes), T-430 and T-282 additions, T-425 (release profile) and the next-image list.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | The Dell (Intel UHD 630, 8 GB, Secure Boot) boots the installer ISO to the shell, greenboot green, `vm-session-check.sh` 45 PASS (0.0.44). No frame times yet. Checks: the Dell look-at list. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123, T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting. |
| B-006 | Controllers for games and the input service (ADR-024, replaces the old InputPlumber line) | Linux + controllers | Now the tasks T-366..T-374 (spike first); games see no pad today (physical nodes are shell-only). Key repeat, stick repeat, long-press, PIN pairing, player assignment go to T-366's design and ADR-017's tasks. |
| B-007 | `ruya-devices` remainder: `ambient`/`media` levels on app streams (sound for profile apps is done: T-365, a pulse server per profile) | `ruya-session` in the image | Audio and network are done and VM-verified (ADR-010). Media access on `/run/media/ruya-shell/...` for profile users belongs to the Media task. |

## Open owner decisions

The long form of each, with options and recommendations: `STATUS-parked.md`, "Open owner decisions before the 2026-11-11 trim".

- **Backups on USB hold account tokens (T-215):** leave credential files out (recommended) or encrypt with the PIN.
- **Admin PIN typed in Ruya Web (ADR-029):** accept with a lockout that cannot lock the TV out (recommended, T-404) or confirm on the TV.
- **Idle-session takeover by another pad (T-396/T-397):** removed from the plan; say if you want it.
- **Release security (T-426, later):** signing key holder, disk encryption, refused Flathub permissions.
- **Ludusavi manifest licence (ADR-028, T-400)**; **telemetry backend and notice (T-224/T-225)**; **parked:** `.play` (T-228), Epic (T-270, ADR-018).
- **Pad art and glyph licence (T-199)**; **brand/logo (T-269)**; **drive formats (T-332)**.
- **A cap on frozen games (T-464..T-466, lead-11 Dell study):** a frozen game costs no CPU but 0.2-1.3 GB (an STK race 1.0 GB); 8 GB fits two frozen heavy games plus one running. Recommended: no cap now, zram (T-465) first; revisit with Proton titles.
- **Small ones:** CPU per game (T-363), Dolby/DTS names (T-219), update size (T-195), HDR/VRR (T-218/T-222), Flatpak runtime in a dev image (T-214), dev ISO erases disks (B-002), preinstalled apps (T-248), a spare low-tier PC, one admin, Turkish review, WSL VHD off C:.

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-10 · Opus 5.5 · Lead (lead-10: T-434, T-435, T-449, T-451, T-448, T-429, T-457, T-450, T-459, T-460, T-428 merged; lead T-447 Hub design; planned ADR-033 Ruya Hub, ADR-034 XWayland, T-447..T-462) · test 1168 QML + 96 skips ALL GREEN; VM 0.0.62 and 0.0.63 PASS (4 stale checks fixed); Dell 0.0.63; CI green. Owner: Hub first then Input; Hub pauses games; XWayland as compatibility layer. Dell: Close dropped for pygame windows (T-459), 5 of 10 apps run. Process: cheaper reviews (targeted checks, delta rounds, narrower UX/design, shots once, T-462).

- 2026-11-10 · Opus 5.5 · Lead (lead-9: T-423 CI gates, T-421 Dell glass, T-424 security baseline, T-147 launch and quick menu merged; T-427..T-435 planned from the Inbox) · test 1063 QML + 89 skips ALL GREEN; no image; 0.0.61 VM: vm-security-check PASS. CI red fixed (host-dependent battery test, two T-421 races, a yanked crate); CI image job manual-only (owner); gh signed in. Review: T-147 deleted 9 tests silently, T-424 baseline hid weaknesses. Owner: drift rests after 30 s. Process: lost-tests.sh in review and self-check; fuzzy tryCompare rule; builder file prune.

- 2026-11-10 · Fable 5 · Planning (plan audit: rules, board, 159 open tasks; no code) · 76 task files got a ruling under the header (overlaps in input, saves, runners, permissions, Web cut to one owner each; about 60 dependency fixes); T-315 stale claim reset; T-258, T-403, T-413 blocked; new T-422 plan lint, T-423 CI gates, T-424 security baseline, T-425 dev/release image, T-426 release-security epic; 5 owner questions. Process: Depends column = open dependencies; sizes, hand-off threshold and roles made consistent; template has Complexity and a security line; planning horizon rule. `dev.ps1 docs` green.

- 2026-11-10 · Opus 5.5 · Lead (lead-8: T-363, T-377, T-359, T-386 Play starts games, T-387 glass after an app merged; T-379 not reproducible; planned ADR-025..ADR-031 (GE-Proton, downloads, controller ownership, games and saves, Web, Companion, developer platform) and T-378..T-419) · test 1029 QML + 84 skips ALL GREEN; VM 0.0.60 queue PASS after three check fixes; Dell 0.0.60 (glass and launch bugs found there). Process: vm-queue.ps1, dell-update.sh, image-chain SKIP_BUILD, a pre-commit lint hook (needs core.hooksPath).

- 2026-11-09 · Opus 5.5 · Lead (lead-7: T-340, T-348, T-376, T-361, T-360 merged; lead T-365 profile sound, T-375 BlueZ kernel HID; plans ADR-024 Ruya Input T-366..T-374, T-359..T-364, T-376, T-377; Hub analysis) · test 1012 QML ALL GREEN; VM 0.0.59 check/display PASS, restart FAIL then fixed (zbus unixexec); Dell 0.0.59: STK sound as ruya-p1, bluetoothd 10-12 % to 0. Process: lints refuse conflict markers and jq; stalled-builder rule.


