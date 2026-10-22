# T-115 — Profiles1: attempts left and retry time in CreateProfile / SetPin replies

Status: done · Phase: 2 · Depends: — · Area: api, services, shell · Size: M

## Goal
After a wrong admin PIN or a wrong current PIN, the shell shows "N attempt(s) left" or "Try again in N s" straight from the service's reply, with no extra calls. This removes the `SwitchTo(id, "")` probe that T-105 added to work around a gap in the contract.

## Read first
- `CLAUDE.md`, "Contracts are drafts until the first release" (extend the contract; update every layer in one commit)
- `api/dbus/org.ruyaos.Profiles1.xml` (`SwitchTo` already returns `attempts_left` and `retry_after_secs`; copy that shape)
- `services/ruya-profiles/src/service.rs` (`Outcome`, `create_profile`, `set_pin`) and `src/dbus.rs` (`switch_to` rounds the retry time up)
- `shell/src/profiles/DBusProfilesBackend.cpp` (`probeAttempts`, `createProfile`, `setPin`) and `ProfilesBackend.h`
- `docs/tasks/T-105-profile-management.md` Outcome

## Scope
1. **Contract first.** In `org.ruyaos.Profiles1.xml`, add `attempts_left` (u) and `retry_after_secs` (u) as out-args of `CreateProfile` (after `id`) and `SetPin` (after `status`). Document in the header that they are meaningful only for `wrong-pin` (attempts left) and `locked-out` (seconds), and 0 otherwise.
2. **Service core.** `create_profile` and `set_pin` return the same `Outcome` information as `switch_to` (status, attempts left, retry time), plus the new id for create. Existing rules do not change. Update the existing unit tests to the new return types and add assertions for the new fields.
3. **D-Bus adapter.** `dbus.rs` returns the extended tuples. Reuse the existing round-up of the retry time (factor it into one helper used by `switch_to`, `create_profile` and `set_pin`).
4. **Shell D-Bus client.** `DBusProfilesBackend` reads the extra values from the replies and emits them in `createFinished` / `setPinFinished`. **Delete `probeAttempts`** and everything that only served it. The mock already reports these numbers; keep its behaviour.
5. **Docs.** `docs/specs/03-services-and-apps.md` §1.1 "UI flows": remove the paragraph about the probe and say the replies carry the counts.

## Out of scope
- New profile methods (rename/delete: T-118).
- Any UI change. What the user sees stays exactly as it is.

## Acceptance criteria
- [x] The XML lists the new out-args for both methods, with the header note (reviewed in the Outcome by quoting the diff).
- [x] `service.rs` tests: a wrong admin PIN in `create_profile` returns `wrong-pin` with `attempts_left` 4 on the first failure and 1 on the fourth; the fifth returns `locked-out` with `retry_after` = `FIRST_LOCKOUT`; the same for `set_pin` with a wrong old PIN; successful calls return 0 and 0 (test: `service::tests`).
- [x] `.\scripts\dev.ps1 rust` is green, including clippy for the Linux target.
- [x] `rg probeAttempts shell/` finds nothing, and the shell builds (the D-Bus client compiles against the new reply types).
- [x] The existing UI tests still pass unchanged, in particular `tst_profile_admin.qml::test_add_profile_wrong_admin_pin` ("4 attempt(s) left") and `test_add_profile_locked_out_message`.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §1.1 (above).
- `docs/STATUS.md`: the D-Bus reply parsing is **unverified** (no bus on Windows); the recipe is in `docs/dev-setup.md` ("Against the real profiles service").

## Hints
- zbus returns multi-value replies as tuples; follow `switch_to` in `dbus.rs`. On the Qt side use `QDBusPendingReply<QString, QString, uint, uint>` for create and `<QString, uint, uint>` for set-pin, as `switchTo` already does.
- Keep the argument names in the XML snake_case and identical to the Rust parameter names.

## Outcome
`CreateProfile` and `SetPin` now return the attempt counts, the shell reads them from the reply, and the `SwitchTo` probe is gone.

- **Contract** (`api/dbus/org.ruyaos.Profiles1.xml`): `CreateProfile` returns `(status, id, attempts_left, retry_after_secs)`; `SetPin` returns `(status, attempts_left, retry_after_secs)`. The header now says the two numbers matter only for `wrong-pin` (tries left before lockout) and `locked-out` (seconds, rounded up) and are 0 otherwise, and that `SwitchTo` also reports `attempts_left` with `pin-required`. Argument names are snake_case and match the Rust parameters.
- **Service** (`services/ruya-profiles/src/service.rs`): `create_profile` returns `(Outcome, Option<String>)` and `set_pin` returns `Outcome`, the same type `switch_to` uses; an admin or old-PIN failure passes the authentication outcome through unchanged, rule failures (`invalid`, `not-allowed`, `unknown-profile`, `failed`) carry zeros. No rule changed.
- **Adapter** (`dbus.rs`): the round-up of the retry time is one helper, `retry_secs`, used by `switch_to`, `create_profile` and `set_pin`.
- **Shell**: `DBusProfilesBackend` reads `QDBusPendingReply<QString, QString, uint, uint>` for create and `<QString, uint, uint>` for set-pin and emits the numbers in `createFinished` / `setPinFinished`; `probeAttempts` and its `<functional>` include are deleted (`rg probeAttempts` finds nothing outside the task history). The mock already reported these numbers and is unchanged.
- **Docs**: spec 03 §1.1 "UI flows" now says the replies carry the counts.

Tests: two new `service::tests` (`create_profile_reports_attempts_and_retry_time`, `set_pin_reports_attempts_and_retry_time`): a wrong PIN returns `wrong-pin` with 4, 3, 2, 1 attempts left and zero retry time; the fifth failure returns `locked-out` with `retry_after` = `FIRST_LOCKOUT`; the right PIN during lockout is still `locked-out`; success and rule failures carry 0 and 0, and rule failures do not touch the counter. The ten existing service tests were adapted to the new return types without changing what they assert.

Verification: `dev.ps1 rust` → ALL GREEN (17 tests in `ruya-profiles`, clippy for Windows and the Linux target, fmt); `dev.ps1 test` → ALL GREEN (77 passed, 7 screenshot tests skipped), including `tst_profile_admin.qml::test_add_profile_wrong_admin_pin` ("4 attempt(s) left") and `test_add_profile_locked_out_message`, unchanged. **Unverified:** the D-Bus reply parsing in `DBusProfilesBackend` and the zbus tuple replies at runtime (no bus on Windows); the recipe is in `docs/dev-setup.md` ("Against the real profiles service").

Deviations: none. UI behaviour is unchanged (the mock always produced these numbers).
