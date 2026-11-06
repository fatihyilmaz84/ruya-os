# T-192 — ruya-store: Flatpak calls off the D-Bus executor; corrections announce themselves

Status: in-progress · Phase: 2 · Depends: — · Area: services, shell · Size: S · Owner: builder

## Goal
Two follow-ups of T-182: the handlers that now run `flatpak list` (Install, Uninstall, Update, Rollback, ListInstalled, ListRemotes) must not block the zbus executor (every other call and signal waits behind them), and a correction that `sync_installed` makes after an outside `flatpak uninstall` must tell the shell (`InstalledChanged`), so it doesn't show a removed app as installed until its next read.

## Read first
- `docs/tasks/T-182-store-data-fixes.md` Outcome (round 2: `announced`, `generation`, `sync_installed`) and `T-188-store-jobs-survive-restart.md`
- `services/ruya-store/src/dbus.rs` (`get_app`/`add_remote` use `blocking::unblock`: copy that), `service.rs` (`sync_installed`, `refresh`, `State.announced`); `api/dbus/org.ruyaos.Store1.xml` (`InstalledChanged`); `services/CLAUDE.md`

## Scope
1. Run the blocking handlers through `blocking::unblock` like `get_app`; keep the order and locking rules (the `generation` check in `sync_installed` still guards against a refresh that overtook it).
2. `sync_installed` returns whether it changed the installed set or update flags; when it did, the D-Bus layer emits `InstalledChanged` once (and sets `announced` so `refresh()` doesn't announce the same change twice).
3. Extend `vm-store-check.sh`'s outside-removal step: after `flatpak uninstall` by hand and a `ListInstalled` call, an `InstalledChanged` signal was seen (the script already runs a `busctl monitor`; parse JSON, not key order).

## Out of scope
- The shell side (T-191), new methods, Flatpak transaction changes.

## Acceptance criteria
- [ ] Rust tests: a correction announces exactly once (and the next `refresh()` doesn't repeat it); a call that blocks in the fake Flatpak does not stop another D-Bus call from being answered (a test with the fake's blocking hook, or an integration-style test of the handler path if the crate has one; say which). Revert checks noted.
- [ ] VM (lead run): the extended `vm-store-check.sh` step. Outcome: `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` Store section (when `InstalledChanged` is sent).

## Outcome
Verified: host (vm pending: vm-store-check.sh). `dev.ps1 rust` and the Rust tests ran on the host; the extended VM step was written but not run.

Built:
- `Store::sync_installed` returns whether the correction changed the installed set or an update flag, and records the corrected set as `announced` (so the next `refresh()` returns `Ok(false)` for it). `list_installed`, `install`, `uninstall`, `update` and `rollback` take an `emit: &mut dyn FnMut(Event)` (the idiom of `sync` and `run_next`) and send `Event::InstalledChanged` through it when the correction changed something.
- `dbus.rs`: `Install`, `Uninstall`, `Update`, `Rollback`, `ListInstalled` and `ListRemotes` are `async` and run through one helper, `StoreIface::off_executor`, which uses `blocking::unblock` and hands `emit` to the same events channel `forward` sends signals from (so order is kept). `Started` (queue kick) still runs on the executor after the call. The `generation` check in `sync_installed` is unchanged.
- Existing test `a_job_that_ends_during_a_query_still_sends_installed_changed` described the old behaviour (the query corrects silently and the refresh announces); it is now `a_job_that_ends_during_a_query_is_announced_once` (the query announces, the refresh then sends nothing more). The guarantee it protected, that the change is announced at all, still holds and is asserted.
- `vm-store-check.sh`, outside-removal step: marks the signal log, runs `flatpak uninstall` by hand and `ListInstalled`, then parses the `busctl monitor --json=short` lines with `python3` (member name, not key order) and requires exactly one `InstalledChanged`, and still one after a second `ListInstalled`.

Tests (Rust, `ruya-store`):
- `service::tests::a_correction_after_an_outside_removal_is_announced_exactly_once`, `a_job_that_ends_during_a_query_is_announced_once`, `every_call_that_reads_the_installed_set_announces_its_correction` (install, uninstall, update, rollback). Revert check: with `sync_installed` returning `false` always, these three fail; with `state.announced = now` removed, the first two fail.
- `dbus::tests::a_flatpak_call_that_blocks_does_not_stop_another_call_from_being_answered` and `install_does_not_hold_the_executor_and_a_correction_reaches_the_signals`: integration-style, on the handler path (the `StoreIface` methods are called directly, without a bus, because a bus connection does not exist on the host). The fake's `after_next_installed` hook blocks `flatpak list`; one thread plays the executor, the slow handler is polled once and must be `Pending` (it is `Ready` after the hook's 3 s timeout when it runs inline), then `get_app` and `list_remotes` are answered while it hangs, then it is released and ends with its answer and one `InstalledChanged`. Revert check: with `off_executor` running the call inline instead of `blocking::unblock`, both fail (after the 3 s safety timeout).
- Test helper in `dbus.rs`: `Handle(Arc<FakeFlatpak>)` implements `Flatpak` so the test keeps a handle on the fake.

Contract: the XML only gains a comment (`InstalledChanged` is also sent for such a correction, may arrive before the call's reply); no signature changed. Spec 03 Store section updated.

Not covered here: `AddRemote`, `GetApp` and `ListJobs` were already off the executor; the shell side (T-191) is untouched. A new `Sender` is cloned per call (cheap).
