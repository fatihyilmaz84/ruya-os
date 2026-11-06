# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-06 (Sonnet 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages with one section nav and a hint bar, motion, toasts/OSD, Settings (Profiles, Network, Bluetooth, Audio, Display, Storage, System, About), on-screen keyboard, first-boot wizard, Turkish, accessible names. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`, also a restart mid-install), library (`ruya-library`, T-163), updates (`ruya-update`: manual, daily check, idle restart at night, T-159), the Guide key, launching apps (`ruya-session`: Launch/Stop/crash/kill and the shell's `Session` client over the real bus, T-162). Against the mock only: Bluetooth and Storage panes (services T-173, T-174). **The shell is the compositor (T-130, vm-verified).**
- **Not started:** per-profile Wayland sockets (T-164: an app's window appears in the shell), InputPlumber (B-006), installer. No app has been launched from the shell's own UI yet.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-164** ([lead], the critical path: per-profile Wayland sockets, so an app's window appears). **Owner, 2026-11-06 (later): the hold is lifted for T-189..T-194, dispatch them; still no new tasks are created until the owner says so.** Lanes: T-189 and T-192.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents, at most two at a time in their own worktrees and in different areas, has each branch reviewed by `ruya-reviewer`, and merges it (`docs/LEAD.md`, build loop). Dispatched builders never edit this file. At most one task with a "VM (this task)" criterion runs at a time. A builder session the owner starts directly takes NEXT in the main checkout, alone, and does the bookkeeping itself (`CLAUDE.md`).

Open work only (todo, in-progress, blocked), in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-189](tasks/T-189-test-gate-vacuous-assertions.md) | Test gate: catch assertions that cannot fail (undefined reads, NaN waits) | in-progress | — |
| [T-192](tasks/T-192-store-service-async-and-changed-signal.md) | ruya-store: Flatpak calls off the D-Bus executor; corrections announce themselves | in-progress | — |
| [T-193](tasks/T-193-vm-script-robustness.md) | VM scripts: no false passes, no leftovers | todo | — |
| [T-190](tasks/T-190-settings-pane-focus-follow-ups.md) | Settings panes: look-ahead after relayout, Tab, peek legibility | todo | — |
| [T-191](tasks/T-191-shell-backend-race-follow-ups.md) | Shell backends: Profiles guard, Store reconcile races, `working` from the job list | todo | — |
| [T-194](tasks/T-194-confirm-buttons-name-the-action.md) | Confirm dialogs: the button says the action; TextEntry cancel cue | todo | — |
| [T-195](tasks/T-195-slim-the-image.md) | Slim the image: only what the UI, the services and gaming need; a manifest with reasons | todo | — |
| [T-164](tasks/T-164-per-profile-wayland-sockets.md) | **[lead]** Per-profile Wayland sockets: a profile's app appears in the shell | todo | T-162 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-164 |
| [T-166](tasks/T-166-suspend-under-eglfs.md) | **[lead]** Suspend and resume with the shell on KMS (eglfs) | todo | — |

**VM queue** (done on the host, VM check pending; the lead runs them with one image build): empty (T-182, T-183, T-184, T-188 verified 2026-11-06 on `0.0.42-lead`).

## Inbox

Follow-ups and debt for the next planner, one line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Plan at 5+ items.

- (T-162) `ruya-session` forgets running apps when it restarts (they keep running; a relaunch then fails with `launch-failed`, the unit name is taken): adopt `ruya-app-*` units of every profile manager on start.
- (T-162) An app whose binary cannot be executed (exec 203) reports `crashed` with code 203, not `launch-failed`: map exec failures.
- (2026-11-06) Owner's new F: drive (NTFS, 119 GiB, USB): move `output/` (qcow2, ISO) to it with a junction when no VM or build runs; keep cargo and podman caches internal.
- (Dell, 2026-11-06) `bootloader-update.service` fails on the Dell: Secure Boot is on and the firmware lacks the Microsoft UEFI CA 2023 (bootupctl refuses to update). Harmless to booting, but a red unit on every boot: decide on tolerating it (a drop-in with `SuccessExitStatus=1`?) or documenting Secure Boot as off for test machines. Also the Dell's hostname became its IPv6 address (DHCP hostname): set a static `ruyaos` hostname.
- (Dell, 2026-11-06) On real Intel hardware the shell logs `Failed to initialize EGL display. There is no EGL_WL_bind_wayland_display extension` (as in the VM): GL clients cannot hand buffers to the compositor that way. T-164 must pick a Qt Wayland hardware integration that works on the KMS display (`linux-dmabuf-v1` / dmabuf) and test a GL client on the Dell, not only the software test client (B-003).
- (0.0.40 try-out) The VM clock shows UTC: there is no time-zone setting yet (wizard or System pane); plan it with the OOBE/installer work.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | **Second install 2026-11-06 with the `0.0.44-t162` ISO: boots to the shell by itself, greenboot green, `vm-session-check.sh` 45 PASS on the hardware. First install (Dell, Intel UHD 630, 8 GB, UEFI with Secure Boot):** the 0.0.40 ISO booted to a text login (T-178 bug); after `systemctl set-default graphical.target` + `isolate` the shell runs on KMS (Mesa gallium, eglfs_kms, ~20 % of one core idle, no warnings, all services active), and the owner created a profile and signed in. No frame times yet. The dev ISO of `0.0.44-t162` is `F:\RuyaOS
uyaos-0.0.44-t162-install.iso` (dev SSH key: test machines only); the 4 Nov ISO (0.0.40) boots to a text login (T-178 bug), do not use it. Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. Also check the hint bar's spacing to the Settings list's last row at 1080p (T-158). Hardware checks queued here: Wi-Fi connect/forget under the NetworkManager deny rule (T-180), pads in UPower as kind 12 "gaming-input" (DualSense, Xbox, 8BitDo; else extend `KIND_GAMING_INPUT` in `battery.rs`), a fake UPower device for `vm-devices-check.sh` (umockdev or dbusmock, optional), Bluetooth (adapter, "just works" pairing, Battery1, rfkill-blocked `Powered`, hot-plugged USB adapter). T-178 is done (the ISO boots to the shell in QEMU). The ISO's own boot menu still says "Install Fedora Linux 44" (cosmetic, bib has no product-name setting). |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123) and the session built (T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating; a held Backspace or Esc currently repeats Back and can walk the page stack to Home: decide whether page-level Back ignores `isAutoRepeat`, as the Guide overlay does), stick repeat speed, Accept long-press and context menu (spec 02 §4.3), and Bluetooth PIN/passkey pairing, player assignment, button test and remapping (T-136). |
| B-007 | `ruya-devices` remainder (BlueZ done in T-173, VM check queued): applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` in the image (T-130 done) | Audio (T-128, by events since T-133) and network (T-132) are done and VM-verified. ADR-010. Also: media access for profile users and Flatpak apps on `/run/media/ruya-shell/...` belongs to the Media task (mounts belong to `ruya-shell`, not the active profile). |

## Open owner decisions

- **Host disk or RAM, watch it:** WSL `ext4` errors (gone since the distro was recreated with `memory=8GB`, `nestedVirtualization=false` on 2026-10-27) and a zeroed cargo file (2026-10-28), both on C:. Recommendation: Windows Memory Diagnostic and the drive maker's SMART check; not blocking. If `ext4` errors return, move the VHD to the D: SSD (clear `output/` first); Claude recreates the distro itself (owner said so).
- **Dev ISO on the test machine (B-002, the Dell):** the ISO erases every disk in the machine without asking, puts the dev SSH key on root, and tracks `localhost/ruyaos:dev` (no updates until pointed at a registry). Recommendation: acceptable for a dedicated test machine with nothing on it (unplug other disks), never for anyone else's; a real installer with disk choice is Phase 3. Not blocking T-178.
- **Design canvas (owner):** the board "Settings" needs the peek-row cue and look-ahead scrolling (T-185, 04 §8); the Home empty state (T-183) shows installed apps. Not blocking.
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): Steam (Proton) and RetroArch are separate Store apps too, not in the first MVP (owner, 2026-11-06); blur and shadows stay the default look on hardware that supports them, with the lower tiers as the fallback (owner, 2026-11-06; 04 §1 principle 5, §3.5); the first MVP ships without Plex, Steam Link and similar media/streaming apps: they are separate Store apps, and the focus is the OS, the shell UI and the building blocks (owner, 2026-11-06; `00-overview.md` §2, §6); builders as `ruya-builder` agents in worktrees (two at a time), a `ruya-reviewer` verdict before every merge, the lead as the only writer of STATUS (owner, 2026-11-04, after comparing with Tinwave); image builds only in image-heavy tasks, logic tasks go to the lead's VM queue, every image build ends with `scripts\free-space.ps1` (owner, 2026-11-03); icon set Material Symbols Rounded, ADR-013 (owner, 2026-11-01); design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-06 · Sonnet 5.5 · Lead (T-162 by the lead; no lanes; range had only docs) · `ruya-session` runs in the image: `systemd-run --machine=` per app, status file, scope-aware Stop/kill, linger; unit exposure 1.1; deleting a profile ends its manager. VM `0.0.44-t162`: smoke OK, session check 45 PASS, devices 57. `test` 381 QML + 30 skips, Rust green. VM found: SELinux refuses PID 1 a service's pipe; Flatpak apps live in their own scope; PipeWire was not masked for profiles. New F: drive formatted NTFS, holds the ISO. Process: image/CLAUDE.md quirk.

- 2026-11-05 · Sonnet 5.5 · Lead (build loop from `4c0e713`: T-178..T-188 merged, 11 tasks; 6 CHANGES_REQUESTED, T-187 lead-read) · `test` 381 QML + 30 skips. VM `0.0.42-lead`: smoke, devices 57, store 67, library, storage 98: all PASS (devices needs `-Audio`). Planned T-178..T-194 (T-189..T-194 not dispatched). Owner: media and streaming apps out of the first MVP; blur and shadows stay the default; no new tasks after those in flight. Process: builders run dev.ps1 in their worktree; VM scripts parse JSON, not key order.

- 2026-11-04 · Opus 5.5 · Lead (build loop; from `2c134ce`: T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144, T-175, T-176, T-161, T-173, T-145, T-177, T-174 merged after `ruya-reviewer`, 10 CHANGES_REQUESTED) · `test` 346 QML + 28 skips. VM `0.0.32/.33/.37` (lead), `.34/.36/.38/.39` (builders): update drill + idle reboot, store, devices, BlueZ, UPower, udisks2 all PASS. Lead fixes: drill, store and Bluetooth stop-scan, polkit deny-by-default (review). Owner: Inter download OK. Process: devkitPro git/cmake/ssh, per-checkout log, lane counts to merge.

- 2026-11-04 · Opus 5.5 · Lead (review `9b77857..4bd0c66`: T-155, T-157, T-130 diff; T-159 skimmed) · `test` ALL GREEN (267 QML + 21 skips, 242 Rust), `shots` 56, CI green at `945a60f` (one shell flake at `18a342a` → T-167); 0 review findings. Disks full twice: WSL disk grew 7 → 29 GB per build; `free-space.ps1` + `wsl --manage --compact`. Owner: builder agents in worktrees (2 lanes), Opus review before merge, lead-only STATUS, image builds only in image tasks (VM queue). Planned T-162..T-168. Paused by the owner mid-loop: see LEAD-NOTES.

- 2026-11-04 · Sonnet 5.5 · T-159 · `ruya-update` announces the automatic restart (`restart_at`, 120 s grace in `Schedule::restart_step`; input, setting off or nothing staged calls it off) and retries a failed scheduled download after an hour (manual ones never). Shell: sticky warning toast (`Notifications.showSticky`), every press reported while pending; Turkish. Build fix in `99-cleanup.sh` (kernel 7.2.15 leftovers in /boot and /var/lib/rpm-state; `0.0.29-t159a` passed the lint). `test` ALL GREEN (271 QML + 22 skips, 70 Rust in the crate), `shots` 57 reviewed. VM PENDING: lead runs `vm-update-check.sh reboot`. Inbox +2.
