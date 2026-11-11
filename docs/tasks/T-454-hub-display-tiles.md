# T-454 — Hub display: the current mode, resolution and refresh rate, brightness where the screen supports it

Status: done · Phase: 2 · Depends: — · Area: shell, services (ruya-devices, only for brightness) · Size: S · Owner: builder · Complexity: normal · Developer surface: internal

## Goal
From the Hub the player sees the display's mode and can change resolution and refresh rate with the same keep-or-revert safety as Settings, and gets a brightness control only where the screen really has one.

## Read first
- ADR-033; `02` §1.6 (T-447's display part); `04` §8; `Devices1.Display` (`ListOutputs`, `SetMode`, `GetPending`, `Keep`, `Revert`) and the Settings display pane

## Scope
1. A display row or tile in the Quick Hub showing the current mode; Accept opens a small mode list; a change uses the existing pending/keep/revert flow over the game.
2. Brightness: contract first (`Devices1.Display`: `Brightness` with a state, `SetBrightness`) for screens with a kernel backlight (`/sys/class/backlight`); TVs and monitors without one report `unsupported` and the shell shows no brightness control. DDC/CI is out (needs `i2c-dev` and a package: an Inbox line).
3. HDR is out (T-218).

## Acceptance criteria
- [ ] Mode change from the Hub keeps or reverts like Settings (test on the mock)
- [ ] Brightness: present with a backlight, absent without (tests on mock and in Rust with fixture sysfs)
- [ ] UX: Back leaves the mode list; the revert countdown is readable over a game; `UX notes:` line
- [ ] VM (lead run): `vm-devices-check.sh system` sees `Brightness` as `unsupported` in QEMU
- [ ] `dev.ps1 test` ALL GREEN; `shots` reviewed

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` §1.6, `03` (Devices1.Display).

## Hints
- Planned by lead-10 (ADR-033).

## Outcome
Verified: host (vm pending: `vm-devices-check.sh system`, brightness part)

UX notes: states reached: the Display entry in the Hub (between Performance and Power; absent when no screen is known and no backlight), the panel (Resolution, Refresh rate, Brightness; Brightness only with a backlight, Refresh rate only when the size has more than one rate), the mode list (Settings' `ModePicker`, over the whole screen), the "Keep this resolution?" dialog (`ModeConfirm`, z 40 above the Hub), a toast for a refused change or a game in the way. Back: the mode list closes to the Resolution/Refresh row (nothing was asked of the service), Back in the panel returns to the Hub on the Display entry, Back in the Hub resumes; in the dialog Back is Revert. Focus: panel opens on its first row; after the list closes it is on the row that opened it; the dialog puts it on Revert; when the Brightness row disappears (a monitor replaces the laptop panel) the focus stays on the row that took its place. Doubted: (1) a mode change ends every game (the shell is the compositor), so over a running game the rows refuse with Settings' own toast instead of restarting: "readable over a game" is then only the dialog's z-order (tested) and a screenshot of it over a game picture; whether a player should be allowed to lose the game is the lead's call (it is how Settings behaves today). (2) After a change the shell, as for any change, opens Settings on Display & motion under the dialog; from the Hub that is a detour, not a harm. (3) Resolution and Refresh rate are two rows (as in Settings) and not one "Mode" row, because the mode list of one size is short and a rate change keeps the size.

What was built:
- Contract first (`api/dbus/org.ruyaos.Devices1.xml`): `Display.GetBrightness() -> (su)` (`supported` or `unsupported`, percent 1..100) and `Display.SetBrightness(u percent) -> s` (`ok`, `unsupported`, `invalid`, `failed`); status strings added to the header.
- `services/ruya-devices/src/backlight.rs` (new): reads `/sys/class/backlight` (firmware, then platform, then raw; `actual_brightness` else `brightness`), plans a level (at least 1: never black), `RUYA_BACKLIGHT_DIR` for fixtures. `dbus.rs` serves the two methods; the write goes through logind `Session.SetBrightness` (the service is not root), or to the fixture file when `RUYA_BACKLIGHT_DIR` is set. 10 Rust tests with fixture sysfs (no backlight, scaling, ordering, clamps, direct write).
- Shell: `DisplayBackend`/`Mock`/`DBus` gain `refreshBrightness`, `setBrightness`, `brightnessChanged`, `setBrightnessFinished` (own `RequestSequence`); `Display.brightnessSupported`, `Display.brightness`, `setBrightness`, `refreshBrightness`; mock screen "laptop" (the only one with a backlight) and hooks `mockFailBrightnessNext`, `mockBrightnessCalls`, `mockBacklightKey`.
- `QuickMenu.qml`: a `display` panel (new row kind `pick`: value at the right, Accept opens a list; sliders now draw `fraction()`/`value()` from their descriptor and may have no `activate`, so Brightness has no A hint), the one `ModePicker` (built when first needed) with Settings' entries, Settings' game-must-close guard, the Hub closes when the service accepts a change. A Hub row's text is `Theme.text`. Fixed on the way: a delegate read `row.value` of a stale `row` (TypeError when the row list changed); each binding now reads `row` itself.
- `scripts/vm-devices-check.sh`: `brightness_check` in `system` (QEMU: `GetBrightness` is `(su) "unsupported" 0`, `SetBrightness 50` unsupported, `0` invalid, another user refused).
- Specs: `02` §1.6 (Display panel, Tiles line), `03` (Brightness paragraph after the T-198 one). Translations (tr + en) for the 11 new strings.

Tests: new `tst_hub_display.qml` (20 functions, 2 screenshot ones skipped without `RUYA_SHOTS_DIR`); `tst_quickmenu.qml` order lists gained `panel:display` (the feature adds the row; no assertion weakened). Revert checks (each undone, the new tests failed, then restored): `Display.brightnessSupported ?` made `true ?` (3 tests); the 5-step made 1 (3 tests); the running-game guard made `if (false)` (`test_a_running_game_must_be_closed_before_the_console_restarts`); the Hub's close on an accepted change removed (2 tests); `Display.refreshBrightness()` on opening the panel removed (`test_the_panel_asks_for_the_level_again_when_it_opens`); Rust: `plan`'s `clamp(1, max)` made `clamp(0, max)` (`a_plan_never_goes_dark_and_refuses_what_is_out_of_range`). `lost-tests.sh` printed nothing.

Files: api/dbus/org.ruyaos.Devices1.xml; services/ruya-devices/src/{backlight.rs,dbus.rs,lib.rs,main.rs}; shell/src/display/*; shell/qml/QuickMenu.qml; shell/tests/{tst_hub_display.qml,tst_quickmenu.qml}; shell/i18n/*.ts; scripts/vm-devices-check.sh; docs/specs/02-shell.md, 03-services-and-apps.md.

Unverified: logind accepting `SetBrightness` from the service's user unit on a real laptop (the Dell has no backlight; QEMU none), real `/sys/class/backlight` naming beyond the fixtures.
