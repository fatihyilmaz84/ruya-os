# T-159 — `ruya-update`: notice before the automatic restart; retry a failed download

Status: done · Phase: 2 · Depends: T-154 · Area: api, services, shell · Size: M · Owner: builder

## Goal
Nobody loses a session to the nightly update restart: the console announces it two minutes ahead on screen, any button press calls it off, and a scheduled download that failed is tried again within the hour instead of a day later.

## Read first
- `docs/specs/01-platform.md` §4 (the "Schedule" paragraph), `02-shell.md` §5.1 (toasts)
- `api/dbus/org.ruyaos.Update1.xml`, `services/ruya-update/src/schedule.rs`, `service.rs` (`tick`, `scheduled_check`, `scheduled_restart`), `main.rs`
- `shell/src/update/`, `shell/qml/SystemPane.qml` (the staged toast), `Notifications` usage in `Shell.qml`
- UI: `04-design-system.md` §5 (Toast), §7 (copy); new tokens or components: none
- `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Grace period** (pure core): when the restart rules first hold (T-154: window, 30 idle minutes, no app, setting on, image staged), the service does not reboot at once; it sets a pending restart time `now + 120 s` and reports it. At a tick at or after that time, if the rules still hold, it reboots. Any `ReportActivity`, the setting turned off, or the image no longer staged clears the pending time (then the usual 30 idle minutes start again).
2. **Contract first:** a record key, for example `restart_at` (x, unix seconds, 0 = none), with `StatusChanged` when it is set or cleared; XML header text. Mock, D-Bus client and `Update` (`restartAt`) follow.
3. **Shell:** while `restart_at` is set, a `warning` toast "Restarting to finish the update in 2 minutes. Press any button to wait." stays up (no auto-dismiss) and goes when it clears. Input already reaches the service through `Update.noteActivity`; make sure the press that should cancel is not swallowed by the once-a-minute limit (report at once while a restart is pending).
4. **Retry:** a download started by the schedule that fails is tried again after `RETRY_SECS` (one hour), as a failed scheduled check is; a manual download is not retried.
5. Turkish for the new strings; spec 01 §4 and 02 §5.1.

## Out of scope
- A "Restart now" or "Postpone until tomorrow" button, a countdown that ticks every second, a toast after the restart ("Updated to …").
- Changing the window, the idle time or the grace length into settings.

## Acceptance criteria
- [ ] Fake clock: quiet → `restart_at` = now + 120 and no reboot; a tick at + 119 s no reboot; at + 120 s one reboot (Rust test).
- [ ] Activity, setting off, or nothing staged during the grace clears `restart_at` and no reboot follows; quiet again only after 30 more idle minutes (Rust tests).
- [ ] A failed scheduled download is retried after an hour, not before; a failed manual download is not retried (Rust tests).
- [ ] Mock: `restart_at` set → the toast is visible with the text above; cleared → gone; a key press while pending reports activity at once even inside the minute (QML tests in `tst_update.qml`).
- [ ] Screenshot of Home with the pending-restart toast, reviewed against `04` §8.
- [ ] VM: image built, `RUYA_BOOT_OK`; `scripts/vm-update-check.sh reboot` extended: with an image staged and the guest clock at 03:10, `GetStatus` shows `restart_at`, a `ReportActivity` as `ruya-shell` clears it and no reboot follows; a second run without activity reboots after the grace and boots the staged image.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the image recipe in `docs/dev-setup.md` and `vm-update-check.sh` over SSH.

## Docs to update
- `docs/specs/01-platform.md` §4, `02-shell.md` §5.1, the Update1 XML header.

## Hints
- Keep the decision in `Schedule` (`pending_restart: Option<i64>`); `scheduled_restart` only reads it. `main.rs` ticks every 60 s, so the reboot lands 120–180 s after the notice; that is fine.
- T-154's `vm-update-check.sh reboot` mode already sets the guest clock; copy it.

## Outcome
Verified: host (vm pending: lead runs `vm-update-check.sh reboot`). `dev.ps1 test` ALL GREEN (271 QML + 22 skips; `ruya-update` crate 70 tests, +14); `dev.ps1 shots` ALL GREEN (57), `26-restart-notice.png` reviewed against 04 §8: warning bar and text readable on the toast card, two lines, no overlap with the header or the focus ring.

**Built.**
- *Contract* (`org.ruyaos.Update1.xml`): record key `restart_at` (x, unix seconds, 0 = none), only non-zero while state is `staged` and `auto_restart` is on; the header describes the notice, the cancelling events and the download retry. `StatusChanged` when it is set or cleared (also by `ReportActivity`, which now emits when it called a restart off).
- *Service* (`schedule.rs`, `service.rs`, `dbus.rs`): `Schedule::restart_step(now, minute, can)` holds the decision (`pending_restart: Option<i64>`, `GRACE_SECS` = 120): the first look where the rules hold announces `now + 120`, a look at or after it reboots if they still hold, anything else clears it (a time more than a grace ahead, from a clock set back, is replaced). `activity()` clears it and says whether it did; `set_auto_restart(false)` clears it; `scheduled_restart` only reads it and emits when it changed. Retry: `Schedule` notes a failed *scheduled* download (`download_failed`); `tick` starts it again after `RETRY_SECS` (`scheduled_download_retry`); `begin_download` (every download, including the user's) clears the note, so a failed manual download is never retried and a manual download takes over a scheduled failure. A retry that fails is retried again after another hour. `FakeBootc::fail_next_call(name, msg)` is new (fail one named command; the existing tests that expected an immediate reboot now go through the grace).
- *Shell:* `UpdateStatus.restartAt`, the D-Bus client, the mock (`mockAnnounceRestart`; `reportActivity` clears `restartAt` like the service), `Update.restartAt/restartPending` (+ `restartPendingChanged`), `Update.noteActivity` reports every press while a restart is pending. `Notifications.showSticky(key, text, kind)` / `remove(key)` (toast without timer; `ToastLayer` takes a `sticky` role); `Shell.qml` shows the warning toast while `restartPending`. Turkish added (`ruyashell_tr.ts`, `_en.ts`).
- *Tests:* Rust 14 new (grace 119/120 s, activity, app start, setting off, nothing staged, window end, clock set back, retry after an hour and again, manual not retried, manual takes over); QML 4 new in `tst_update.qml` (toast appears and stays past `durationMs`, cleared by the service, shown once per announcement, a press inside the minute is reported at once and calls it off) and one screenshot test.
- *Docs:* `01` §4, `02` §5.1, `04` §5 (Toast row), `dev-setup.md`, the XML header.
- `scripts/vm-update-check.sh reboot` extended (written, **not run**): clock to 03:10 tomorrow, wait for `restart_at` (within 90 s, at most 120 s ahead), `ReportActivity` as `ruya-shell`, `restart_at` is 0 at once, 200 s with no reboot and no new announcement, clock +31 minutes, announced again, no activity, wait for the reboot (QEMU exits). The record check also asserts `restart_at` = 0 when idle.

**Deviations.**
- *Build fix: kernel upgrade leftovers.* Fedora shipped kernel 7.2.15 while the base image has an older one, so `40-nvidia.sh` upgrades the kernel in the container and leaves `/boot/symvers-7.2.15-200.fc44.x86_64.xz` (lint `nonempty-boot`) and `/var/lib/rpm-state/kernel` (lint `var-tmpfiles`); `bootc container lint --fatal-warnings` failed `0.0.29-t159a`. `image/build/99-cleanup.sh` now empties `/boot` and removes `/var/lib/rpm-state` (commented). Build `0.0.29-t159a` with the fix passed the lint (14 checks), `make-disk.sh` produced `disk.qcow2`, and the image was pushed to the WSL registry as `localhost:5000/ruyaos:stable` (the registry container is stopped). Not booted by me.
- `dracut-install: ERROR: installing '/root'` appears in `90-initramfs.sh`'s output; the initramfs was still created. Whether it matters is for the VM boot (Inbox).
- Nothing was run in a VM (owner rule 2026-11-03: logic-only service tasks stop at the host). The real-bus behaviour (the `StatusChanged` from `ReportActivity`, the shell's D-Bus client reading `restart_at`) is unverified until then.
- The 22nd skip is the new screenshot test.

**Follow-ups (Inbox).** The `dracut-install` message; the language flip seen in tests.
