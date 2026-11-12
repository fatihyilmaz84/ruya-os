# T-470 — A thawed app's sound is not put back (T-466 restore, VM 0.0.66)

Status: todo · Phase: 2 · Depends: — · Area: services (ruya-session), scripts · Size: S · Owner: builder · Complexity: complex · Developer surface: public-format

## Goal
T-466 parks a frozen app's playback streams on the `ruya-parked` null sink and restores them on Thaw. On image 0.0.66 (lead-12 VM queue, 2026-11-12) the Freeze half passes, the Thaw half fails: after `Thaw` answered ok and the app runs again, `vm-session-check.sh check` printed

```
FAIL: the thawed app's stream was not put back:
PASS: the thawed stream is not linked to ruya-parked
FAIL: the ruya-parked sink is still there after the Thaw
```

The probe after the Thaw printed nothing at all (no `stream=`/`target=` line), and the log shows no `park-audio ... frozen=[]` journal line after the Thaw. Before the Freeze the client was linked to `auto_null` (no card seen in the guest although the queue boots `-Audio`). If games stay silent after Resume on real hardware, this is the cause (LEAD-NOTES concern 1).

## Read first
- `docs/tasks/T-466-frozen-apps-release-audio-and-memory.md`: Scope item 1 and the Outcome (`sync_audio`, `Spawner::app_audio`, the retry, the VM check paragraph)
- `services/ruya-session/src/` (session core, the park-audio side effect), `scripts/vm-session-check.sh` (the Freeze part and `audio_probe`), `docs/specs/03-services-and-apps.md` (Freeze and Thaw)
- The full log of the failed run: rerun the check (below); the lead's copy was `output\vm-queue\vm-session-check-check.log` on the main checkout

## Scope
1. Find why the restore does not happen (or why the probe sees nothing): does Thaw call `sync_audio` with the app now running, does the park-audio side effect run and log, is the client's stream gone after the thaw (the probe found nothing), or is it a check bug.
2. Fix the cause in ruya-session (with a unit test in the pure core that would fail without it) or in the check (say why the check was wrong in the Outcome).
3. Also say whether the `-Audio` VM really has no card visible to the profile's sound server, and why (Inbox line if it needs more than a sentence).

## Out of scope
- The reclaim (passes), the Hub, anything in the shell.

## Acceptance criteria
- [ ] The cause is named in the Outcome with evidence (journal lines, probe output)
- [ ] A unit test (core fix) or a corrected check (check bug) that fails without the change
- [ ] VM (lead run): `vm-session-check.sh check` passes the Thaw part; `Verified: host (vm pending: vm-session-check.sh check)`
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- The lead can give you a booted VM of image 0.0.66 (`smoke-test.ps1 -Work -Audio -Keep`) to try the script and read the journal; ask in the HANDOFF if you need it.
- Planned by lead-12 from the 0.0.66 VM queue.

## Outcome
