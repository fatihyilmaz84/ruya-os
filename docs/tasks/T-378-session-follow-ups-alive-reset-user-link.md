# T-378 - ruya-session follow-ups: Alive resets the miss count, "user unknown" vs a logind error, a strict restart check

Status: todo · Phase: 2 · Depends: T-363 · Area: services (ruya-session follow), scripts · Size: S · Owner: builder · Developer surface: none

## Goal
The adopted-app follower never drops a running game because of one logind hiccup, and the VM restart check fails (not notes) when a killed app is reported as `quit`.

## Read first
- `docs/specs/03-services-and-apps.md` (ruya-session, following adopted apps)
- `services/ruya-session/src/follow.rs` (probe loop, miss count), the `UserLink` type and its `exists`; T-340 Outcome and its review notes (lead-7 Inbox line, now this task)
- `scripts/vm-session-check.sh` (`restart` step)

## Scope
1. A unit test: Unknown, Unknown, Alive, Unknown, Unknown probes never reach the drop threshold (one Alive between Unknowns resets the count). Red when the reset is removed.
2. `UserLink::exists` returns three states (exists, user unknown, could not ask) and a unit is dropped only on "user unknown"; "could not ask" counts as Unknown. Tests for each.
3. `vm-session-check.sh restart`: a killed adopted app that reads `quit` is a FAIL, not a NOTE; replace the 0.3 s `pgrep` loop for a short `systemctl` with a check that cannot miss it (for example the journal of the session manager, or `systemd-run --wait` accounting): say which in the Outcome.
4. (T-363 review) While a unit's end is held for its scope, look at the scope every 1 s (`next_at = now + ATTACH_EVERY`, `scope.rs` `on_unit_event`), so a Stop that needs the kill still ends inside `LAUNCH_WAIT` (8 s); a test: Stop with the kill, then Launch, answers the new run.
5. (T-363 review) `vm-session-check.sh check`: assert `scope gone, cpu N ms` is above 0 for a busy sample (proves `CPUUsageNSec` on a user scope); the `list-units ... | grep -q scope` step fails when `systemctl` errors.
6. (lead-8, Dell 0.0.60) The boot race: ruya-session starts before Profiles1 is activatable and before the profile's user manager ("Profiles1 not readable, no unit is stopped", "cannot list the apps of ruya-p1": Transport endpoint is not connected) and does not retry, so adoption after a reboot can miss a running app. Order the unit after the profile service and retry the listing when a profile's manager appears; a unit test with a fake that fails first and answers later.

## Out of scope
- Flatpak scope following (T-363), anything in the shell.

## Acceptance criteria
- [ ] Rust: `alive_between_unknowns_resets_misses`, `user_link_error_is_not_user_unknown` (or close names), each red without its change.
- [ ] `scripts/test-vm-checks.sh` and `lint-vm-checks.ps1` pass for the changed script.
- [ ] VM (lead run): `vm-session-check.sh restart` ALL PASSED on the next image; Outcome `Verified: host (vm pending: vm-session-check.sh restart)`.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` if the drop rule's wording changes.

## Hints
- Depends on T-363 only because both touch `follow.rs`; take it after T-363 is merged.

## Outcome
_Filled in by the implementer._
