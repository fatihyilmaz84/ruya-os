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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
