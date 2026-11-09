# T-364 - Storage scan follow-ups: a real-directory test, a Rescan row, a calmer busy retry

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-devices drive_scan), shell (StoragePane) · Size: S · Owner: builder · Developer surface: none

## Goal
The drive scan is tested on a real directory, the player can refresh a stale scan, and the pane does not hammer the service while another client scans.

## Read first
- `docs/specs/03-services-and-apps.md` and `02-shell.md` (Storage), `docs/specs/04-design-system.md` §5, §8
- `services/ruya-devices/src/drive_scan.rs` (`FsSource::list`, `FakeTree`), `shell/qml/StoragePane.qml`, `shell/tests/tst_storage.qml`; T-331 Outcome

## Scope
1. A host tempdir test for `FsSource::list` (cap and stop on a real directory larger than `max`).
2. A **Rescan** row (or a re-scan on pane open when the cache is older than the last write we know of) so writes that change no udisks property are seen.
3. The busy retry while another client scans backs off (1.5 s, 3 s, 6 s, cap 10 s) instead of every 1.5 s.
4. Screenshots of the Scanning state and the Other / empty rows.

## Out of scope
- Collapsing six categories into "Show details" (needs a new component: design call in T-282), formatting (T-332/T-333).

## Acceptance criteria
- [ ] Rust: `fs_source_list_caps_and_stops_on_a_real_directory` (red without the cap).
- [ ] QML: `test_rescan_row_rescans`, `test_busy_retry_backs_off` (red when removed).
- [ ] UX: Back leaves; focus after Rescan stays on the row; screenshots (Scanning, Other, empty) in en and tr reviewed; `UX notes:` line.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `02` Storage.

## Hints
- Inbox lines (T-331 reviews) are verbatim in `STATUS-parked.md`, "Inbox triage 2026-11-09 (lead-7)".

## Outcome
_Filled in by the implementer._
