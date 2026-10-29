# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-10-30 (Opus 5.5, lead)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** the shell has pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish translation. Profiles, power, audio (`ruya-devices`, event-driven since T-133), network (`ruya-devices` over NetworkManager, T-132), the store service (`ruya-store` over `flatpak`, T-134) and the Guide key are **vm-verified** over the real bus; the Store UI (T-111) is built against the mock. The compositor spike (T-123) proved ADR-002 option A (shell as Wayland compositor on KMS); T-130 (lead) makes it the session.
- **Not started:** `ruya-session` in the image (T-139 built the core, dev mode only; unit, policy and the real spawner follow T-130), `ruya-update` (T-135 built its contract `Update1` and the Settings UI against a mock), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has ever been launched from the shell.
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. **Image and VM work works again since 2026-10-27** (fresh WSL distro, `.wslconfig` `memory=8GB`; image `0.0.13-lead` built, made into a disk and booted `RUYA_BOOT_OK`, T-131 VM-verified). If `ext4` errors return, see the WSL note under Open owner decisions.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-149**

**Lead review due** after 3–5 more builder tasks (reviewed up to the lead commit "lead review 4671bb5..e863439", see `docs/LEAD-NOTES.md`). **One builder session at a time, one task per session:** two builders in one checkout mixed three tasks' work on 2026-10-28. Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-130](tasks/T-130-compositor-session.md) | **[lead]** Compositor session: `ruya-shell` replaces cage  | todo | T-150 |
| [T-149](tasks/T-149-library-flatpak-games.md) | `ruya-library`: Flatpak games are games | todo | T-112 |
| [T-151](tasks/T-151-ruya-update-service.md) | `ruya-update`: the `Update1` service over `bootc` | todo | T-135 |
| [T-113](tasks/T-113-games-page.md) | Library client and Games page with art cards | todo | T-101, T-112, T-143 |
| [T-152](tasks/T-152-store-high-risk-admin-pin.md) | Store: admin PIN before a Standard profile installs a high-risk app | todo | T-111 |
| [T-146](tasks/T-146-art-led-home.md) | Art-led Home: hero, Recent art row, section nav | todo | T-113, T-143 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-130, T-138, T-146 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |
| [T-144](tasks/T-144-contrast-and-accessible-names.md) | Design review: contrast over the backdrop, accessible names | todo | T-143 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.



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
- Decided (for the record): design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 4 lines: date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-10-30 · Opus 5.5 · Lead (review `4671bb5..e863439`: T-150, T-135, T-148, T-111) · `test` ALL GREEN (209 QML + 15 screenshot skips, 178 Rust); `shots` ALL GREEN (224; `17`, `18`, `19`, `25` reviewed, `19` now caught after the fade). CI green at `4671bb5`. No VM run (T-148's `0.0.19-t148` covers every service change).
  Findings 2 fixed / 0 filed: Store progress fill white like the volume OSD (was `toastInfo`); `AppArt` and the progress bar adopted in `04` §5. Decided: admin-only service calls check the caller like `AddRemote` (Update1 header, T-151).
  Planned T-151 (`ruya-update` over `bootc`, VM) and T-152 (admin PIN for high-risk installs). Inbox: AppArt decided; genre field dropped until Home (T-146) needs categories.

- 2026-10-29 · Sonnet 5.5 · T-111 · Store page (toolbar, four rows, search results, controller filter via the service) and `appDetail` page (badges, plain-language permissions with high-risk flags, install/update/uninstall with progress and inline errors); `Page.openRequested`; D-Bus client replays early job signals (unverified). `test` ALL GREEN; `shots` green once, `17`/`18` reviewed, `19` caught mid-fade (re-run hung on this desktop).
  Lead review is due (T-150, T-135, T-148, T-111).
- 2026-10-29 · Sonnet 5.5 · T-148 · `Search(query, options)` (controller, limit) and `CatalogChanged`; service `sync`, shell patches installed flags without re-searching, `Store.controllerFilter`. `test` ALL GREEN (198 QML); VM `0.0.19-t148` `RUYA_BOOT_OK`, `vm-store-check.sh` all passed (127 of 3419 apps are gamepad).
  Lead review is due.
- 2026-10-29 · Sonnet 5.5 · T-135 · `Update1` contract, `Update` singleton + mock + unverified D-Bus client, Settings -> System Updates group (check, download progress, restart, admin rollback and channel), staged toast. Added `Profiles1.VerifyAdmin` (XML, Rust + test, mock, client) to gate the rollback. `test` ALL GREEN (195 QML), `shots` ALL GREEN, `25` reviewed.
  Scoped two `powerCancel` lookups in `tst_profile_admin` (a second `PowerConfirm` made the name ambiguous). No `ruya-update` yet. Lead review is due after T-148.
- 2026-10-29 · Sonnet 5.5 · T-150 · `KeyRouter` (C++ event filter, one `isGuideKey`) and the shell's `appLayer` with `addApp/focusApp/removeApp`; stand-in app tests. `test` ALL GREEN (187 QML). `shots` unjudged: timer tests fail on this desktop session, also on the baseline.
  Unblocks T-130 (lead). Lead review is due after T-148.
