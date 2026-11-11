# T-454 — Hub display: the current mode, resolution and refresh rate, brightness where the screen supports it

Status: in-progress · Phase: 2 · Depends: — · Area: shell, services (ruya-devices, only for brightness) · Size: S · Owner: builder · Complexity: normal · Developer surface: internal

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
_Filled in by the implementer._
