# RuyaOS — Status

**Read this first in every session; update it last.** Rules: root `CLAUDE.md`. Roles (Opus lead, Sonnet builders): `docs/LEAD.md`. Task format: `docs/tasks/README.md`. Finished work: each task's own file (`Status: done`, Outcome starting with `Verified:`); history before T-132 in [`STATUS-done.md`](STATUS-done.md), old sessions in [`STATUS-log.md`](STATUS-log.md), parked Inbox lines and decided records in [`STATUS-parked.md`](STATUS-parked.md). `scripts/lint-board.ps1` (part of `dev.ps1 test`) keeps this board and the task files in step.

Last updated: 2026-11-06 (Sonnet 5.5, planning)

## Where we are

- **Phase 0 (foundation): vm-verified 2026-10-22.** Image builds, boots to the shell, updates, rolls back by hand and by greenboot. Real hardware: B-002 (the Dell boots the shell from the installer ISO).
- **Phases 1–2 (shell core, profiles, devices):** pages, Settings (Profiles, Network, Bluetooth, Audio, Display, Storage, System, About), on-screen keyboard, first-boot wizard, Turkish. **vm-verified over the real bus:** profiles, power, audio, network, store, library, updates, the Guide key, launching apps (`ruya-session`, T-162). Bluetooth and Storage panes are verified against the mock only (VM queue). **The shell is the compositor (T-130).** The installer ISO (`0.0.47-combined`) partitions the whole disk and boots.
- **Not started:** per-profile Wayland sockets (T-164: an app's window appears in the shell; Play does nothing yet), InputPlumber (B-006).
- **Host:** Windows plus a Fedora 44 WSL distribution (image builds) and QEMU/WHPX (boot tests): `docs/dev-setup.md`.

Verification legend: **host** = built and tested on Windows · **host (vm pending)** = on the VM queue · **vm** = built into the image and verified booted in QEMU · **unverified** = written, not run · **hw** = real hardware.

## Board

**NEXT → T-164** ([lead], the critical path: per-profile Wayland sockets). Owner, 2026-11-06: developer documentation (T-214) and then the visual polish come first: **T-204, T-206, T-205, then T-209, T-208** are the first builder lanes; T-164 stays the lead's critical path.

**How work runs (owner, 2026-11-04):** the lead dispatches `ruya-builder` agents, at most two at a time in their own worktrees and in different areas, has each branch reviewed by `ruya-reviewer`, and merges it (`docs/LEAD.md`, build loop). Dispatched builders never edit this file. At most one task with a "VM (this task)" criterion runs at a time. A builder session the owner starts directly takes NEXT in the main checkout, alone, and does the bookkeeping itself (`CLAUDE.md`).

Open work only, in the recommended order; when NEXT is blocked take the first `todo` whose dependencies are `done`. `[lead]` tasks are skipped by builders. If nothing qualifies, **stop and ask for a planning session** (`docs/tasks/PLANNING.md`).

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-190](tasks/T-190-settings-pane-focus-follow-ups.md) | Settings panes: look-ahead, Tab, peek legibility | todo | — |
| [T-194](tasks/T-194-confirm-buttons-name-the-action.md) | Confirm dialogs: the button says the action | todo | — |
| [T-197](tasks/T-197-shell-crash-on-bluetooth-audio-disconnect.md) | **[lead]** Shell crash when a Bluetooth headset disconnects | in-progress | — |
| [T-198](tasks/T-198-display-resolution-and-dpi.md) | **[lead]** Display: resolution, refresh, UI scale (DPI) | todo | — |
| [T-199](tasks/T-199-device-icons.md) | Device icons in the Bluetooth pane and toasts | todo | — |
| [T-201](tasks/T-201-recover-from-stuck-processes.md) | **[lead]** Recover from stuck processes (watchdogs, OOM) | todo | — |
| [T-202](tasks/T-202-screen-saver-and-power-saving.md) | Screen saver and power saving | todo | — |
| [T-203](tasks/T-203-pair-a-controller-without-a-keyboard.md) | Pair a controller with no keyboard | todo | — |
| [T-205](tasks/T-205-gliding-highlight-and-liquid-pills.md) | Gliding highlight, liquid-glass pills | in-progress | T-204 |
| [T-207](tasks/T-207-faster-bluetooth-controller-reconnect.md) | **[lead]** Faster Bluetooth controller reconnect | todo | — |
| [T-208](tasks/T-208-wallpaper-support.md) | Wallpapers: bundled set, USB, Settings picker | in-progress | — |
| [T-210](tasks/T-210-profile-customisation.md) | Profile customisation: avatar, colour, name | todo | — |
| [T-213](tasks/T-213-time-zone-setting.md) | Time zone in setup and Settings | todo | — |
| [T-215](tasks/T-215-save-backup-and-keep-data.md) | **[lead]** Saves: back up/restore, keep on uninstall | todo | — |
| [T-216](tasks/T-216-network-connection-options.md) | **[lead]** Network options: IP, DNS, proxy, hidden Wi-Fi | todo | — |
| [T-217](tasks/T-217-controller-input-mapping.md) | **[lead]** Controller mapping (InputPlumber, B-006) | todo | — |
| [T-218](tasks/T-218-hdr-feasibility-spike.md) | **[lead]** HDR feasibility spike | todo | — |
| [T-219](tasks/T-219-audio-formats-and-surround.md) | **[lead]** Audio formats and surround, passthrough | todo | — |
| [T-220](tasks/T-220-privacy-settings.md) | Privacy settings and per-app permissions | todo | — |
| [T-221](tasks/T-221-app-management.md) | App management: sizes, update, remove, bulk | todo | — |
| [T-222](tasks/T-222-refresh-rate-matching-and-vrr.md) | **[lead]** Refresh-rate matching and VRR | todo | T-198 |
| [T-223](tasks/T-223-status-cluster-device-batteries.md) | Top-right status: one battery chip per device | todo | — |
| [T-224](tasks/T-224-telemetry-service-and-consent.md) | **[lead]** Telemetry service and consent | todo | — |
| [T-225](tasks/T-225-crash-reporting.md) | **[lead]** Crash reporting | todo | T-224 |
| [T-211](tasks/T-211-parental-controls-service.md) | **[lead]** Parental controls, service side | todo | T-210, T-213 |
| [T-212](tasks/T-212-parental-controls-screens.md) | Parental controls screens | todo | T-211 |
| [T-164](tasks/T-164-per-profile-wayland-sockets.md) | **[lead]** Per-profile Wayland sockets | todo | T-162 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch, quick menu, return, close | todo | T-164 |
| [T-166](tasks/T-166-suspend-under-eglfs.md) | **[lead]** Suspend and resume under eglfs | todo | — |
| [T-226](tasks/T-226-system-information.md) | System information screen (CPU, RAM, GPU, storage...) and USB report | todo | — |
| [T-227](tasks/T-227-ui-sounds-and-ambient-themes.md) | UI sounds and ambient atmosphere: sound themes, one bundled theme, maker guide | todo | — |
| [T-245](tasks/T-245-notification-centre.md) | **[lead]** Notification centre: history, quiet mode, notifications from apps (bridge) | todo | — |
| [T-246](tasks/T-246-achievements.md) | **[lead]** Achievements: portal for games, per-profile service, unlock moment | todo | T-245, T-164 |
| [T-228](tasks/T-228-epic-play-packages.md) | **[lead]** EPIC: `.play` packages (ADR-014 accepted; parked by the owner until visual polish and T-164) | blocked | owner |
| [T-229](tasks/T-229-play-feasibility-spike.md) | **[lead]** Spike: `.play` as a generated Flatpak, Wine display, Proton nesting | todo | T-228, T-164 |
| [T-230](tasks/T-230-play-format-crate.md) | `.play` format: schema, parser, hostile-package tests | todo | T-228 |
| [T-231](tasks/T-231-play-signing-and-trust.md) | **[lead]** `.play` signing, trust tiers, key continuity, revocation | todo | T-230 |
| [T-232](tasks/T-232-play-art-and-video-vetting.md) | `.play` art and video vetting (decode, check, re-encode) | todo | T-230 |
| [T-233](tasks/T-233-ruya-pack-cli.md) | `ruya-pack` developer CLI | todo | T-230, T-231, T-232 |
| [T-234](tasks/T-234-play1-contract-mock-client.md) | `Play1` contract, mock, shell client | todo | T-230, T-231 |
| [T-235](tasks/T-235-package-page-design-step.md) | **[lead]** Design step: package page and install-flow components | todo | T-228 |
| [T-236](tasks/T-236-install-from-usb-and-package-page.md) | Shell: Install from USB and the package page | todo | T-234, T-235 |
| [T-237](tasks/T-237-play-importer-core.md) | `ruya-play` importer core (staging, unpack, verify; fakes) | todo | T-230, T-231, T-232 |
| [T-238](tasks/T-238-ruya-play-service-in-the-image.md) | **[lead]** `ruya-play` service in the image (VM) | todo | T-229, T-234, T-237 |
| [T-239](tasks/T-239-play-launcher-and-runner-resolution.md) | **[lead]** Launcher and runner resolution (bundled, system, newest) | todo | T-229, T-238 |
| [T-240](tasks/T-240-play-permissions-mapping-and-gate.md) | `.play` permissions: mapping, ceilings, admin gate | todo | T-231, T-238 |
| [T-241](tasks/T-241-play-updates.md) | **[lead]** `.play` updates: signed feeds, same-key rule, rollback | todo | T-231, T-238, T-240 |
| [T-242](tasks/T-242-play-library-home-and-preview.md) | `.play` in Library and Home: art, preview loop, save paths | todo | T-232, T-238 |
| [T-243](tasks/T-243-play-developer-guide-and-samples.md) | `.play` developer guide and two samples | todo | T-233 |
| [T-244](tasks/T-244-system-wine-runner-pack.md) | **[lead]** System Wine runner pack on the `ruyaos` remote | todo | T-229, T-239 |

**VM queue** (host-done, VM check pending; the lead runs them with one image build): empty after `0.0.48-lead` (T-191, T-192, T-193, T-196, T-200, T-214 verified; T-200 sensors on the Dell are still open). Devices checks need `-Audio`.

## Inbox

One line each: `- (source) what, and why it matters`. Dispatched builders put them in their HANDOFF; the lead copies them here. Older lines (T-189..T-196, T-195, Dell, designs) are in [`STATUS-parked.md`](STATUS-parked.md): the planner reads them too. Plan at 5+ items.

- (T-162) `ruya-session` forgets running apps when it restarts (a relaunch then fails with `launch-failed`): adopt `ruya-app-*` units of every profile manager on start. An exec failure (203) reports `crashed`, not `launch-failed`.
- (Dell) `bootloader-update.service` fails with Secure Boot on (no Microsoft UEFI CA 2023): tolerate it (`SuccessExitStatus=1`?) or document Secure Boot off for test machines. The hostname is the DHCP/IPv6 name (T-216 adds a static console name).
- (Dell) `Failed to initialize EGL display ... EGL_WL_bind_wayland_display` on KMS: T-164 must pick a dmabuf integration and test a GL client on the Dell (B-003).
- (T-214 findings) `Library.launch` only emits `launchRequested` (Play does nothing: T-164/T-147); games as `ruya-p<N>` cannot open `/dev/input/event*` and `ruya-inputd` does not grab (B-006); `ruya-store` age label: `g. Full text in `STATUS-parked.md`.
- (T-192 review) `ruya-store` `sync_installed`: overlapping reads can apply out of order; give each read a ticket.
- (Dell) Headsets paired before the pairing fix are `Bonded: no`: the shell could offer "Pair again" (needs `bonded` in `ListDevices`).
- (T-200 review) Capture the Dell's real `/sys/class/hwmon` and `thermal_zone` layout into `services/ruya-devices/tests/fixtures/` (today's fixture is written from the task text). Full text in `STATUS-parked.md`.
- (T-214 review) `dev.ps1` lint self-check lacks a fixture for the `/* sample: <path> */` C-block rule; the AppStream example in `appstream-metadata.md` is not checked against the sample's metainfo; `vm-sample-check.s. Full text in `STATUS-parked.md`.
- (T-206 review) `subset-icons.sh`: install `skia-pathops` with `--require-hashes` (the only unchecked download); `check-font-coverage.py` catches only identical coincident contours, not any overlap. Full text in `STATUS-parked.md`.
- (T-204, design, decide) `glassTint` (44 %) gives white text only 2.5:1 over pure-white art (04 §7 wants 4.5:1): until decided `tint` carries no text (options: stronger tint ~64 %, a lightness cap on hero art, a dark text var. Full text in `STATUS-parked.md`.
- (VM 0.0.48-lead) Re-run once on the next image: the three script fixes (`vm-devices-check.sh storage` with the retry, `thermal-fake` with the exponent parser, `vm-sample-check.sh` with the Store restart) are host-chec. Full text in `STATUS-parked.md`.
- (T-209, design, decide) Dark themes + bright wallpaper/hero art: glass text 0.9:1 over white (T-208's dim rule covers wallpapers only); avatar palette vs themes: blob overlap on bright tints gives glass text 2.5-2.8:1 and initials on orange/cyan/green avatars 2.2-2.9:1 (gate per theme or an initial token); gate rows for text on the bare Backdrop. Later: one shared FocusRing + 2 px halo; High-contrast as a sixth theme (its shot is the deferred criterion); `--theme` override for `shots`; per-profile themes. Canvas boards need a theme row (all five palettes, Daylight). Dell: cycle the five themes and watch the 700 ms cross-fade.
- (0.0.40) The VM and the Dell clock show UTC: T-213.

## Blocked (need something this host doesn't have)

| ID | What | Needs | Notes |
|---|---|---|---|
| B-002 | Install on a real low-tier machine; first frame-time numbers (spec 02 §8) | Hardware | The Dell (Intel UHD 630, 8 GB, Secure Boot) boots the installer ISO to the shell, greenboot green, `vm-session-check.sh` 45 PASS on the hardware (0.0.44). No frame times yet. The `0.0.47-combined` ISO is on `F:\RuyaOS\` (dev SSH key: test machines only). Hardware checks queued: Wi-Fi under the NetworkManager deny rule, pads in UPower as kind 12, Bluetooth, thermal (T-200). More in `STATUS-parked.md`. |
| B-003 | Compositor performance: blurred Guide overlay over a running game at ≥ 55 FPS on the mid tier (ADR-002) | A GPU | Functional part done in the VM (T-123, T-130). Left: frame rates, dmabuf clients, blur over a client surface, gamescope nesting, volume-key `Shortcut`s with an app focused. |
| B-006 | Replace the `ruya-inputd` stopgap with InputPlumber (ADR-003), grab and re-emit | Linux + controllers | Also owns key repeat (a held Backspace/Esc repeats Back: should page-level Back ignore `isAutoRepeat`?), stick repeat, long-press and context menu (spec 02 §4.3), Bluetooth PIN pairing, player assignment, button test, remapping (T-136, T-217). |
| B-007 | `ruya-devices` remainder: `ambient`/`media` levels on app streams, PipeWire for profile apps | `ruya-session` in the image | Audio and network are done and VM-verified (ADR-010). Media access on `/run/media/ruya-shell/...` for profile users belongs to the Media task. |

## Open owner decisions

- **Telemetry (T-224/T-225; asked for 2026-11-06).** (1) Consent model: recommendation = an explicit first-boot choice (Share / Don't share, equal buttons, nothing sent before the answer); "on unless turned off" needs legal advice. (2) Backend and who pays: the code ships an open protocol and a reference receiver; the production endpoint is yours. (3) Retention proposed 13 months hardware / 90 days crashes, no IPs. (4) Privacy notice text and a data-processing agreement before any release that enables it. (5) Whether "App usage" may ever be asked. Until you answer, T-220's statement and the first-boot screen follow the recommendation.
- **`.play` packages (T-228; asked for 2026-11-06).** **Decided 2026-11-06, work parked until you say start:** D1 ADR-014 accepted (a `.play` is a container that installs as a sandboxed Flatpak, amending ADR-005), conditional on the T-229 spike. D2 (decided 2026-11-06): RuyaOS ships no emulators, Proton/Steam runtime, firmware or discs; packagers do and carry the duty; only Wine is a system runner. Left open only if RuyaOS ever hosts packages (an Official remote). D3: the image preinstalls the Wine runner. Remaining open questions: `docs/specs/05-play-packages.md` §16.
- **Dolby/DTS names (T-219):** the UI needs a licence to use the names and logos. Until decided: "Surround (AC-3)", "Surround Plus (E-AC-3)", "DTS".
- **Update size vs the unshrunk image (T-195):** the slimmed image is not smaller on disk or in the update download (layers). Rechunking or flattening is a trade-off (update size). Recommendation: spike rechunking after the first release candidate.
- **Controller brand art (T-199):** pictures of Sony/Microsoft/Nintendo pads need a legal decision; the task draws its own silhouettes.
- **HDR and VRR (T-218/T-222):** decisions after the spikes; they may need Gen11+ Intel or AMD hardware to test.
- **Preinstalled Flatpak runtime** (`org.freedesktop.Platform//26.08`) in a dev/offline image (T-214): size vs first-install network.
- **Dev ISO on the test machine (B-002):** it erases every disk, puts the dev SSH key on root and tracks `localhost/ruyaos:dev`. Acceptable for a dedicated test machine only; a real installer with disk choice is Phase 3.
- **Real hardware:** a spare low-tier x86-64 PC would unblock KPIs and the ADR-002 performance check. **One admin or several?** (recommendation: one in the UI for the MVP). **Turkish wording review** by a native speaker before release. **libdvdcss / AACS:** not included; needs an explicit decision. **Host disk or RAM:** WSL `ext4` errors if they return: move the VHD off C:; Claude recreates the distro.
- Decided (the record is in [`STATUS-parked.md`](STATUS-parked.md)): storage shows the internal disk; Steam, RetroArch and media/streaming apps are separate Store apps; blur and shadows stay the default; agents in worktrees with a reviewer verdict; icon set Material Symbols; the lead pushes `main` after the secret scan.

## Session log (newest first, the latest five; older entries in `STATUS-log.md`)

One entry per session, at most 700 characters (`lint-board.ps1`): date · model · tasks · what happened · numbers · follow-ups. Detail belongs in the task Outcome.

- 2026-11-06 · Sonnet 5.5 · Planning (owner request: `.play` packages; no code) · Wrote spec `05-play-packages.md` (format, runners bundled/system/newest, closed permissions, signing and trust tiers, updates), Proposed ADR-014 (a container that installs as a sandboxed Flatpak, amends ADR-005) and epic T-228 with T-229..T-244. Epic is `blocked` on the owner (ADR-014, D1-D3). Open: Xwayland or Wine Wayland (none today), Proton nesting, emulator content policy. Inbox untouched.

- 2026-11-06 · Sonnet 5.5 · Lead (T-162 by the lead; no lanes; range had only docs) · `ruya-session` runs in the image: `systemd-run --machine=` per app, status file, scope-aware Stop/kill, linger; unit exposure 1.1; deleting a profile ends its manager. VM `0.0.44-t162`: smoke OK, session check 45 PASS, devices 57. `test` 381 QML + 30 skips, Rust green. VM found: SELinux refuses PID 1 a service's pipe; Flatpak apps live in their own scope; PipeWire was not masked for profiles. New F: drive formatted NTFS, holds the ISO. Process: image/CLAUDE.md quirk.

- 2026-11-05 · Sonnet 5.5 · Lead (build loop from `4c0e713`: T-178..T-188 merged, 11 tasks; 6 CHANGES_REQUESTED, T-187 lead-read) · `test` 381 QML + 30 skips. VM `0.0.42-lead`: smoke, devices 57, store 67, library, storage 98: all PASS (devices needs `-Audio`). Planned T-178..T-194 (T-189..T-194 not dispatched). Owner: media and streaming apps out of the first MVP; blur and shadows stay the default; no new tasks after those in flight. Process: builders run dev.ps1 in their worktree; VM scripts parse JSON, not key order.

- 2026-11-04 · Opus 5.5 · Lead (build loop; from `2c134ce`: T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144, T-175, T-176, T-161, T-173, T-145, T-177, T-174 merged after `ruya-reviewer`, 10 CHANGES_REQUESTED) · `test` 346 QML + 28 skips. VM `0.0.32/.33/.37` (lead), `.34/.36/.38/.39` (builders): update drill + idle reboot, store, devices, BlueZ, UPower, udisks2 all PASS. Lead fixes: drill, store and Bluetooth stop-scan, polkit deny-by-default (review). Owner: Inter download OK. Process: devkitPro git/cmake/ssh, per-checkout log, lane counts to merge.

- 2026-11-04 · Opus 5.5 · Lead (review `9b77857..4bd0c66`: T-155, T-157, T-130 diff; T-159 skimmed) · `test` ALL GREEN (267 QML + 21 skips, 242 Rust), `shots` 56, CI green at `945a60f` (one shell flake at `18a342a` → T-167); 0 review findings. Disks full twice: WSL disk grew 7 → 29 GB per build; `free-space.ps1` + `wsl --manage --compact`. Owner: builder agents in worktrees (2 lanes), Opus review before merge, lead-only STATUS, image builds only in image tasks (VM queue). Planned T-162..T-168. Paused by the owner mid-loop: see LEAD-NOTES.

