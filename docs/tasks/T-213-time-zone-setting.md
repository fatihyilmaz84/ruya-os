# T-213 — Time zone: choose it in setup and in Settings, so local time is right

Status: in-progress · Phase: 2 · Depends: — · Area: api, services, shell · Size: S · Owner: builder

## Goal
The console knows the owner's time zone. Today the clock shows UTC (first noticed in the 0.0.40 try-out, still true on the Dell). Local time is needed by the clock in the shell, the update restart window ("03:00 to 05:00 local", `ruya-update`), bedtimes and daily limits (T-211) and the screen saver/sleep timelines (T-202).

## Read first
- `docs/specs/01-platform.md` ("Schedule" paragraph: the restart window and its use of local time), `docs/specs/02-shell.md` §1.3 (first-boot setup, T-106) and the System pane, `ruya-update`'s schedule code and tests (how it gets the local hour), the clock in the status cluster (`ProfileStatus.qml`/`StatusCluster`), `ruya-devices` structure for a new small interface or `ruya-profiles` if more fitting
- systemd: `timedatectl` (`list-timezones`, `set-timezone`), `org.freedesktop.timedate1` on the system bus (`SetTimezone`, `ListTimezones`, `Timezone` property), `chronyd` (NTP is on); polkit action `org.freedesktop.timedate1.set-timezone`

## Scope
1. **Contract first:** a small `org.ruyaos.Devices1.Time` interface (or the pane talking to `timedate1` through a thin service call): `GetTimezone() -> s`, `ListTimezones() -> as` (IANA names, grouped by region in the UI), `SetTimezone(name) -> status` (admin only: the caller's active profile is an admin, as for the other admin calls; unknown names `invalid`), `TimezoneChanged` signal, plus `NtpSynchronised` property for the "clock not set yet" case. The service (`ruya-devices` user unit cannot call `timedate1` without polkit: add the narrow polkit rule for exactly `org.freedesktop.timedate1.set-timezone` and only for the user `ruya-shell`, like the power rules, or run the call from a root service: pick the smaller and say why).
2. **Shell:** first-boot setup gets a "Where are you?" step (region -> city list, controller-first, a sensible default from the language, skippable; the choice needs no admin because setup runs before profiles exist), Settings -> System gets a "Time zone" row for admins; the clock uses the zone at once (and 12/24 h follows the language as now); the update restart window and any other "local time" consumer read the zone (check `ruya-update` uses `localtime`, not UTC; add a test with a fake zone).
3. **Mock and tests;** a zone change moves the clock and the update schedule's local hour in tests.

## Out of scope
- Automatic detection by IP or GPS, DST rules beyond what tzdata gives, a 12/24 hour override, the system locale (language is separate).

## Acceptance criteria
- [ ] Rust tests for the zone validation and the polkit/caller rule; `ruya-update` schedule tests with a non-UTC zone (window at 03:00 local, not UTC).
- [ ] `tst_*`: the setup step (region -> city -> done) with the controller keys only, focus asserted; the System row is admin-only; the shell clock follows a zone change.
- [ ] Screenshots of the setup step and the System row, `04` §8.
- [ ] VM (lead run): `timedatectl` shows the zone set through the contract; a non-admin caller and an invalid name are refused.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `01-platform.md` (schedule uses local time; the zone), `02-shell.md` §1.3 and System, the XML, `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
