# T-153 — `ruya-update` review fixes: races, empty tag, corrupt channel file

Status: todo · Phase: 2 · Depends: T-151 · Area: services, image, shell · Size: S · Owner: builder

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
_Filled in by the implementer._
