# RuyaOS — board, later part

Open tasks that are not on the front of the board in `docs/STATUS.md` (ready later, depend on unbuilt work, lead tasks, the `.play` epic). Same columns and rules as the STATUS board; `scripts/lint-board.ps1` reads both files, so every open task file needs exactly one row in one of them. Move a row to STATUS when it becomes one of the next tasks.

| ID | Title | Status | Depends |
|---|---|---|---|
| [T-201](tasks/T-201-recover-from-stuck-processes.md) | **[lead]** Recover from stuck processes (watchdogs, OOM) | todo | — |
| [T-207](tasks/T-207-faster-bluetooth-controller-reconnect.md) | **[lead]** Faster Bluetooth controller reconnect | todo | — |
| [T-210](tasks/T-210-profile-customisation.md) | Profile customisation: avatar, colour, name | todo | — |
| [T-215](tasks/T-215-save-backup-and-keep-data.md) | **[lead]** Saves: back up/restore, keep on uninstall | todo | — |
| [T-216](tasks/T-216-network-connection-options.md) | **[lead]** Network options: IP, DNS, proxy, hidden Wi-Fi | todo | — |
| [T-217](tasks/T-217-controller-input-mapping.md) | **[lead]** Controller mapping (InputPlumber, B-006) | todo | — |
| [T-218](tasks/T-218-hdr-feasibility-spike.md) | **[lead]** HDR feasibility spike | todo | — |
| [T-219](tasks/T-219-audio-formats-and-surround.md) | **[lead]** Audio formats and surround, passthrough | todo | — |
| [T-220](tasks/T-220-privacy-settings.md) | Privacy settings and per-app permissions | todo | — |
| [T-221](tasks/T-221-app-management.md) | App management: sizes, update, remove, bulk | todo | — |
| [T-222](tasks/T-222-refresh-rate-matching-and-vrr.md) | **[lead]** Refresh-rate matching and VRR | todo | T-198 |
| [T-224](tasks/T-224-telemetry-service-and-consent.md) | **[lead]** Telemetry service and consent | todo | — |
| [T-225](tasks/T-225-crash-reporting.md) | **[lead]** Crash reporting | todo | T-224 |
| [T-211](tasks/T-211-parental-controls-service.md) | **[lead]** Parental controls, service side | todo | T-210, T-213, T-247 |
| [T-212](tasks/T-212-parental-controls-screens.md) | Parental controls screens | todo | T-211 |
| [T-165](tasks/T-165-profile-switch-freezes-apps.md) | Profile switch and sign-out freeze the profile's apps | todo | T-164 |
| [T-147](tasks/T-147-fullscreen-app-flow.md) | Full-screen apps: launch, quick menu, return, close | todo | T-164 |
| [T-166](tasks/T-166-suspend-under-eglfs.md) | **[lead]** Suspend and resume under eglfs | todo | — |
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
| [T-248](tasks/T-248-epic-first-party-apps.md) | **[lead]** EPIC: first-party apps (picture viewer, weather, media player, files, Jellyfin, browser, emulator frontend) and the platform they need | blocked | owner |
| [T-249](tasks/T-249-hig-human-interface-guidelines.md) | **[lead]** Human Interface Guidelines for app authors (`docs/specs/06-hig.md`) | todo | — |
| [T-250](tasks/T-250-app-platform-spike-and-adr.md) | **[lead]** Spike and ADR-015 (Proposed): how apps use the OS components (runtime extension, RuyaKit) | todo | — |
| [T-251](tasks/T-251-ruyakit-shared-components.md) | RuyaKit: shared components as a module apps can use | todo | T-250 |
| [T-252](tasks/T-252-app-template-ci-and-publish.md) | App template, CI recipe, publish to the Store | todo | T-250, T-251, T-214 |
| [T-253](tasks/T-253-app-picture-viewer.md) | App: Picture viewer | todo | T-251, T-252 |
| [T-254](tasks/T-254-app-weather.md) | App: Weather | todo | T-251, T-252 |
| [T-255](tasks/T-255-app-media-player.md) | App: Media player (local files; codec situation) | todo | T-251, T-252, T-256 |
| [T-256](tasks/T-256-app-file-manager.md) | App: File manager (and the shared folder browser) | todo | T-251, T-252 |
| [T-257](tasks/T-257-app-jellyfin-client.md) | App: Jellyfin client | todo | T-251, T-252, T-255 |
| [T-258](tasks/T-258-app-browser.md) | **[lead]** App: Browser: Proposed ADR-016 first | todo | T-250, T-252 |
| [T-259](tasks/T-259-app-emulator-frontend.md) | App: Emulator frontend (no emulators, ROMs or BIOS shipped) | todo | T-251, T-252, T-256 |
| [T-262](tasks/T-262-wake-from-suspend-by-controller.md) | **[lead]** Wake from suspend with a controller (hardware-dependent; honest UI) | todo | T-166, T-202, T-203 |
| [T-263](tasks/T-263-controller-registry-and-player-model-spec.md) | **[lead]** EPIC multiple controllers (ADR-017): spec of the registry and the player model | todo | T-260 |
| [T-264](tasks/T-264-controller-registry-and-slots-service.md) | Controller registry and player slots: contract, `ruya-inputd`, mock, client | todo | T-263 |
| [T-265](tasks/T-265-players-ui-whos-playing-and-chips.md) | Players UI: "Who's playing?" dialog, player chips, Settings > Players | todo | T-264, T-223 |
| [T-266](tasks/T-266-virtual-gamepads-per-slot-for-apps.md) | **[lead]** Ordered virtual gamepads per slot for apps (physical pads hidden) | todo | T-264, T-217 |
| [T-267](tasks/T-267-pad-default-owner-at-login.md) | A pad remembers its owner: Guide on the picker highlights that profile | todo | T-264, T-265 |
| [T-268](tasks/T-268-guest-player.md) | Guest as a temporary player | todo | T-264, T-265, T-211 |
| [T-269](tasks/T-269-boot-experience-brand-silent-direct.md) | Boot experience: branded splash, silent boot, no boot menu unless a key is held (image, VM) | todo | — |
| [T-270](tasks/T-270-epic-games-store-integration.md) | **[lead]** Epic Games Store integration (Legendary, Heroic-style): Proposed ADR-018 first | blocked | owner |
| [T-271](tasks/T-271-themes-more-distinct.md) | Colour themes that look different from each other (owner feedback) | todo | — |
| [T-272](tasks/T-272-picker-modals-glass-and-rounded-thumbnails.md) | Picker modals in glass, rounded wallpaper thumbnails (owner feedback) | todo | T-198 |
