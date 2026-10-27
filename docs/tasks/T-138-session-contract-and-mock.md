# T-138 — App sessions: `Session1` contract and shell `Session` singleton with a mock

Status: todo · Phase: 3 · Depends: — · Area: api, shell · Size: S

## Goal
The shell gets one object, `Session`, that launches an installed app, stops it, and tells the UI which apps are running and when one exits, against a mock. It is the contract that the Store UI ("Open"), the Games page (tiles) and the Guide overlay (switch/close app, after T-130) will call; `ruya-session` (T-139, and later the VM task) implements it.

## Read first
- `docs/specs/03-services-and-apps.md` §4.1 (launch: `flatpak run` in the profile's user manager) and ADR-004 in `docs/specs/00-overview.md` (apps are the profile's Unix user, never `ruya-shell` or root)
- `docs/specs/02-shell.md` §2 (overlay: switch app, close app)
- `api/dbus/org.ruyaos.Store1.xml` and `shell/src/store/` (**the pattern**: contract, `StoreBackend`, mock, D-Bus client, facade)
- `shell/CLAUDE.md` (backend pattern)

## Scope
1. **Contract first:** `api/dbus/org.ruyaos.Session1.xml`, object `/org/ruyaos/Session1`: `Launch(app_id, profile)` → `(status, instance)`, `Stop(instance)` → `status`, `ListRunning()` → dictionaries (`instance`, `app_id`, `profile`, `started` unix seconds, `state` = `starting | running | stopping`), signals `AppStarted(instance, app_id)`, `AppExited(instance, app_id, exit_code, reason)` (`reason` = `quit | crashed | killed | launch-failed`). Statuses: `ok`, `unknown-app`, `unknown-profile`, `already-running`, `unknown-instance`, `invalid`, `failed`. State in the contract header that the profile argument is trusted because only `ruya-shell` and root may call (policy), and that the service refuses non-profile accounts (root, system users, `ruya-shell`).
2. **Shell `Session` singleton** in `shell/src/session/`: abstract `SessionBackend`, `MockSessionBackend` (asynchronous; launching a known app id goes `starting` then `running` after a short delay, `RUYA_MOCK_FAST` shortens it; `Stop` exits it with reason `quit`; one app id can be launched once per profile; a mock id `crashy` exits after launch with reason `crashed`) and `DBusSessionBackend` (compiled only, **unverified**). Facade exposes `running` (a list model of instances, keys only) and the signals.
3. **A toast** "<app> stopped unexpectedly" for `crashed` and `launch-failed` (never for `quit`).
4. **No UI beyond that:** the app layer and the overlay entries belong to T-130 and the tasks after it.

## Out of scope
- The service (T-139), per-profile Wayland sockets, foreground/background switching, the app layer in `Shell.qml` (T-130), launching from tiles or the Store page.

## Acceptance criteria
- [ ] Mock and contract agree: a test calls `Launch`/`Stop` with each status string's trigger (unknown app, unknown profile, twice, bad instance, empty id).
- [ ] `running` updates on start and exit; `AppExited` carries the reason; `crashy` raises exactly one toast, a normal quit none (tests in `tst_session.qml`).
- [ ] `Launch` for a profile that does not exist in the mock `Profiles` returns `unknown-profile`.
- [ ] `dev.ps1 test` ALL GREEN (no screenshot needed: no new screen).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §4.1 (contract, shell side as built), `shell/CLAUDE.md` only if a new pattern appeared, the XML header.

## Hints
- Keep `instance` an opaque string (the service will use a systemd unit name).
- Translations: one new string; refresh `shell/i18n` and translate it.

## Outcome
_Filled in by the implementer. Start with a `Verified:` line._
