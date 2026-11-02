# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-02 (Sonnet 5.5, T-154)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`), updates (`ruya-update`, manual only), the Guide key. Against the mock: Store UI, Games page, art-led Home (T-111, T-113, T-146). ADR-002 option A proven (T-123); T-130 (lead) makes the shell the session.
- **Not started:** `ruya-session` in the image (T-139 built the core, dev mode only; unit, policy and the real spawner follow T-130), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has ever been launched from the shell.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-155**

**Lead review due** after 2–4 more builder tasks (reviewed up to the lead commit "lead review 300245c..e19899f", see `docs/LEAD-NOTES.md`). **One builder session at a time, one task per session:** two builders in one checkout mixed three tasks' work on 2026-10-28. Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage  | todo | T-150 |
| [T-155](tasks/T-155-card-accept-pulse.md) | Accept pulse on art cards; remove the unused `Tile` | todo | T-146 |
| [T-157](tasks/T-157-icon-font.md) | Icon font (Material Symbols Rounded) and `Icon` | todo | — |
| [T-158](tasks/T-158-hint-bar.md) | Hint bar with controller button glyphs | todo | T-157 |
| [T-144](tasks/T-144-contrast-and-accessible-names.md) | Design review: contrast over the backdrop, accessible names | todo | T-143 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-130, T-138, T-146 |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.

- (T-154) Tell the user before an automatic restart (toast or countdown, and a way to postpone); today `ruya-update` just runs `systemctl reboot` at night when idle.
- (T-154) A scheduled download that fails is not retried until the next check (24 h); retry it after an hour like a failed check.
- (T-154) When `ruya-session` runs apps it must call `Update1.ReportActivity(true)` (the shell only knows about its own app layer), and a headless/idle app should keep reporting so a long movie is not restarted over.
- (T-153) Greenboot's wanted script `01_update_platforms_check.sh` fails on every VM boot ("wanted", so harmless); find out what it checks or drop it.
- (lead) The status cluster's controller battery (04 §2) needs battery data: a `Devices1` contract over UPower in `ruya-devices` with its VM check, not a mock-only pane; plan it after T-157 (its icon comes from that set).

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | A dev ISO exists (`output/bootiso/`, holds the dev SSH key: test machines only). Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating), stick repeat speed, Accept long-press and context menu (spec 02 §4.3). |
| B-007 | `ruya-devices` remainder: BlueZ part (contract T-136), applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` after T-130 | Audio (T-128, by events since T-133) and network (T-132) are done and VM-verified. ADR-010. |

## Open owner decisions

- **WSL ext4 corruption: apparently fixed 2026-10-27, watch it.** After recreating the distro with `memory=8GB` and `nestedVirtualization=false` (backup `.wslconfig.bak-2026-10-27`; the earlier "disk 3" Windows errors belong to an empty card reader, not an SSD), a full `build.sh`, `make-disk.sh qcow2` and a VM session ran with no `ext4` error in `dmesg`. Not proven whether RAM pressure at 20 GB or the old distro was the cause. If it returns: Windows Memory Diagnostic or memtest86, then move the VHD to the D: SSD (about 63 GB free; clear `output/` first). Claude recreates the distro itself (owner said so).
- **Host disk or RAM, watch it (2026-10-28):** a file in the cargo registry on C: (`zbus-5.19.0/src/address/transport/mod.rs`) had turned into null bytes; re-extracted from the checksummed `.crate`, no other zeroed files. Together with the earlier WSL `ext4` errors (also on C:) this hints at the C: drive or RAM. Recommendation: run Windows Memory Diagnostic and the drive maker's SMART check; not blocking.
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): icon set Material Symbols Rounded, ADR-013 (owner, 2026-11-01); design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 4 lines: date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-02 · Sonnet 5.5 · T-154 · `ruya-update` schedule (`schedule.rs`, fake clock): check at start and every 24 h, scheduled check downloads, restart via `systemctl reboot` at 03:00-05:00 after 30 idle minutes with no app; `SetAutoRestart` (admin) + Settings switch, `ReportActivity` from the shell. `test` ALL GREEN (254 QML, 56 Rust), `shots` reviewed. VM `0.0.24-t154`->`0.0.25-t154`: guest clock moved to 03:10, the service rebooted the guest, cold start `RUYA_BOOT_OK`; `settings` ALL PASSED, exposure 4.8 OK. Shell D-Bus client unverified. Lead review due after 2-4 more tasks.

- 2026-11-02 · Sonnet 5.5 · T-156 · `GetApp` returns `new_permissions` (installed vs remote metadata); a Standard profile needs an admin's PIN to update an app whose update adds a high-risk permission. The shell never called `GetApp` (permissions empty over D-Bus, so T-152's gate was dead there): the page now loads them first. `test` ALL GREEN (247 QML, 46 store Rust), `shots` reviewed. VM `0.0.23-t156`: `vm-store-check.sh` ALL CHECKS PASSED. A real permission-adding update unverified. Lead review due after 1-3 more tasks.

- 2026-11-02 · Sonnet 5.5 · T-153 · `ruya-update`: rollback holds the command lock, no switch to a tagless reference, a bad channel file reports `failed` instead of stopping the service, forbidden string in Settings. `test` ALL GREEN (243 QML, 32 Rust in the crate). VM `0.0.22-t153`: bad channel file boots healthy, `vm-update-check.sh` ALL PASSED, 4.8 OK. Lead review due after 2-4 more tasks.

- 2026-11-01 · Opus 5.5 · Lead (review `300245c..e19899f`: T-149, T-151, T-113, T-152, T-146) · `test` ALL GREEN (242 QML + 20 skips, 207 Rust, 63 s); `shots` ALL GREEN (55, 36 s; every Home, Games and Store-PIN screen reviewed). CI green at `300245c`. No VM run (T-151's `0.0.21-t151` covers the only packaged change).
  Findings 8 fixed / 4 filed: art cards were 2.2:1 not 16:9, focused Home pill showed no ring, stray letter mid-hero, hero art missed its first value, vacuous ArtCard test, `Theme.hairline` added (`hairlineAt(u)`), 04 glass rows, stale comments; `ruya-update` rollback race, empty tag, fatal channel file → T-153, update adding a high-risk permission → T-156.
  Planned T-153..T-156; Inbox emptied (2 dropped: art-roles line was wrong; user-installed Flatpak games are outside the contract). Escalated: icon set. Process: parallel review subagents (`LEAD.md` 3); geometry criteria need a property test (`PLANNING.md` Lessons).
  Owner chose Material Symbols Rounded (ADR-013, 04 §3.7): planned T-157 (icon font, `Icon`, gear and OSD) and T-158 (hint bar).

- 2026-10-31 · Sonnet 5.5 · T-146 · Art-led Home: hero art, hero block (Play/Details), Recent row, glass section nav with LB/RB, empty state; 5 new tokens, 5 components, `tst_home` (13 tests), 15 test files moved off the tiles. `test` ALL GREEN (241 QML). `shots` NOT run (session locked): screenshots unreviewed. Lead review is due.
