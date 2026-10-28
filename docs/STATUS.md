# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-10-28 (Opus 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** the shell has pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish translation. Profiles, power, audio (`ruya-devices`, event-driven since T-133), network (`ruya-devices` over NetworkManager, T-132), the store service (`ruya-store` over `flatpak`, T-134) and the Guide key are **vm-verified** over the real bus; the Store UI is T-111. The compositor spike (T-123) proved ADR-002 option A (shell as Wayland compositor on KMS); T-130 (lead) makes it the session.
- **Not started:** `ruya-session` (launch apps; T-138, T-139), `ruya-update` (T-135 is its UI contract), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has ever been launched from the shell.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. **Image and VM work works again since 2026-10-27** (fresh WSL distro, `.wslconfig` `memory=8GB`; image `0.0.13-lead` built, made into a disk and booted `RUYA_BOOT_OK`, T-131 VM-verified). If `ext4` errors return, see the WSL note under Open owner decisions.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-138**

**Lead review due: after 3 more builder tasks** (reviewed up to the lead commit "lead review f835519..7392be4", see `docs/LEAD-NOTES.md`). **One builder session at a time, one task per session:** two builders in one checkout mixed three tasks' work on 2026-10-28. Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage  | todo | T-123 |
| [T-138](tasks/T-138-session-contract-and-mock.md) | `Session1` contract and shell `Session` singleton with a mock | todo | — |
| [T-139](tasks/T-139-session-service-core.md) | `ruya-session`: pure core and D-Bus adapter (dev mode) | todo | T-138 |
| [T-141](tasks/T-141-vm-goto-page.md) | `vm-goto.ps1`: a VM past the wizard to a named page | todo | — |
| [T-140](tasks/T-140-store-remotes-and-progress.md) | Store in the image: Flathub remote, AppStream refresh, real progress | todo | T-134 |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — |
| [T-135](tasks/T-135-update-contract-and-settings.md) | `Update1` contract, mock, Settings → System updates | todo | — |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.

- (empty)


## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | A dev ISO exists (`output/bootiso/`, holds the dev SSH key: test machines only). Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating), stick repeat speed, Accept long-press and context menu (spec 02 §4.3). |
| B-007 | `ruya-devices` remainder: BlueZ part (contract T-136), applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` after T-130 | Audio (T-128, by events since T-133) and network (T-132) are done and VM-verified. ADR-010. |

## Open owner decisions

- **WSL ext4 corruption: apparently fixed 2026-10-27, watch it.** After recreating the distro with `memory=8GB` and `nestedVirtualization=false` (backup `.wslconfig.bak-2026-10-27`; the earlier "disk 3" Windows errors belong to an empty card reader, not an SSD), a full `build.sh`, `make-disk.sh qcow2` and a VM session ran with no `ext4` error in `dmesg`. Not proven whether RAM pressure at 20 GB or the old distro was the cause. If it returns: Windows Memory Diagnostic or memtest86, then move the VHD to the D: SSD (about 63 GB free; clear `output/` first). Claude recreates the distro itself (owner said so).
- **Pushed 2026-10-28** (`scan-secrets.ps1` clean). CI has not been read yet since the 2026-10-27 push: check the latest run (board lint, the new `ruya-store` crate) at the next lead review.
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 4 lines: date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

### 2026-10-28 · Opus 5.5 · Lead (review of `f835519..7392be4` plus uncommitted T-132/T-133/T-134 work)
Two Sonnet builder sessions ran T-132, T-133 and T-134 at once in this checkout and stopped without Outcomes or commits; the lead reviewed the code (0 findings), ran the VM checks and committed each task. `dev.ps1 test` ALL GREEN (164 QML, 13 skipped; 117 Rust); `shots` not run (no screen changed). VM `0.0.17-t134`: `RUYA_BOOT_OK`, `vm-devices-check.sh` and `vm-store-check.sh` all PASS, NIC unplug followed by service and shell, exposure 3.4 / 3.3 OK; no `ext4` errors.
Found: the image ships Fedora's OCI Flatpak remote (524 unnamed apps) → T-140; Settings screenshots in the VM need a wizard walk → T-141; job-signal buffering → T-111 hint. NEXT T-138.

### 2026-10-27 · Opus 5.5 · Lead (owner: "take the lead, optimise docs and rules")
Review of `2f2f1e1..f7574e9` (T-129 was lead work; docs only otherwise) and planning. `dev.ps1 test` ALL GREEN (164 QML passed, 13 skipped offscreen; Rust 54), `shots` ALL GREEN (177; one `TEST WINDOW LOST ACTIVATION`, recovered); `23-settings-network.png` reviewed: fine. VM not run (WSL disk). CI not checked; 6 commits unpushed. **Docs and rules slimmed** (STATUS 25 KB → about 9 KB, Done table archived, board lists open work only, `lint-board.ps1`, `shell/PATTERNS.md` split out, duplicated role text removed; see `LEAD-NOTES.md`). Planned T-135..T-139 (update, Bluetooth, storage, session contract and core). **Later the same day (owner: do the WSL steps and the push):** `main` pushed after a clean secret scan; the owner recreated the WSL distro with `memory=8GB`; `build.sh` 0.0.13-lead, `make-disk.sh` and `smoke-test.ps1 -Work -Keep` all passed (`RUYA_BOOT_OK`, no ext4 errors); T-131's VM criterion done (rename and delete by keys, service state checked). CI not read yet.

- 2026-10-24 · Sonnet 5.5 · T-110 · `org.ruyaos.Store1` contract, `Store` singleton with mock (12 apps, simulated installs) and D-Bus client, 7 tests. `test` ALL GREEN (152). D-Bus client unverified.

- 2026-10-24 · Sonnet 5.5 · T-131 · Rename and delete in Settings → Profiles (`ProfileManageFlow`). `test` 144, `shots` 156 green. **VM criterion not run** (WSL disk went read-only three times): Inbox.

- 2026-10-24 · Opus 5.5 · T-129 (lead, host-only while the disk is broken) · `Devices1.Network` contract, mock, D-Bus client, Settings → Network. `test` 164, `shots` 177 green. D-Bus client unverified.