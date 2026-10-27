# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-10-27 (Opus 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** the shell has pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish translation. Profiles, power, audio (`ruya-devices`) and the Guide key are **vm-verified** over the real bus. Network and Store exist only as contract, mock and UI (host); their services are T-132 and T-134. The compositor spike (T-123) proved ADR-002 option A (shell as Wayland compositor on KMS); T-130 (lead) makes it the session.
- **Not started:** `ruya-session` (launch apps; T-138, T-139), `ruya-update` (T-135 is its UI contract), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has ever been launched from the shell.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. **The WSL disk corrupts on this machine, so no image or VM work can be verified until the owner acts** (Open owner decisions). Host-only tasks continue.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-138**

**Lead review due: after 3 more builder tasks** (reviewed up to the lead commit "lead review 2f2f1e1..f7574e9", see `docs/LEAD-NOTES.md`). Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-138](tasks/T-138-session-contract-and-mock.md) | `Session1` contract and shell `Session` singleton with a mock | todo | — |
| [T-139](tasks/T-139-session-service-core.md) | `ruya-session`: pure core and D-Bus adapter (dev mode) | todo | T-138 |
| [T-112](tasks/T-112-library-service-core.md) | ruya-library discovery core (Rust) | todo | — |
| [T-135](tasks/T-135-update-contract-and-settings.md) | `Update1` contract, mock, Settings → System updates | todo | — |
| [T-111](tasks/T-111-store-ui.md) | Store UI | todo | T-110, T-119 |
| [T-113](tasks/T-113-games-page.md) | Games page and recent row | todo | T-101, T-112 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage (needs the VM) | todo | T-123 |
| [T-132](tasks/T-132-devices-network-service.md) | `ruya-devices`: network over NetworkManager, in the VM | todo | T-129, T-128 |
| [T-133](tasks/T-133-devices-pipewire-events.md) | `ruya-devices`: follow PipeWire by events, no 1 s poll | todo | T-128 |
| [T-134](tasks/T-134-store-service-core.md) | `ruya-store` service over the `flatpak` CLI, in the VM | todo | T-110 |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.

- (T-131) VM criterion unverified: rename and delete through the running shell with `vm-keys.ps1`, then `vm-profiles-check.sh state` (first runtime check of `DBusProfilesBackend::renameProfile/deleteProfile`). Redo once the WSL disk works.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | A dev ISO exists (`output/bootiso/`, holds the dev SSH key: test machines only). Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating), stick repeat speed, Accept long-press and context menu (spec 02 §4.3). |
| B-007 | `ruya-devices` remainder: BlueZ part (contract T-136), applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` after T-130 | Audio is T-128; network service T-132; the PipeWire poll T-133. ADR-010. |

## Open owner decisions

- **WSL ext4 corrupts on this host, even on a fresh distro. It blocks every image/VM task (T-130, T-131 VM check, T-132, T-133, T-134).** On 2026-10-24 a fresh `FedoraLinux-44` went read-only 18 minutes into `build.sh` (`ext4_lookup: iget: checksum invalid`). Suspects: host RAM, or the C: SSD (Samsung 870 QVO) holding the VHD. **Not a suspect any more:** the Windows `disk` event 154 errors (block 0x0, "disk 3") belong to an empty JMicron card reader (0 GB), not to an SSD. 2026-10-27: `.wslconfig` is now `memory=8GB`, `nestedVirtualization=false` (backup `.wslconfig.bak-2026-10-27`), but the existing distro still has the earlier error state (it mounted "with errors" and went read-only again at boot), so it has to be **recreated** (`wsl --unregister FedoraLinux-44`, `wsl --install FedoraLinux-44 --no-launch`, `dnf -y install podman git qemu-img`; it holds nothing but packages) before the 8 GB test build means anything; the session's auto-mode classifier refused the unregister, so the owner runs it. If a build then fails the same way, try (1) Windows Memory Diagnostic or memtest86, and (2) the VHD on the D: SSD (Samsung 990 PRO; only about 63 GB free, a build needs about 40 GB, so clear `output/` first).
- **Pushed 2026-10-27** (secret scan clean; `image/bib/config.toml` stays git-ignored). CI has not been read yet: check the first run (it exercises the new board lint) before the next lead review.
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23), later pushes need the owner's go-ahead.

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 4 lines: date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

### 2026-10-27 · Opus 5.5 · Lead (owner: "take the lead, optimise docs and rules")
Review of `2f2f1e1..f7574e9` (T-129 was lead work; docs only otherwise) and planning. `dev.ps1 test` ALL GREEN (164 QML passed, 13 skipped offscreen; Rust 54), `shots` ALL GREEN (177; one `TEST WINDOW LOST ACTIVATION`, recovered); `23-settings-network.png` reviewed: fine. VM not run (WSL disk). CI not checked; 6 commits unpushed. **Docs and rules slimmed** (STATUS 25 KB → about 9 KB, Done table archived, board lists open work only, `lint-board.ps1`, `shell/PATTERNS.md` split out, duplicated role text removed; see `LEAD-NOTES.md`). Planned T-135..T-139 (update, Bluetooth, storage, session contract and core).

- 2026-10-24 · Sonnet 5.5 · T-110 · `org.ruyaos.Store1` contract, `Store` singleton with mock (12 apps, simulated installs) and D-Bus client, 7 tests. `test` ALL GREEN (152). D-Bus client unverified.

- 2026-10-24 · Sonnet 5.5 · T-131 · Rename and delete in Settings → Profiles (`ProfileManageFlow`). `test` 144, `shots` 156 green. **VM criterion not run** (WSL disk went read-only three times): Inbox.

- 2026-10-24 · Opus 5.5 · T-129 (lead, host-only while the disk is broken) · `Devices1.Network` contract, mock, D-Bus client, Settings → Network. `test` 164, `shots` 177 green. D-Bus client unverified.

- 2026-10-24 · Opus 5.5 · Lead (disk space) · `build.sh` removes untagged images it did not use (WSL use 78 → 30 GB); `smoke-test.ps1 -Work` gives one shared `work.qcow2`; fixed a stale `RUYA_BOOT_OK` read when the old QEMU held `serial.log`. `.vhdx` shrink is an owner step (`dev-setup.md`).
