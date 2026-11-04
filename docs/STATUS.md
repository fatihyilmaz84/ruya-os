# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-04 (Opus 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages with one section nav and a hint bar, motion, toasts/OSD, Settings (Profiles, Network, Bluetooth, Audio, Display, Storage, System, About), on-screen keyboard, first-boot wizard, Turkish, accessible names. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`, also a restart mid-install), library (`ruya-library`, T-163), updates (`ruya-update`: manual, daily check, idle restart at night, T-159), the Guide key. Against the mock only: Bluetooth and Storage panes (services T-173, T-174). **The shell is the compositor (T-130, vm-verified).**
- **Not started:** `ruya-session` in the image (T-162, then per-profile sockets T-164), InputPlumber (B-006), installer. No app has been launched from the shell's own UI yet.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-173** (T-161 and T-175 are in flight)

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents, at most two at a time in their own worktrees and in different areas, has each branch reviewed by `ruya-reviewer`, and merges it (`docs/LEAD.md`, build loop). Dispatched builders never edit this file. At most one task with a "VM (this task)" criterion runs at a time. A builder session the owner starts directly takes NEXT in the main checkout, alone, and does the bookkeeping itself (`CLAUDE.md`).

Open work only (todo, in-progress, blocked), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-162](tasks/T-162-ruya-session-in-the-image.md) | **[lead]** `ruya-session` in the image: real spawner, unit, bus policy | todo | — |
| [T-164](tasks/T-164-per-profile-wayland-sockets.md) | **[lead]** Per-profile Wayland sockets: a profile's app appears in the shell | todo | T-162 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-164 |
| [T-161](tasks/T-161-controller-battery.md) | Controller battery: `Devices1` over UPower, status cluster, low-battery toast | in-progress | T-157 |
| [T-173](tasks/T-173-devices-bluetooth-service.md) | `ruya-devices`: `Devices1.Bluetooth` over BlueZ | todo | — |
| [T-174](tasks/T-174-devices-storage-service.md) | `ruya-devices`: `Devices1.Storage` over udisks2 | todo | T-137 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |
| [T-166](tasks/T-166-suspend-under-eglfs.md) | **[lead]** Suspend and resume with the shell on KMS (eglfs) | todo | — |

**VM queue** (done on the host, VM check pending; the lead runs them with one image build): empty (T-159, T-160, T-171 verified 2026-11-04 on 0.0.32/0.0.33).

## Inbox

Follow-ups and debt for the next planner, one line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

- (T-159) `image/build/90-initramfs.sh` prints `dracut-install: ERROR: installing '/root'` (the initramfs is still written); 0.0.32 and 0.0.33 print it once each and boot fine (`RUYA_BOOT_OK`, greenboot passed): it doesn't matter, silence it (small image task).
- (T-163 review) `ruya-library`: rescan on Flatpak updates too (the fingerprint is names only; put the deploy commit in it), so a renamed or recategorised app refreshes without `Rescan`.
- (T-163) Home says "Your library is empty" while apps are installed but none was played (`last_played` 0, Recent row only): fall back to installed items, or record `last_played` (T-162/T-147).
- (T-163) `Store1` answers `already-installed` for an app removed outside the Store (`flatpak uninstall`): its installed cache is stale.
- (T-163) Flatpak titles lack appstream names until the remote's appstream is fetched (the VM shows "TestGame").
- (T-171 review) Store: resume or re-query jobs after `ruya-store` comes back (needs a `ListJobs` in `Store1.xml`).
- (T-170 review) Settings panes give no cue that more rows exist below the viewport, now that no cut row hints at it: decide on a scroll affordance (fade, chevron or peek) in 04 §5 (design, lead).
- (T-176 review) lint-tokens weight rule: also handle grouped `font { pixelSize: ... }` and values spread over three or more lines (none in the tree).
- (T-176) PowerConfirm's buttons are named "Cancel"/"Confirm": name them after the action ("Restart now") for screen readers; the wizard's create-name-and-PIN step and the profile add/manage flows are not walked by `tst_accessibility` yet.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | Build a fresh dev ISO first (the 0.0.4 one was deleted to free space on 2026-11-02; it holds the dev SSH key: test machines only). Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. Also check the hint bar's spacing to the Settings list's last row at 1080p (T-158). |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123) and the session built (T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating), stick repeat speed, Accept long-press and context menu (spec 02 §4.3), and Bluetooth PIN/passkey pairing, player assignment, button test and remapping (T-136). |
| B-007 | `ruya-devices` remainder (BlueZ is now T-173): applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` in the image (T-130 done) | Audio (T-128, by events since T-133) and network (T-132) are done and VM-verified. ADR-010. |

## Open owner decisions

- **Host disk or RAM, watch it:** WSL `ext4` errors (gone since the distro was recreated with `memory=8GB`, `nestedVirtualization=false` on 2026-10-27) and a zeroed cargo file (2026-10-28), both on C:. Recommendation: Windows Memory Diagnostic and the drive maker's SMART check; not blocking. If `ext4` errors return, move the VHD to the D: SSD (clear `output/` first); Claude recreates the distro itself (owner said so).
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): builders as `ruya-builder` agents in worktrees (two at a time), a `ruya-reviewer` verdict before every merge, the lead as the only writer of STATUS (owner, 2026-11-04, after comparing with Tinwave); image builds only in image-heavy tasks, logic tasks go to the lead's VM queue, every image build ends with `scripts\free-space.ps1` (owner, 2026-11-03); icon set Material Symbols Rounded, ADR-013 (owner, 2026-11-01); design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-04 · Opus 5.5 · Lead (build loop resumed; range `2c134ce..` merged T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144, each after `ruya-reviewer`; 6 CHANGES_REQUESTED, 3 lead fixes) · `test` 327 QML + 28 skips, `shots` 69 ALL GREEN. VM `0.0.32`/`0.0.33`: store check 48 PASS, update drill ALL PASSED, idle reboot, rollback kept: T-159/T-160/T-171 vm. Planned T-169..T-175. Process: git/cmake on PATH are devkitPro's (worktree links), per-checkout test log, .ts merge recipe, lane counts to merge.

- 2026-11-04 · Opus 5.5 · Lead (review `9b77857..4bd0c66`: T-155, T-157, T-130 diff; T-159 skimmed) · `test` ALL GREEN (267 QML + 21 skips, 242 Rust), `shots` 56, CI green at `945a60f` (one shell flake at `18a342a` → T-167); 0 review findings. Disks full twice: WSL disk grew 7 → 29 GB per build; `free-space.ps1` + `wsl --manage --compact`. Owner: builder agents in worktrees (2 lanes), Opus review before merge, lead-only STATUS, image builds only in image tasks (VM queue). Planned T-162..T-168. Paused by the owner mid-loop: see LEAD-NOTES.

- 2026-11-04 · Sonnet 5.5 · T-159 · `ruya-update` announces the automatic restart (`restart_at`, 120 s grace in `Schedule::restart_step`; input, setting off or nothing staged calls it off) and retries a failed scheduled download after an hour (manual ones never). Shell: sticky warning toast (`Notifications.showSticky`), every press reported while pending; Turkish. Build fix in `99-cleanup.sh` (kernel 7.2.15 leftovers in /boot and /var/lib/rpm-state; `0.0.29-t159a` passed the lint). `test` ALL GREEN (271 QML + 22 skips, 70 Rust in the crate), `shots` 57 reviewed. VM PENDING: lead runs `vm-update-check.sh reboot`. Inbox +2.

- 2026-11-03 · Sonnet 5.5 · T-157 · Material Symbols Rounded subset (3 icons, two static cuts, ~2 KB each) via `scripts/subset-icons.sh` (pinned commit, SHA-256), `Icon.qml` + `Theme` icon tokens, `lint-icons.ps1`; the Settings pill and volume OSD use it; licence in `/usr/share/licenses/ruyaos/`. `test` ALL GREEN (267 QML + 21 skips), `shots` reviewed. VM `0.0.28-t157`: `RUYA_BOOT_OK`, licence present, gear drawn. Test host loads fonts in `qmlEngineAvailable` (Setup precedes QGuiApplication). Inbox +2. Lead review due after 2-3 more tasks.

- 2026-11-02 · Sonnet 5.5 · T-155 · Accept pulse moved from `Tile` into `ArtCard.pulse()` (the art shrinks to `pulseScale`, so no clash with the focus scale), run on Accept in the Home Recent row (`playRecent`) and the Games grid (`acceptCurrent`); `Tile.qml` deleted. Reduced-motion test retargeted to `ArtCard`; new Accept tests in `tst_motion` (Recent, plus launch still happens under reduced motion) and `tst_games`. `test` ALL GREEN (258 QML + 21 skips); no screenshot change. Lead review due after 2-4 more tasks.
