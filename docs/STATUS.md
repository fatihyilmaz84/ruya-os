# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-01 (Opus 5.5, lead review)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`), updates (`ruya-update`, manual only), the Guide key. Against the mock: Store UI, Games page, art-led Home (T-111, T-113, T-146). ADR-002 option A proven (T-123); T-130 (lead) makes the shell the session.
- **Not started:** `ruya-session` in the image (T-139 built the core, dev mode only; unit, policy and the real spawner follow T-130), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has ever been launched from the shell.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-153**

**Lead review due** after 3–5 more builder tasks (reviewed up to the lead commit "lead review 300245c..e19899f", see `docs/LEAD-NOTES.md`). **One builder session at a time, one task per session:** two builders in one checkout mixed three tasks' work on 2026-10-28. Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage  | todo | T-150 |
| [T-153](tasks/T-153-update-review-fixes.md) | `ruya-update` review fixes: races, empty tag, corrupt channel file | todo | T-151 |
| [T-156](tasks/T-156-update-high-risk-pin.md) | Admin PIN before an app update that adds a high-risk permission | todo | T-152 |
| [T-154](tasks/T-154-update-schedule-and-idle-reboot.md) | `ruya-update`: daily check, automatic download, reboot when idle | todo | T-153 |
| [T-155](tasks/T-155-card-accept-pulse.md) | Accept pulse on art cards; remove the unused `Tile` | todo | T-146 |
| [T-144](tasks/T-144-contrast-and-accessible-names.md) | Design review: contrast over the backdrop, accessible names | todo | T-143 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-130, T-138, T-146 |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.

(empty)

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
- **Icon set (new, 2026-11-01; owner-level by `04` §8):** Home's Settings pill is a gear character that Windows draws as a colour emoji, and the planned controller-battery item and hint bar (A/B glyphs) need icons too. Options: Material Symbols Rounded (Apache-2.0, variable font), Lucide (ISC, line icons), Phosphor (MIT). Recommendation: **Material Symbols Rounded**, a subset bundled as a font like Inter; button glyphs drawn as letters in circles. Blocks: the gear, the battery item, the hint bar.
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 4 lines: date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-01 · Opus 5.5 · Lead (review `300245c..e19899f`: T-149, T-151, T-113, T-152, T-146) · `test` ALL GREEN (242 QML + 20 skips, 207 Rust, 63 s); `shots` ALL GREEN (55, 36 s; every Home, Games and Store-PIN screen reviewed). CI green at `300245c`. No VM run (T-151's `0.0.21-t151` covers the only packaged change).
  Findings 8 fixed / 4 filed: art cards were 2.2:1 not 16:9, focused Home pill showed no ring, stray letter mid-hero, hero art missed its first value, vacuous ArtCard test, `Theme.hairline` added (`hairlineAt(u)`), 04 glass rows, stale comments; `ruya-update` rollback race, empty tag, fatal channel file → T-153, update adding a high-risk permission → T-156.
  Planned T-153..T-156; Inbox emptied (2 dropped: art-roles line was wrong; user-installed Flatpak games are outside the contract). Escalated: icon set. Process: parallel review subagents (`LEAD.md` 3); geometry criteria need a property test (`PLANNING.md` Lessons).

- 2026-10-31 · Sonnet 5.5 · T-146 · Art-led Home: hero art, hero block (Play/Details), Recent row, glass section nav with LB/RB, empty state; 5 new tokens, 5 components, `tst_home` (13 tests), 15 test files moved off the tiles. `test` ALL GREEN (241 QML). `shots` NOT run (session locked): screenshots unreviewed. Lead review is due.

- 2026-10-30 · Sonnet 5.5 · T-152 · Standard profiles enter an admin's PIN (`PinPad` + `Profiles.verifyAdmin`) before Install of a high-risk app; note under the permissions; 4 tests, `20` reviewed. `test` and `shots` ALL GREEN (226 QML). Lead review is due after 1-2 more tasks.

- 2026-10-30 · Sonnet 5.5 · T-113 · `Library` singleton (mock + unverified D-Bus client), `ArtCard`, real Games page (4-column grid, source filter, launch request + toast, empty state). `test` ALL GREEN (220 QML), `shots` ALL GREEN, `21` reviewed. `tst_pages` retargeted from the old placeholder. Lead review is due after 1-2 more tasks.

- 2026-10-30 · Sonnet 5.5 · T-151 · `ruya-update` (bootc) + `forbidden` in XML/mock/test, unit, policy, greenboot check. `test` ALL GREEN (210 QML, 25 new Rust). VM `0.0.20`->`0.0.21-t151`: `vm-update-check.sh` ALL PASSED, restart from Settings booted the new version, exposure 4.8 OK.
  Found in the VM: bootc needs `CAP_SYS_PTRACE` and no `RestrictSUIDSGID`. Progress is 0 then 100. Lead review is due after 2-3 more tasks.
