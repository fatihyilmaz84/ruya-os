# RuyaOS — board, later part

Open tasks that are not on the front of the board in `docs/STATUS.md` (ready later, depend on unbuilt work, lead tasks, the `.play` epic). Same columns and rules as the STATUS board; `scripts/lint-board.ps1` reads both files, so every open task file needs exactly one row in one of them. Move a row to STATUS when it becomes one of the next tasks.

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-362](tasks/T-362-compositor-xdg-output-and-socket-follow-ups.md) | Compositor: xdg-output for games, profile-socket and log follow-ups | todo | — |
| [T-394](tasks/T-394-options-menu-on-game-cards.md) | Options menu on game and app cards: Details, Activity, Uninstall and the rest of T-393's list | todo | T-393, T-386 |
| [T-398](tasks/T-398-controller-family-button-mapping.md) | The family's own confirm button: Nintendo A on the right, PlayStation Cross (or Circle), a Confirm-button setting | todo | T-396 |
| [T-397](tasks/T-397-one-controller-drives-the-ui.md) | One controller drives the UI: owner pads per signed-in profile, takeover when they are gone, Guide on a foreign pad | todo | T-396 |
| [T-399](tasks/T-399-action-glyphs-follow-the-active-controller.md) | Glyphs follow the active controller: action glyphs for Xbox, PlayStation, Nintendo, keyboard and a generic pad | todo | T-396, T-398 |
| [T-395](tasks/T-395-options-menu-on-other-surfaces.md) | Options menu on the other surfaces: Store cards, Downloads rows, device rows | todo | T-394 |
| [T-378](tasks/T-378-session-follow-ups-alive-reset-user-link.md) | ruya-session follow-ups: Alive resets the miss count, user unknown vs a logind error, a strict restart check | todo | T-363 |
| [T-299](tasks/T-299-image-follow-ups-secure-boot-bluez-grub-menu.md) | Image follow-ups (VM this task): quiet bootloader-update on Secure Boot, BlueZ pairable timeout, grub-menu ordering, webp | todo | — |
| [T-364](tasks/T-364-storage-scan-follow-ups.md) | Storage scan follow-ups: a real-directory test, a Rescan row, a calmer busy retry | todo | — |
| [T-339](tasks/T-339-vm-check-script-follow-ups.md) | VM check scripts: power-saving wake, sounds probe and jq | todo | — |
| [T-388](tasks/T-388-downloads-spike-and-contract.md) | **[lead]** Downloads: spike (bytes, rate, pause) and the job record v2 in Store1 and Update1 | todo | — |
| [T-389](tasks/T-389-store-jobs-v2-and-actions.md) | Store1 jobs v2: bytes, rate, ETA, queue order; cancel, pause, resume, move | todo | T-388 |
| [T-390](tasks/T-390-update-download-v2-and-actions.md) | Update1: the OS download as a v2 job (bytes, rate), cancel, pause, resume | todo | T-388 |
| [T-391](tasks/T-391-downloads-page.md) | The Downloads page: current, queued and finished downloads, speed, actions; a status pill | todo | T-389, T-390 |
| [T-392](tasks/T-392-download-stats-and-policy.md) | Download stats and policy: per-day totals and history; pause while playing, download in standby | todo | T-389, T-390, T-391 |
| [T-381](tasks/T-381-ge-proton-spike.md) | **[lead]** Spike: GE-Proton outside Steam (umu, runtime, display, size, licences, codecs) | todo | — |
| [T-380](tasks/T-380-profile-audio-isolation.md) | **[lead]** Profiles apart in the audio graph: what a profile's app may see and change in PipeWire | todo | — |
| [T-382](tasks/T-382-ge-proton-preinstalled-and-updated.md) | GE-Proton preinstalled in the image, updated through the Store, named in About | todo | T-381 |
| [T-383](tasks/T-383-steam-uses-ge-proton-by-default.md) | Steam uses GE-Proton by default once installed | todo | T-381, T-382 |
| [T-384](tasks/T-384-ge-proton-for-developers.md) | Developers: run a Windows game on the console's GE-Proton (tier-C format, chapter, sample) | todo | T-382 |
| [T-385](tasks/T-385-runner-catalogue-and-per-game-choice.md) | Windows runner catalogue (Wine, Wine-GE, UMU-Proton, ...) in the Store and a per-game runner choice | todo | T-382 |
| [T-368](tasks/T-368-controllers-pane-capabilities-button-test.md) | Settings > Controllers: connected pads, capabilities and a live button test | todo | T-367 |
| [T-369](tasks/T-369-input-mapping-v1-profiles.md) | Mapping v1: button layout, remapping, dead zones, curves; global profiles with import and export | todo | T-368 |
| [T-370](tasks/T-370-game-and-platform-input-profiles.md) | Game and platform controller profiles: inheritance, applied on focus, a Controller entry on the game page | todo | T-369 |
| [T-371](tasks/T-371-input-ownership-passthrough-and-steam.md) | **[lead]** Ownership modes: direct passthrough and Steam-managed controllers | todo | T-367 |
| [T-372](tasks/T-372-input-keyboard-mouse-layers-chords.md) | Keyboard and mouse output, action layers, chords and controller shortcuts | todo | T-369 |
| [T-373](tasks/T-373-input-gyro-touchpad-haptics.md) | Gyro, touchpad and haptics | todo | T-369 |
| [T-374](tasks/T-374-input-semantic-actions-and-glyphs-for-apps.md) | Semantic actions and controller glyphs for native apps (Platform1) | todo | T-369 |
| [T-292](tasks/T-292-activity-page-follow-ups.md) | Activity page follow-ups: refresh only when visible, paging, retry, icons, focus order | todo | — |
| [T-295](tasks/T-295-time-zone-follow-ups.md) | Time zone follow-ups: say it when Setup cannot set the zone, type to filter the chooser | todo | — |
| [T-287](tasks/T-287-display-hotplug-and-mode-check.md) | Display service follow-ups: hot-plug signal, check the real mode after the restart, recovery argument | todo | T-282 |
| [T-288](tasks/T-288-display-pane-layout-and-ui-size-reflow.md) | Display pane order, layout at large UI size, a Screen row, and the late-filled Column reflow | todo | T-282 |
| [T-343](tasks/T-343-settings-first-focus-and-manage-profiles-follow-ups.md) | Settings follow-ups: first focus skips disabled rows, read-only rows in the spec, Manage profiles result and Guest | todo | — |
| [T-289](tasks/T-289-system-information-follow-ups.md) | System information follow-ups: Bluetooth address from BlueZ, image from a root source, one info row, drive chooser | todo | — |
| [T-338](tasks/T-338-dell-second-pad-drop-repro.md) | **[lead]** Dell: why did the second DualSense drop after 21 s? (live repro and report) | todo | T-335 |
| [T-355](tasks/T-355-dell-real-game-smoke-test-supertuxkart.md) | **[lead]** Dell smoke test with a real game: SuperTuxKart through the shell | todo | T-386 |
| [T-332](tasks/T-332-format-removable-drive-service.md) | Format a removable drive: the service (udisks2, polkit, refusals, identity re-check) | todo | T-196, T-194 |
| [T-333](tasks/T-333-format-drive-settings-flow.md) | Settings > Storage > Format drive...: choose, confirm, PIN, progress, result | todo | T-331, T-332 |
| [T-341](tasks/T-341-lint-icon-and-docs-follow-ups.md) | Lint and docs follow-ups: sample metainfo check, icon spike contour, member-lint note, vm-goto | todo | — |
| [T-342](tasks/T-342-store-age-rating-and-sync-follow-ups.md) | Store follow-ups: every OARS attribute, the long Turkish badge, installed-list reads in order | todo | — |
| [T-344](tasks/T-344-audio-pane-delete-and-confirm-detail-follow-ups.md) | Sound theme delete and confirm dialogs: refused delete, guard test, wrapped details | todo | — |
| [T-345](tasks/T-345-appart-gpu-check-masked-tint-and-shots.md) | AppArt and rounded corners: one GPU check, tint under masked pictures, shots at 4K and DPR 1 | todo | — |
| [T-346](tasks/T-346-sound-theme-checker-work-cap-and-flac-fixtures.md) | Sound theme checker: cap the decode work, fuzz the decoder, FLAC fixtures from real encoders | todo | T-330 |
| [T-283](tasks/T-283-contrast-gate-rows-and-chart-bar-marker.md) | Contrast gate rows: glass sheet, chart bars, saver, bare backdrop, avatars; the chart's read-bar marker | todo | T-282 |
| [T-284](tasks/T-284-glass-sheet-and-dialog-card-follow-ups.md) | Glass sheet follow-ups and one dialog card for the confirm dialogs | todo | T-282 |
| [T-298](tasks/T-298-ci-qt-floor-and-linux-clippy-gate.md) | **[lead]** CI: decide the Qt floor and add a Linux-native clippy gate at Rust 1.92 | todo | — |
| [T-201](tasks/T-201-recover-from-stuck-processes.md) | **[lead]** Recover from stuck processes (watchdogs, OOM) | todo | — |
| [T-207](tasks/T-207-faster-bluetooth-controller-reconnect.md) | **[lead]** Faster Bluetooth controller reconnect | todo | — |
| [T-210](tasks/T-210-profile-customisation.md) | Profile customisation: avatar, colour, name | todo | — |
| [T-215](tasks/T-215-save-backup-and-keep-data.md) | **[lead]** Saves: back up/restore, keep on uninstall | todo | — |
| [T-216](tasks/T-216-network-connection-options.md) | **[lead]** Network options: IP, DNS, proxy, hidden Wi-Fi | todo | — |
| [T-218](tasks/T-218-hdr-feasibility-spike.md) | **[lead]** HDR feasibility spike | todo | — |
| [T-219](tasks/T-219-audio-formats-and-surround.md) | **[lead]** Audio formats and surround, passthrough | todo | — |
| [T-357](tasks/T-357-headphone-virtual-surround-hrtf.md) | **[lead]** Headphone virtual surround: a licence-clean HRTF through PipeWire (owner pointer: HRTF Database) | todo | T-322 |
| [T-220](tasks/T-220-privacy-settings.md) | Privacy settings and per-app permissions | todo | — |
| [T-221](tasks/T-221-app-management.md) | App management: sizes, update, remove, bulk | todo | — |
| [T-222](tasks/T-222-refresh-rate-matching-and-vrr.md) | **[lead]** Refresh-rate matching and VRR | todo | T-198 |
| [T-224](tasks/T-224-telemetry-service-and-consent.md) | **[lead]** Telemetry service and consent | todo | — |
| [T-225](tasks/T-225-crash-reporting.md) | **[lead]** Crash reporting | todo | T-224 |
| [T-211](tasks/T-211-parental-controls-service.md) | **[lead]** Parental controls, service side | todo | T-210, T-213, T-247 |
| [T-212](tasks/T-212-parental-controls-screens.md) | Parental controls screens | todo | T-211 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
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
| [T-248](tasks/T-248-epic-first-party-apps.md) | **[lead]** EPIC: first-party apps (picture viewer, weather, media player, files, Jellyfin, then the emulator frontend; no browser first) and the platform they need | todo | — |
| [T-249](tasks/T-249-hig-human-interface-guidelines.md) | **[lead]** Human Interface Guidelines for app authors (`docs/specs/06-hig.md`) | todo | — |
| [T-250](tasks/T-250-app-platform-spike-and-adr.md) | **[lead]** Spike for ADR-015 (Accepted): the `org.ruyaos.Platform` runtime extension with RuyaKit | todo | — |
| [T-251](tasks/T-251-ruyakit-shared-components.md) | RuyaKit: shared components as a module apps can use | todo | T-250 |
| [T-252](tasks/T-252-app-template-ci-and-publish.md) | App template, CI recipe, publish to the Store | todo | T-250, T-251, T-214 |
| [T-253](tasks/T-253-app-picture-viewer.md) | App: Picture viewer | todo | T-251, T-252 |
| [T-254](tasks/T-254-app-weather.md) | App: Weather | todo | T-251, T-252 |
| [T-255](tasks/T-255-app-media-player.md) | App: Media player (local files; codec situation) | todo | T-251, T-252, T-256 |
| [T-256](tasks/T-256-app-file-manager.md) | App: File manager (and the shared folder browser) | todo | T-251, T-252 |
| [T-257](tasks/T-257-app-jellyfin-client.md) | App: Jellyfin client | todo | T-251, T-252, T-255 |
| [T-258](tasks/T-258-app-browser.md) | **[lead]** App: Browser (parked by the owner 2026-11-08, ADR-016: no browser first) | todo | owner, T-250, T-252 |
| [T-259](tasks/T-259-app-emulator-frontend.md) | App: Emulator frontend (no emulators, ROMs or BIOS shipped) | todo | T-251, T-252, T-256 |
| [T-262](tasks/T-262-wake-from-suspend-by-controller.md) | Wake from suspend with a controller (hardware-dependent; honest UI) | todo | T-166, T-202, T-203 |
| [T-263](tasks/T-263-controller-registry-and-player-model-spec.md) | **[lead]** EPIC multiple controllers (ADR-017): spec of the registry and the player model | todo | T-260, T-366 |
| [T-264](tasks/T-264-controller-registry-and-slots-service.md) | Controller registry and player slots: contract, `ruya-inputd`, mock, client | todo | T-263 |
| [T-265](tasks/T-265-players-ui-whos-playing-and-chips.md) | Players UI: "Who's playing?" dialog, player chips, Settings > Players | todo | T-264, T-223 |
| [T-266](tasks/T-266-virtual-gamepads-per-slot-for-apps.md) | **[lead]** Ordered virtual gamepads per slot for apps (physical pads hidden) | todo | T-264, T-367 |
| [T-267](tasks/T-267-pad-default-owner-at-login.md) | A pad remembers its owner: Guide on the picker highlights that profile | todo | T-264, T-265 |
| [T-268](tasks/T-268-guest-player.md) | Guest as a temporary player | todo | T-264, T-265, T-211 |
| [T-270](tasks/T-270-epic-games-store-integration.md) | **[lead]** Epic Games Store integration (Legendary, Heroic-style): Proposed ADR-018 first | blocked | owner |
| [T-273](tasks/T-273-epic-multitasking-and-task-switching.md) | **[lead]** EPIC multitasking and task switching (ADR-019 Accepted): spec | todo | T-164 |
| [T-274](tasks/T-274-spike-freezing-real-games.md) | **[lead]** Spike: freeze and thaw real apps and games on the Dell | todo | T-164, T-162 |
| [T-275](tasks/T-275-session-per-app-freeze-and-switch.md) | `ruya-session`: per-app freeze/thaw and an atomic `Switch` | todo | T-273, T-274, T-165 |
| [T-276](tasks/T-276-compositor-snapshots-visibility-smooth-switch.md) | **[lead]** Compositor: last-frame snapshots, visibility events, smooth switch | todo | T-273, T-164, T-147 |
| [T-277](tasks/T-277-task-switcher-ui-and-quick-switch.md) | Task switcher UI and the quick-switch gesture | todo | T-273, T-147, T-275, T-276 |
| [T-278](tasks/T-278-background-and-memory-policy-game-mode.md) | **[lead]** Background and memory policy ("game mode") | todo | T-273, T-274, T-275, T-201 |
| [T-279](tasks/T-279-app-cooperation-save-state-and-background-audio.md) | App cooperation: save state, background audio, developer guide | todo | T-273, T-275 |
| [T-280](tasks/T-280-gap-free-boot-handover.md) | **[lead]** Close the dark gap between the boot splash and the shell's first frame | todo | T-269 |
| [T-302](tasks/T-302-epic-game-data-hub-api.md) | **[lead]** EPIC game data hub (ADR-020 Accepted): ROM folders, save and capture paths, now-playing: spec | todo | — |
| [T-303](tasks/T-303-spike-hub-systems-layout-sandbox.md) | **[lead]** Spike and spec: system ids, ROM and capture layout, sandbox reach | todo | T-302 |
| [T-304](tasks/T-304-hub1-contract-and-service.md) | `Hub1`: contract, `ruya-hub` service, mock and client | todo | T-302, T-303 |
| [T-305](tasks/T-305-captures-screenshot-recording-clip.md) | **[lead]** Captures: screenshots, recordings and clip-the-last-seconds by the OS | todo | T-302, T-304, T-164 |
| [T-306](tasks/T-306-now-playing-exchange.md) | Now playing: apps report, the OS shows and shares it | todo | T-302, T-304, T-247 |
| [T-307](tasks/T-307-library-and-emulator-frontend-use-the-hub.md) | Library and the emulator frontend use the hub | todo | T-302, T-304, T-259 |
| [T-308](tasks/T-308-hub-developer-guide-sample-and-permissions.md) | Hub developer guide, sample app and per-app permissions | todo | T-302, T-304, T-306, T-220 |
| [T-309](tasks/T-309-saves-catalog-and-operations-service.md) | **[lead]** Saves manager, service: catalog of saves per game and safe operations (copy, move, delete, export, import) | todo | T-215, T-302, T-304 |
| [T-310](tasks/T-310-saves-manager-ui.md) | Saves manager UI: browse, copy, move, delete, export and import saves | todo | T-309 |
| [T-311](tasks/T-311-saves-manager-for-external-emulators.md) | External emulators and apps integrate with the saves manager (declare, register, open, notify) | todo | T-309, T-304, T-306 |

| [T-314](tasks/T-314-epic-retro-achievements.md) | **[lead]** EPIC: retro achievements (RetroAchievements) for emulated games | todo | — |
| [T-315](tasks/T-315-spike-ra-terms-hashes-and-contract.md) | **[lead]** Spike: RetroAchievements terms, ROM hash rules, supported systems, service contract | in-progress | T-314, T-302 |
| [T-316](tasks/T-316-ra-account-link-and-emulator-handover.md) | RetroAchievements account link in Settings and credential hand-over to emulators | todo | T-315, T-304, T-220, T-211 |
| [T-317](tasks/T-317-ra-data-in-the-shell.md) | RetroAchievements data in the shell: cache, Library rings, profile tab, game page | todo | T-316, T-307, T-246 |
| [T-318](tasks/T-318-ra-unlock-moment-and-presence.md) | **[lead]** Retro unlock moment and presence: toast, report event, polling fallback | todo | T-317, T-246, T-245, T-306 |
| [T-319](tasks/T-319-xbox-360-wireless-receiver.md) | Xbox 360 wireless receiver ("360 dongle"): in-kernel `xpad`, classification, battery, sync guidance | todo | — |
| [T-350](tasks/T-350-lint-dev-docs-public-api-coverage-and-samples.md) | lint-dev-docs: every public API element is documented, every sample builds | todo | — |
| [T-351](tasks/T-351-api-level-and-changelog.md) | API level: RUYA_API_LEVEL, the AppStream minimum, the Store filter, an XML-diff changelog | todo | — |
| [T-352](tasks/T-352-ruya-platform-service-skeleton.md) | ruya-platform: the one door for sandboxed apps (ADR-022 Accepted; step one: the caller-identity spike) | todo | T-351 |
| [T-353](tasks/T-353-developer-mock-and-sample-harness.md) | Developer harness: a Platform mock, a sample app and a conformance runner in CI | todo | T-352, T-350 |
| [T-354](tasks/T-354-research-xbox-wireless-adapter-support.md) | **[lead]** Research: Xbox Wireless Adapter support (driver, user-downloaded firmware, legal risk) and a recommended task list; builds nothing | todo | — |
