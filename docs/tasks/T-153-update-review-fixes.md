# T-153 — `ruya-update` review fixes: races, empty tag, corrupt channel file

Status: done · Phase: 2 · Depends: T-151 · Area: services, image, shell · Size: S · Owner: builder

## Goal
`ruya-update` survives the edge cases the 2026-11-01 lead review found: a rollback racing a check, a channel switch before the host's tag is known, and a bad channel file in `/var`, which today stops the service and fails every boot through the required greenboot check.

## Read first
- `docs/specs/01-platform.md` §4 (the "Built" paragraph)
- `services/CLAUDE.md`, `image/CLAUDE.md`
- `services/ruya-update/src/service.rs` (all of it), `main.rs`, `image/.../ruya-update.service`, `scripts/vm-update-check.sh`
- `docs/tasks/T-151-ruya-update-service.md` Outcome

## Scope
1. **Rollback race** (`service.rs`, `rollback`): today the busy/unavailable check runs under `inner`, the lock is dropped, and only then `command_lock` is taken, so a `Check` started in the gap can finish after the rollback and overwrite `inner.host` with the pre-rollback status. Take `command_lock` first, check busy/unavailable while holding it, and keep it across `bootc rollback` + `status`. Set `State::Staged` only if no other job started meanwhile.
2. **Empty tracked image** (`switch_target`): when `inner.host.tracked` is empty (startup `refresh` not finished or failed, or `spec.image` null), return `None` instead of a reference like `:beta`; `Check` then reports `failed` with a clear error (no `bootc switch` to a tagless reference).
3. **Corrupt channel file** (`load_channel`): an unknown value or unreadable `/var/lib/ruya-update/channel` must not stop the service. Start, follow the host's own tag, log the problem, and report it as the status `error` (state `failed`) until `SetChannel` writes a good file. Lead decision 2026-11-01: `/var` survives an image rollback, so a fatal start turns one bad file into a rollback loop through the required check `51-ruya-update.sh`; the required check stays.
4. **Untested branch:** a unit test for "bootc succeeded but staged nothing" (state `failed`, error "bootc staged nothing").
5. **Docs and comments:** `ProtectProc=invisible` does nothing while `CAP_SYS_PTRACE` is in the bounding set; say so in the unit's comment and in the T-151 Outcome's hardening list (don't remove the line). Fix the `Cargo.toml` comment (only `Rollback` goes through `blocking::unblock`) and the `vm-update-check.sh` comment above the `nightly` → `invalid` step. Spec 01 §4: one sentence that a staged download hides other channels until the reboot.
6. **Shell copy:** Settings → System shows the generic "update could not be started" for `forbidden` from `SetChannel`/`Rollback`; give it its own string ("Only an admin can do this.") with Turkish, and a test in `tst_update.qml` or `tst_system_ui.qml` using the mock's `forbidden` path.

## Out of scope
- Scheduled checks and the idle reboot (T-154).
- Sharing `caller_is_admin` with `ruya-store` (wait for a third admin-gated service).

## Acceptance criteria
- [ ] A test drives `rollback` and `begin_check` from two threads with a fake `bootc` that blocks, and asserts the final state is `staged` with the rollback's status (Rust test).
- [ ] With an empty tracked image and a remembered channel, `Check` ends `failed` and the fake never sees `switch` (Rust test).
- [ ] `Service::new` with a channel file reading `nightly` starts, follows the host tag, and reports `failed` with an error naming the file; `SetChannel("stable")` then clears it (Rust test).
- [ ] The "staged nothing" test exists and passes (Rust test).
- [ ] `forbidden` shows the new string (QML test).
- [ ] VM: image built, `RUYA_BOOT_OK`, `scripts/vm-update-check.sh` ALL PASSED; and with `echo nightly > /var/lib/ruya-update/channel` and a reboot, the service is active and greenboot reports the boot healthy (record the commands in the Outcome).

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md` (`build.sh`, `make-disk.sh qcow2`, `smoke-test.ps1`) and `scripts/vm-update-check.sh` over SSH.

## Docs to update
- `docs/specs/01-platform.md` §4; T-151 Outcome (hardening note); `docs/dev-setup.md` only if a command changed.

## Hints
- `command_lock` serialises `bootc` calls; `inner` guards state. Never hold `inner` while waiting on `command_lock` (the D-Bus status reads take `inner`).
- The fake `bootc` in `service.rs` tests already counts calls; add a blocking gate (a `Barrier` or channel) for the race test.

## Outcome
Verified: **vm** (service, unit, policy as packaged) and **host** (`dev.ps1 test` ALL GREEN: 243 QML + 20 screenshot skips, 32 `ruya-update` tests). `shots` not run: no visible UI change beyond one message string.

**Built**
- `service.rs`: `rollback` takes `commands` before it checks the rules and holds it across `bootc rollback` + `status`; a quick `Busy` check before the lock means it does not wait out a download. State becomes `Staged` only if no job started meanwhile. `switch_target` is `None` while `host.tracked` is empty; `run_check` does its `bootc` part in `check_locked`, which first reads `status` if the tracked image is unknown and fails with "bootc does not say which image this console follows" if it still is not. `Update::new` no longer fails: a channel file that is unknown or unreadable is logged, the host's own tag is followed, and `record()` reports state `failed` with the error naming the file (`/var/lib/ruya-update/channel: unknown channel "nightly"`) while the state is idle, up-to-date or failed (a staged image or running job still shows); `SetChannel` clears it. `main.rs` follows. The fake `bootc` got `hold_next_rollback` (test gate).
- Shell: `SystemPane.qml` shows "Only an admin can do this." (Turkish: "Bunu yalnızca bir yönetici yapabilir.") for `forbidden` from `SetChannel`, `Check`, `Download` and `Rollback`; `.ts` files edited by hand (locations are cosmetic).
- Comments and docs: `ProtectProc=invisible` note in the unit and in the T-151 hardening list, `Cargo.toml` and `vm-update-check.sh` comments, spec 01 §4 (staged download hides other channels until the reboot; bad channel file; unknown tracked image).

**Tests added:** rollback racing a check (fake `bootc` blocks inside `rollback`; final state `staged`, staged `0.0.18`, `check` after `rollback`), rollback busy during a download, empty tracked image (no `switch`, no `check`), check learning the tracked image, corrupt and unreadable channel file (start, `failed` with file name, check still works, `SetChannel` clears and rewrites), staged image not hidden by the bad file, "bootc staged nothing"; QML `test_forbidden_has_its_own_message`.

**Deviations:** the race test cannot fail on the old code in the exact interleaving (it needs a check slipping into the gap between two locks); it pins the new ordering instead (the check's `bootc` calls come after the rollback's). `Check`/`Download` `forbidden` cannot happen on the real service; the shared string is harmless there.

**VM** (image `0.0.22-t153`, WSL registry, work disk): `RUYA_BOOT_OK 0.0.22-t153`; guest `bootc switch <wsl-ip>:5000/ruyaos:stable` + `vm-reboot-check.ps1`; `echo nightly > /var/lib/ruya-update/channel`, `vm-reboot-check.ps1`: `RUYA_BOOT_OK`, `ruya-update` active, journal "ignoring the remembered channel", `GetStatus` state `failed` with the file in `error`, greenboot "required script 51-ruya-update.sh success!", "health-check passed", `boot_success=1`; `SetChannel stable` as root: `ok`, file rewritten, state `idle`. Then image `0.0.23-t153` pushed as `stable`: `scripts/vm-update-check.sh` ALL PASSED, `systemd-analyze security` 4.8 OK. Registry and tags removed afterwards. Greenboot's wanted script `01_update_platforms_check.sh` fails on every boot (pre-existing, not required; Inbox line).
