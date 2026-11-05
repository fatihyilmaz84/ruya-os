# T-188 — Store: the shell finds its running installs again after `ruya-store` restarts

Status: in-progress · Phase: 2 · Depends: T-182 (same crate) · Area: services, shell · Size: M · Owner: builder

## Goal
If `ruya-store` restarts (crash, update) while an install is running, the shell today loses the job: the progress bar hangs. After a restart the shell asks the service which jobs exist and shows their real state.

## Read first
- `docs/tasks/T-171-store-facade-robustness.md` Outcome (what the facade does when the service goes away; the restart-mid-install VM check)
- `api/dbus/org.ruyaos.Store1.xml`; `services/ruya-store/src/` (job table, `Install`/`Remove`); `shell/src/store/` (`DBusStoreBackend`, mock, job model); `scripts/vm-store-check.sh`
- `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Contract:** add `ListJobs() -> a(...)` (or a dictionary list in the style the XML already uses): id, app id, kind (install/remove), state, progress. Extend the XML first; service, mock and D-Bus client follow.
2. **Service:** answers from its job table. A job that was running when the service died is, after the restart, reported as `failed` with a reason (`interrupted`) unless Flatpak finished it (re-check the installed state), because the service cannot resume Flatpak's transaction.
3. **Shell:** when the Store backend reconnects (service owner changed), call `ListJobs`, replace the job list, and show the reconciled state (a hung "installing" becomes "failed, retry" or "installed"). A late reply to an old request must not overwrite newer data (use the guard from T-177/T-181 if merged, else the battery pattern).

## Out of scope
- Resuming a half-done Flatpak transaction, new Store UI.

## Acceptance criteria
- [ ] Rust tests for `ListJobs` and the post-restart mapping (running becomes `failed`/`interrupted`, or `installed` when the app is present); revert check noted.
- [ ] `tst_store_backend.qml`/`tst_store_ui.qml`: after a simulated service restart (name owner lost and regained) the job model matches `ListJobs`, not the stale list.
- [ ] Contract, mock, D-Bus client and service agree (names, argument order, state strings).
- [ ] VM (lead run): extend `scripts/vm-store-check.sh`'s restart-mid-install step to assert `ListJobs` after the restart. Outcome: `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` Store section; the XML doc comments.

## Hints
- Don't build an image.

## Outcome
Verified: host (vm pending: vm-store-check.sh)

What was built (all run on the host; the D-Bus client, the real unit and the state directory are exercised only by the VM check):

- **Contract** (`api/dbus/org.ruyaos.Store1.xml`): `ListJobs() -> aa{sv}`, one record per job: `id`, `app`, `kind` (`install` | `remove` | `update` | `rollback`), `state` (`queued` | `running` | `finished`), `status` (the `JobFinished` status once finished, else ""), `reason` ("" or `interrupted`), `percent`, `phase`. Deviation from the task text, which said "state ... failed": a finished job is `state finished` with `status failed` and `reason interrupted`, so the other failure kinds (`network`, `disk-full`, ...) keep their status in the same field and the shell maps it with the same strings as `JobFinished`.
- **Service** (`services/ruya-store`): new `jobs.rs` (job record, tab-separated file format read as untrusted input, trimming to the 20 newest finished jobs). The job table lives in `Store` and is written to `jobs` in `$STATE_DIRECTORY` (the unit already has `StateDirectory=ruya-store`; `RUYA_STORE_JOBS_FILE` overrides; neither set means memory only, as in `--session`) whenever a job is queued, starts or ends; progress is kept in memory only. Job names continue after a restart (`Queue::starting_at`), otherwise `job-1` would be reused and the shell would mix two jobs. `recover()` settles the jobs a previous run left queued or running once, before the first `ListJobs` answer and at the start of `sync`: a running install of an app that is installed now, and a running remove of an app that is gone, are `ok`; every other one (queued, update, rollback, `flatpak list` unreadable) is `failed`/`interrupted`. Jobs queued by the new run before the first `ListJobs` are not touched (`stale` ids). `ListJobs` on D-Bus runs `recover` through `blocking::unblock` (`flatpak list`).
- **Shell**: `StoreBackend::listJobs()` + `jobsListed(QList<StoreJob>)`, replies guarded by a `RequestSequence` in the base class (`beginJobsRequest`/`acceptJobs`/`deliverJobs`, T-181); the D-Bus backend calls it at start (via `Store`) and whenever the name appears, and adopts the still-running jobs of the reply into its job-to-app map (and forgets finished ones). `Store` replaces `jobs` by the table's running jobs, and for an app it had given up as `failed` at `serviceLost` whose latest job ended otherwise (Flatpak finished it: `ok`) it emits a second `jobFinished`; a job the table also calls `failed` is not reported twice. It emits `jobsReconciled()` after each application. T-171's behaviour is unchanged (the facade still ends the jobs of a lost service as `failed` at once, so no page waits for a service that never comes back); the table then corrects it. The mock keeps a job table too (`loseService` records interrupted jobs, `regainService(finishedApps)`, `forgetJobs`, `listJobsDelayed`), reachable from tests as `Store.mockServiceRegained/mockForgetJobs/mockListJobsDelayed/mockPendingJobLists`.
- **Tests**: Rust (`jobs.rs` 4, `queue.rs` 1, `service.rs` 10 new): file round trip, damaged file, trimming, name continuation, queued/running x install/remove/update/rollback mapping after a restart, `flatpak list` failing, second restart agrees, jobs of the new run untouched by recovery, `sync` settles without a client. QML: `tst_store_backend.qml` (interrupted stays failed with one verdict, Flatpak-completed install becomes installed, new service's running job is shown, a stale `jobs` entry is replaced, a late table is dropped) and `tst_store_ui.qml` (page offers Install again after an interrupted job; page goes from the error to Open when Flatpak completed it).
- **VM check** (`scripts/vm-store-check.sh`, `scripts/vm-store-probe.qml`): after the restart-mid-install step it calls `ListJobs` (no queued/running job, the app's job is `finished` and either `failed`/`interrupted` or `ok` with the app installed, `jobs` file exists), checks the probe's `Store` applied the table (`jobsReconciled` at least twice, empty `jobs`), and checks that the next job's number is higher than the old one. Not run here.

Revert checks: with the `jobs` replacement in `Store` removed, `test_job_table_replaces_a_stale_entry` and `test_restart_shows_the_jobs_the_new_service_runs` fail; with the correction for lost apps removed, `test_restart_finds_the_install_flatpak_completed` and `test_restart_after_flatpak_completed_the_install` fail; with `deliverJobs` not checking the sequence, `test_a_late_job_table_is_dropped` fails; in Rust, with `Queue::starting_at` replaced by a fresh queue, `a_restart_keeps_finished_jobs_and_never_reuses_a_name` fails; with the install mapping forced to "not done", `a_running_job_is_interrupted_unless_flatpak_finished_it` fails; with recovery touching all active jobs instead of the stale ones, `recovery_leaves_the_jobs_of_this_run_alone` fails.

Files: `api/dbus/org.ruyaos.Store1.xml`, `services/ruya-store/src/{jobs,queue,service,dbus,app,main,lib}.rs`, `shell/src/store/{StoreBackend.h,DBusStoreBackend.*,MockStoreBackend.*,Store.*}`, `shell/tests/tst_store_backend.qml`, `shell/tests/tst_store_ui.qml`, `scripts/vm-store-check.sh`, `scripts/vm-store-probe.qml`, `docs/specs/03-services-and-apps.md`, `docs/dev-setup.md`.

Unverified: the real D-Bus path (`DBusStoreBackend::listJobs`, adoption of running jobs), the state file under `ProtectSystem=strict`, and that `systemctl restart` kills the Flatpak child (the VM check covers all three). Starting the shell while a job already runs (the start-up `ListJobs` adopting it) has no host test: the mock has no job at construction.

Follow-ups (Inbox):
- (T-188) A job adopted from `ListJobs` at shell start shows in `Store.jobs`, but a page opened on that app does not know it is `working` (its flag is local to the page that started the job); a page should derive `working` from `Store.jobs`.
- (T-188) A queued job lost in a restart is `failed`/`interrupted` even though it never started; re-queueing it would need the operation (remote, delete-data flag, commit), which the file does not store.
