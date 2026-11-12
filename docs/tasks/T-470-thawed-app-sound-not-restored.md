# T-470 — A thawed app's sound is not put back (T-466 restore, VM 0.0.66)

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-session), scripts · Size: S · Owner: builder · Complexity: complex · Developer surface: public-format

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
Verified: host (vm pending: vm-session-check.sh check)

**Cause: a check bug, not ruya-session.** The check stops `ruya-compositor@tty1` for the Freeze part (so the shell's sweep does not thaw its Freezes). `ruya-shell` does not linger, so logind stops `user@<ruya-shell uid>.service` 10 s later (`UserStopDelaySec=10`, the Fedora default), and with it PipeWire, WirePlumber and every profile's `ruya-pulse@` server. The Freeze's park ran about 1 s after the stop and passed; the Thaw came after the 30 s reclaim wait, when the manager was gone:
- the three `systemd-run[...]: Failed to start transient service unit: Transport endpoint is not connected` warnings at 08:49:11, :13 and :15 in the run's journal tail are, by their 2 s spacing and their time (16 s before the next section's `reset-failed`), the Thaw's `park-audio` request and its two retries (`PARK_TRIES` 3, `PARK_RETRY` 2 s); its `park-audio ... failed` lines were not printed because the check greps only `... done`;
- the probe printed nothing because `pw-dump` as `ruya-shell` had no PipeWire to talk to (`audio_probe` is empty when `pw-dump` fails), so neither the `stream=` nor the `parked_sink=no` line could match;
- reproduced on the Dell (0.0.66): after `systemctl stop ruya-compositor@tty1`, `user@972` was still `active` at 2 s and `inactive` at 15 s, the journal shows `Stopped user@972.service` and `Stopped user-runtime-dir@972.service`, and `systemctl --user -M ruya-shell@.host is-active 'ruya-pulse@*'` and `pw-dump` then answered `Transport endpoint is not connected` / failed: the same error as the VM. With `loginctl enable-linger ruya-shell` before the stop, the manager, PipeWire and `ruya-pulse@ruya-p1` were still active at 30 s, and after the start and `disable-linger` they stayed active (seat session back within 1 s).
The core does call `sync_audio` on the Thaw with the app running (`a_frozen_apps_sound_is_parked_and_put_back_on_the_thaw` covers it, and the request reached the worker: it was the job that failed three times), so no service change and no new unit test.

**The fix (`scripts/vm-session-check.sh`).** Before it stops the shell, the check remembers whether `ruya-shell` lingers, runs `loginctl enable-linger ruya-shell`, and after `systemctl start ruya-compositor@tty1` waits (up to 10 s) for the `ruya-shell seat0` session and takes the linger back (`disable-linger`, only when it was off before). New assertion just before the Thaw: `ruya-shell's manager still runs with the shell stopped (it lingers)`; without the linger it fails (Dell: `inactive` 15 s after the stop), so the check names the cause instead of an empty probe.

**No card in the `-Audio` VM (Scope 3).** The card is the seat session's alone: logind gives `/dev/snd/*` to the active seat session by its `uaccess` ACL, and the compositor's session is the only one `ruya-shell` has on the seat. With the shell stopped the ACL goes (Dell: the `user:ruya-shell` entry on `/dev/snd/pcmC0D3p` disappeared at once) and WirePlumber leaves only `auto_null`; `cards=auto_null:running` in the failing run was read with the shell stopped, so it says nothing about the VM's card. The check now prints `cards with the shell running:` just before it stops the shell, and the UNVERIFIED line says why no card is seen (see Inbox for seeing the card's suspend).

**Spec.** `03` (Freeze and Thaw, the sound parking): the park and restore need `ruya-shell`'s manager, which lives only while the compositor's session holds it, and the card is the seat session's.

**Revert test.** Not a Rust/QML test: the reverted state (no linger) is the 0.0.66 run itself (FAIL on the restore) and the Dell reproduction above (the new manager assertion would read `inactive`). The VM run of the corrected check is the lead's.

**Developer surface.** The header says `public-format`, but this diff changes no format, D-Bus method or file an app reads: only the check and a spec paragraph describing existing behaviour. Nothing for `docs/developers/`.

**Dell.** Stopped and started `ruya-compositor@tty1` three times (two probes and the fix trial, about 20 to 50 s each). In the second probe `ruya-shell`'s manager stopped, which ended `ruya-pulse@ruya-p1` and `ruya-pulse@ruya-p2`; they were started again by hand (`systemctl --user -M ruya-shell@.host start ruya-pulse@ruya-p{1,2}`). Linger of `ruya-shell` was set and taken back (off, as before). No reboot, no files left.

Files: `scripts/vm-session-check.sh`, `docs/specs/03-services-and-apps.md`, this task file.
