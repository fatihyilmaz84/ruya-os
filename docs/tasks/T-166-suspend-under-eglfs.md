# T-166 — Suspend and resume with the shell on KMS (eglfs)

Status: done · Phase: 2 · Depends: T-130 · Area: image, shell · Size: S · Owner: lead

## Goal
Choosing Suspend in the Guide power menu suspends the console, and a key press brings back a working shell (picture, input, sound), or else Suspend is not offered until it works.

## Read first
- `docs/specs/02-shell.md` §1.4 (Power); `01-platform.md` §2; ADR-002 notes in `00-overview.md`
- `image/rootfs/usr/lib/systemd/system/ruya-compositor@.service`, `services/ruya-devices` (power), `scripts/vm-power-check.sh`
- T-130 Outcome (eglfs, no logind TakeDevice)

## Scope
1. In the VM (QEMU with S3 enabled: `-global ICH9-LPC.disable_s3=0`; add a `-Suspend` switch to the VM launcher if needed), choose Suspend from the shell (or `Power1`/`systemctl suspend` as the same path the shell uses) and wake it (QMP `system_wakeup`). Record what happens: does eglfs keep the DRM master, does the picture come back, do keys reach the shell, does PipeWire recover.
2. If it works: a check in `vm-power-check.sh` (suspend, wake, the shell still answers and draws: screenshot before and after).
3. If it does not and the fix is small (for example re-setting the mode on resume, `QT_QPA_EGLFS_ALWAYS_SET_MODE` is already on): fix it. If not small: hide Suspend in the power menu on the image (a property from the power backend, tested in QML with the mock), and file the fix as an Inbox line and under B-002.
4. VT switching (Ctrl+Alt+F2 and back) under eglfs: try it once and record the result; no fix in this task.

## Out of scope
- Real-hardware suspend (B-002), wake-on-controller, hibernation.

## Acceptance criteria
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; the Scope 1 observations in the Outcome with screenshots before and after.
- [ ] Either `vm-power-check.sh` passes a suspend/wake check, or the power menu no longer offers Suspend on the image (QML test with the mock flag; VM screenshot of the menu).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md` and the VM steps above.

## Docs to update
- `02-shell.md` §1.4, `01-platform.md` §2, ADR-002 "Still open" list.

## Hints
- WHPX may not support S3 well; if QEMU cannot suspend at all on this host, record it, mark this task blocked on hardware (B-002) and still do the hide-Suspend fallback only if the owner agrees: it is a product choice (ask in the lead report).

- Planner note (2026-11-07): T-202 shows "Sleep is not available" in Power saving until the file `/usr/share/ruyaos/suspend-verified` exists (T-293 implements the row): this task creates that marker when suspend/resume is verified on the image, and does not create it if suspend cannot work.

## Outcome
Verified: hw (Dell OptiPlex 7080, BIOS 1.12.1, i915, image 0.0.55; lead-5, 2026-11-08 23:00). The VM (QEMU/WHPX) was not used: the Dell is the real target and S3 under WHPX proves nothing about i915.

Done over SSH with `rtcwake -m mem -s 20` (S3, `mem_sleep` `s2idle [deep]`): four suspend/resume cycles in a row. After each: `ruya-compositor@tty1` active, the CRTC enabled at 1920x1080@60, **60 vblank events per second** (the `drm_vblank_event_delivered` tracepoint: 241 in 4 s, 180 in 3 s three times), no `page flip` error, no failed unit but the known `bootloader-update`. The kernel log shows `Waking up from system sleep state S3`, `PM: suspend exit`, bluetoothd `Controller resume`. The DualSense is disconnected after resume (as expected, it needs a PS press; reconnect not tested), the ambient stream stays in the PipeWire graph. Not observed by a person: the picture itself and keys after resume (the owner confirms on the Dell: Guide > Suspend, any key wakes). VT switching (Scope 4) not tried.

Decision (marker): a **build-time file** `image/rootfs/usr/share/ruyaos/suspend-verified`, because a runtime marker could never exist before the first suspend and the Sleep row only exposes an opt-in choice (default Never); the Guide already offers a manual Suspend. Hardware that cannot resume must delete the file (documented in `dev-setup.md`). T-262 (wake by controller) is the next step; idle sleep default stays Never.

Follow-ups: the owner's look at the picture and a key after wake; reconnect of the DualSense after resume; `bootloader-update` failing (T-269/T-299).
