# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-04 (Opus 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`), updates (`ruya-update`: manual, daily check, idle restart at night), the Guide key. Against the mock: Store UI, Games page, art-led Home (T-111, T-113, T-146). **The shell is the compositor (T-130, vm-verified):** cage is gone, `ruya-shell` runs on KMS (eglfs) and shows Wayland clients fullscreen in its app layer; Guide stays with the shell.
- **Not started:** `ruya-session` in the image (T-139 built the core, dev mode only; unit, policy and the real spawner are next, unblocked by T-130), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has been launched from the shell's own UI yet (a test client ran as a Wayland app, T-130).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-169** (T-160 + T-163 are in flight as one image build)

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents, at most two at a time in their own worktrees and in different areas, has each branch reviewed by `ruya-reviewer`, and merges it (`docs/LEAD.md`, build loop). Dispatched builders never edit this file. At most one task with a "VM (this task)" criterion runs at a time. A builder session the owner starts directly takes NEXT in the main checkout, alone, and does the bookkeeping itself (`CLAUDE.md`).

Open work only (todo, in-progress, blocked), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-160](tasks/T-160-greenboot-wanted-check.md) | Greenboot: no failing wanted check on a healthy boot | in-progress | — |
| [T-163](tasks/T-163-ruya-library-in-the-image.md) | `ruya-library` in the image: installed Flatpaks over the real bus | in-progress | — |
| [T-169](tasks/T-169-dev-ps1-fresh-worktree.md) | `dev.ps1 test` green first time in a fresh worktree and after a merge | in-progress | — |
| [T-162](tasks/T-162-ruya-session-in-the-image.md) | **[lead]** `ruya-session` in the image: real spawner, unit, bus policy | todo | — |
| [T-164](tasks/T-164-per-profile-wayland-sockets.md) | **[lead]** Per-profile Wayland sockets: a profile's app appears in the shell | todo | T-162 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-164 |
| [T-171](tasks/T-171-store-facade-robustness.md) | Store: no ghost jobs when the service restarts; no null-binding warnings | todo | — |
| [T-170](tasks/T-170-settings-pane-polish.md) | Settings panes: no clipped top rows; Bluetooth and Storage pane fixes | todo | T-137 |
| [T-172](tasks/T-172-hint-bar-follow-ups.md) | Hint bar follow-ups: one Sections hint, wizard hints, per-page overrides | todo | — |
| [T-161](tasks/T-161-controller-battery.md) | Controller battery: `Devices1` over UPower, status cluster, low-battery toast | todo | T-157 |
| [T-173](tasks/T-173-devices-bluetooth-service.md) | `ruya-devices`: `Devices1.Bluetooth` over BlueZ | todo | — |
| [T-174](tasks/T-174-devices-storage-service.md) | `ruya-devices`: `Devices1.Storage` over udisks2 | todo | T-137 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |
| [T-144](tasks/T-144-contrast-and-accessible-names.md) | Design review: contrast over the backdrop, accessible names | todo | T-143 |
| [T-166](tasks/T-166-suspend-under-eglfs.md) | **[lead]** Suspend and resume with the shell on KMS (eglfs) | todo | — |

**VM queue** (done on the host, VM check pending; the lead runs them with one image build): T-159 (`vm-update-check.sh reboot`).

## Inbox

Follow-ups and debt for the next planner, one line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

- (T-159) `image/build/90-initramfs.sh` prints `dracut-install: ERROR: installing '/root'` (the initramfs is still written); check at the next VM boot whether it matters, else silence it.

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

- 2026-11-04 · Opus 5.5 · Lead (review `9b77857..4bd0c66`: T-155, T-157, T-130 diff; T-159 skimmed) · `test` ALL GREEN (267 QML + 21 skips, 242 Rust), `shots` 56, CI green at `945a60f` (one shell flake at `18a342a` → T-167); 0 review findings. Disks full twice: WSL disk grew 7 → 29 GB per build; `free-space.ps1` + `wsl --manage --compact`. Owner: builder agents in worktrees (2 lanes), Opus review before merge, lead-only STATUS, image builds only in image tasks (VM queue). Planned T-162..T-168. Paused by the owner mid-loop: see LEAD-NOTES.

- 2026-11-04 · Sonnet 5.5 · T-159 · `ruya-update` announces the automatic restart (`restart_at`, 120 s grace in `Schedule::restart_step`; input, setting off or nothing staged calls it off) and retries a failed scheduled download after an hour (manual ones never). Shell: sticky warning toast (`Notifications.showSticky`), every press reported while pending; Turkish. Build fix in `99-cleanup.sh` (kernel 7.2.15 leftovers in /boot and /var/lib/rpm-state; `0.0.29-t159a` passed the lint). `test` ALL GREEN (271 QML + 22 skips, 70 Rust in the crate), `shots` 57 reviewed. VM PENDING: lead runs `vm-update-check.sh reboot`. Inbox +2.

- 2026-11-03 · Sonnet 5.5 · T-157 · Material Symbols Rounded subset (3 icons, two static cuts, ~2 KB each) via `scripts/subset-icons.sh` (pinned commit, SHA-256), `Icon.qml` + `Theme` icon tokens, `lint-icons.ps1`; the Settings pill and volume OSD use it; licence in `/usr/share/licenses/ruyaos/`. `test` ALL GREEN (267 QML + 21 skips), `shots` reviewed. VM `0.0.28-t157`: `RUYA_BOOT_OK`, licence present, gear drawn. Test host loads fonts in `qmlEngineAvailable` (Setup precedes QGuiApplication). Inbox +2. Lead review due after 2-3 more tasks.

- 2026-11-02 · Sonnet 5.5 · T-155 · Accept pulse moved from `Tile` into `ArtCard.pulse()` (the art shrinks to `pulseScale`, so no clash with the focus scale), run on Accept in the Home Recent row (`playRecent`) and the Games grid (`acceptCurrent`); `Tile.qml` deleted. Reduced-motion test retargeted to `ArtCard`; new Accept tests in `tst_motion` (Recent, plus launch still happens under reduced motion) and `tst_games`. `test` ALL GREEN (258 QML + 21 skips); no screenshot change. Lead review due after 2-4 more tasks.

- 2026-11-02 · Opus 5.5 · Lead (T-130; no review, nothing landed since `39b25f2`) · `ruya-shell` is the compositor on KMS, cage removed; input devices by a `uaccess` rule (lead decision); `KeyRouter` takes Guide from any item inside an app. `test` ALL GREEN (256 QML + 21 skips), `shots` 56. VM `0.0.26-t130`, fresh disk: `RUYA_BOOT_OK`, no cage, wizard and picker over the real bus, T-123 sequence and a held Guide over a test client. Drill: update to `0.0.27`, rollback, a broken compositor rolled back by greenboot after 4 boots. Process: drill step 5 recipe, `/NUL` git-ignored. Inbox +3. Host drives 99 % full (owner).
