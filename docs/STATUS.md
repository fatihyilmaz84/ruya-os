# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-02 (Opus 5.5, lead session T-130)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Left: real hardware (B-002).
- **Phases 1–2 (shell core, profiles, devices):** pages, motion, toasts/OSD, Settings (Profiles, Network, Audio, Display, System, About), on-screen keyboard, first-boot wizard, Turkish. **vm-verified over the real bus:** profiles, power, audio and network (`ruya-devices`), store (`ruya-store`), updates (`ruya-update`: manual, daily check, idle restart at night), the Guide key. Against the mock: Store UI, Games page, art-led Home (T-111, T-113, T-146). **The shell is the compositor (T-130, vm-verified):** cage is gone, `ruya-shell` runs on KMS (eglfs) and shows Wayland clients fullscreen in its app layer; Guide stays with the shell.
- **Not started:** `ruya-session` in the image (T-139 built the core, dev mode only; unit, policy and the real spawner are next, unblocked by T-130), Bluetooth, USB storage, InputPlumber (B-006), installer. No app has been launched from the shell's own UI yet (a test client ran as a Wayland app, T-130).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`. If WSL `ext4` errors return, see Open owner decisions.

Verification legend: **host** = built and tested on Windows · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-155**

**Lead review due** after 3–5 more builder tasks (reviewed up to the lead commit "lead review e5c2ab3..ac6e5b1", see `docs/LEAD-NOTES.md`). **One builder session at a time, one task per session:** two builders in one checkout mixed three tasks' work on 2026-10-28. Builders: when your task makes this true, end your reply by recommending a lead session.

Open work only (todo, in-progress, blocked). The order is the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done` (a task's status is in its file header). `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-155](tasks/T-155-card-accept-pulse.md) | Accept pulse on art cards; remove the unused `Tile` | todo | T-146 |
| [T-157](tasks/T-157-icon-font.md) | Icon font (Material Symbols Rounded) and `Icon` | todo | — |
| [T-159](tasks/T-159-restart-notice-and-download-retry.md) | `ruya-update`: notice before the automatic restart; retry a failed download | todo | T-154 |
| [T-160](tasks/T-160-greenboot-wanted-check.md) | Greenboot: no failing wanted check on a healthy boot | todo | — |
| [T-158](tasks/T-158-hint-bar.md) | Hint bar with controller button glyphs | todo | T-157 |
| [T-161](tasks/T-161-controller-battery.md) | Controller battery: `Devices1` over UPower, status cluster, low-battery toast | todo | T-157 |
| [T-144](tasks/T-144-contrast-and-accessible-names.md) | Design review: contrast over the backdrop, accessible names | todo | T-143 |
| [T-145](tasks/T-145-bundle-inter.md) | Bundle the Inter typeface | todo | T-142 |
| [T-136](tasks/T-136-bluetooth-contract-and-settings.md) | `Devices1.Bluetooth` contract, mock, Settings pane | todo | — |
| [T-137](tasks/T-137-storage-contract-and-settings.md) | `Devices1.Storage` contract, mock, Settings → Storage | todo | — |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch splash, quick menu, return, close | todo | T-130, T-138, T-146 |

## Inbox

Follow-ups and debt for the next planner. Builders: add one line per item, `- (source) what, and why it matters`; write a task file only if your own task needs one. Run a planner at 5+ items.

- (T-130) Apps connect to `ruya-0` in `ruya-shell`'s own runtime directory (mode 0700): apps running as a profile's user (ADR-004) cannot reach it. The `ruya-session` image task must add per-profile sockets (or hand the client a socket fd).
- (T-130) A Wayland app that connects while nobody is signed in is drawn above the picker (it gets no focus); the `ruya-session` task should define what lock or sign-out does to open apps.
- (T-130) Suspend/resume and VT switching under eglfs are untested, but the Guide power menu offers Suspend: try `Suspend` in the VM (and on hardware, B-002) before users rely on it.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | Build a fresh dev ISO first (the 0.0.4 one was deleted to free space on 2026-11-02; it holds the dev SSH key: test machines only). Decide there: a failed boot takes ~100 s, so automatic rollback takes ~7 min; consider a shorter required-check timeout once real boot times are known. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123) and the session built (T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (400 ms delay, then accelerating), stick repeat speed, Accept long-press and context menu (spec 02 §4.3). |
| B-007 | `ruya-devices` remainder: BlueZ part (contract T-136), applying `ambient`/`media` levels to app streams, PipeWire for profile apps | `ruya-session` in the image (T-130 done) | Audio (T-128, by events since T-133) and network (T-132) are done and VM-verified. ADR-010. |

## Open owner decisions

- **Host disk or RAM, watch it:** WSL `ext4` errors (gone since the distro was recreated with `memory=8GB`, `nestedVirtualization=false` on 2026-10-27) and a zeroed cargo file (2026-10-28), both on C:. Recommendation: Windows Memory Diagnostic and the drive maker's SMART check; not blocking. If `ext4` errors return, move the VHD to the D: SSD (clear `output/` first); Claude recreates the distro itself (owner said so).
- **Real hardware (B-002):** is a spare low-tier x86-64 PC (Intel/AMD iGPU) available for the dev ISO? It unblocks the Phase 0 hardware item, the first KPIs and the ADR-002 performance check. Recommendation: yes, a test machine only.
- **One admin or several?** Overview §2 says one admin, `03` §1.1 says one or more. The service supports several; the UI offers Standard and Guest. Recommendation: one admin in the UI for the MVP (as the overview says); revisit after the first user test. Not blocking.
- **Turkish wording review** (`shell/i18n/ruyashell_tr.ts`, written by AI): a native review before the first release. Not blocking; best done after the Settings panes settle (T-135..T-137).
- **libdvdcss / AACS:** not included; needs an explicit owner decision.
- Decided (for the record): icon set Material Symbols Rounded, ADR-013 (owner, 2026-11-01); design system ADR-012 with Inter bundled, an art-led Home and full-screen apps (owner, 2026-10-28); ADR-002 option A (owner, 2026-10-23); repo public on GitHub (2026-10-23); the lead pushes `main` at the end of every lead session after `scripts\scan-secrets.ps1` passes, builders never push (owner, 2026-10-28).

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-02 · Opus 5.5 · Lead (T-130; no review, nothing landed since `39b25f2`) · `ruya-shell` is the compositor on KMS, cage removed; input devices by a `uaccess` rule (lead decision); `KeyRouter` takes Guide from any item inside an app. `test` ALL GREEN (256 QML + 21 skips), `shots` 56. VM `0.0.26-t130`, fresh disk: `RUYA_BOOT_OK`, no cage, wizard and picker over the real bus, T-123 sequence and a held Guide over a test client. Drill: update to `0.0.27`, rollback, a broken compositor rolled back by greenboot after 4 boots. Process: drill step 5 recipe, `/NUL` git-ignored. Inbox +3. Host drives 99 % full (owner).

- 2026-11-02 · Opus 5.5 · Lead (review `e5c2ab3..ac6e5b1`: T-153, T-156, T-154) · `test` ALL GREEN (255 QML + 21 skips, 242 Rust, 52 s), `shots` 56 (39 s, update-adds and Updates screens reviewed), CI green at `48406c7`; no VM run (`0.0.25-t154` covers it). Fixed 2: a `last_check` in the future stopped the daily check; app start/close waited for the once-a-minute report. Inbox → T-159 (restart notice, download retry), T-160 (greenboot), T-161 (controller battery), T-147 hint. Process: `lint-board.ps1` caps the log at five entries of 700 characters.

- 2026-11-02 · Sonnet 5.5 · T-154 · `ruya-update` schedule (`schedule.rs`, fake clock): check at start and every 24 h, scheduled check downloads, restart via `systemctl reboot` at 03:00-05:00 after 30 idle minutes with no app; `SetAutoRestart` (admin) + Settings switch, `ReportActivity` from the shell. `test` ALL GREEN (254 QML, 56 Rust), `shots` reviewed. VM `0.0.24-t154`->`0.0.25-t154`: guest clock moved to 03:10, the service rebooted the guest, cold start `RUYA_BOOT_OK`; `settings` ALL PASSED, exposure 4.8 OK. Shell D-Bus client unverified. Lead review due after 2-4 more tasks.

- 2026-11-02 · Sonnet 5.5 · T-156 · `GetApp` returns `new_permissions` (installed vs remote metadata); a Standard profile needs an admin's PIN to update an app whose update adds a high-risk permission. The shell never called `GetApp` (permissions empty over D-Bus, so T-152's gate was dead there): the page now loads them first. `test` ALL GREEN (247 QML, 46 store Rust), `shots` reviewed. VM `0.0.23-t156`: `vm-store-check.sh` ALL CHECKS PASSED. A real permission-adding update unverified. Lead review due after 1-3 more tasks.
