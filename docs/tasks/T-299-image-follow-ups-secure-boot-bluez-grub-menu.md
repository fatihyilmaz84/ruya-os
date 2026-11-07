# T-299 — Image follow-ups: a quiet bootloader-update on Secure Boot, BlueZ pairable timeout, grub-menu ordering, webp in the shell

Status: todo · Phase: 2 · Depends: — · Area: image, services (check scripts), shell (one help string) · Size: M · Owner: builder

## Goal
The Dell no longer shows a red `bootloader-update.service` on every boot, a crash can never leave the Bluetooth adapter pairable, the boot-menu unit cannot race greenboot, the shell can show a `.webp` wallpaper from a stick, and the player can read how to reach the boot menu.

## Read first
- `image/CLAUDE.md` (image quirks), `docs/specs/01-platform.md` (boot, updates), `docs/dev-setup.md` (image recipe), root `CLAUDE.md` Host: **"VM (this task)"** rules
- `image/build/enabled-units.txt` (bootupd), `image/rootfs/usr/lib/systemd/system/ruya-grub-menu.service`, `image/rootfs/usr/libexec/ruyaos/grub-menu-sync`, `image/build/20-base.sh` (package list), `scripts/check-boot-config.sh`, `vm-boot-check.sh`, `vm-devices-check.sh` (bluetooth part)
- T-203, T-269, T-208 Outcomes; STATUS-parked.md "Inbox triage 2026-11-07", bullets T-299 (Dell look-at list for the journal of the failing unit)

## Scope
1. **bootloader-update on Secure Boot:** on the Dell, Secure Boot is on and the firmware lacks the Microsoft UEFI CA 2023, so `bootupctl` refuses and the unit fails (harmless to booting). Add a drop-in that treats that refusal as success (`SuccessExitStatus=<the status seen in the Dell's journal>`, or `ExecStart=-` with the packaged command) and logs one line; do not hide other failures. Test machines may also document Secure Boot off (`dev-setup.md`). The exit status is read from the Dell journal; until then use `bootupctl`'s documented refusal code and say which in the Outcome.
2. **BlueZ `PairableTimeout`** in the image's `main.conf` (a second guard if a crash leaves the adapter pairable, T-203); value from the pairing window length (the shell/service closes windows itself).
3. **`ruya-grub-menu.service`:** `Before=greenboot-healthcheck.service` and the rollback-trigger unit (it remounts `/boot` rw/ro in a private namespace); `grub-menu-sync` fsyncs the directory after the rename.
4. **`qt6-qtimageformats`** in the package list so a webp wallpaper from a USB stick decodes; image size change in the Outcome.
5. **Boot menu help:** one line in Settings > System information (or About) in en and tr: "To open the boot menu, tap Esc as the console starts." (T-269 policy: hidden unless a boot failed.)

## Out of scope
- The dark gap between splash and shell (T-280), disk-encryption prompt (Phase 6), a brand wordmark (owner decision), Secure Boot key enrolment, the Dell's DPMS or boot timing.

## Acceptance criteria
- [ ] VM (this task): image built from this branch, `scripts\smoke-test.ps1` prints `RUYA_BOOT_OK`; `check-boot-config.sh` and `vm-boot-check.sh` PASS with new lines for: the bootupd drop-in present and `systemd-analyze verify` clean, `main.conf` has `PairableTimeout`, `systemctl show -p Before ruya-grub-menu` lists greenboot, `rpm -q qt6-qtimageformats` and `ls` of the webp plugin.
- [ ] `vm-devices-check.sh bluetooth` (or a small new part) shows `bluetoothctl show`/BlueZ reporting the configured timeout.
- [ ] `grub-menu-sync` shell test or the VM check proves the rename+fsync order (a `strace`-free check: the script text order is asserted by `check-boot-config.sh`).
- [ ] `tst_i18n.qml` has the new string in tr; screenshot of the line (reviewed).
- [ ] UX: nothing new to navigate; Outcome has a `UX notes:` line.
- [ ] `scripts\free-space.ps1` run after the VM checks (root CLAUDE.md).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
# image: scripts/build.sh, make-disk.sh in WSL (background), then:
.\scripts\smoke-test.ps1
```

## Docs to update
- `01-platform.md` (boot menu, bootupd note), `image/CLAUDE.md`, `docs/dev-setup.md`.

## Hints
- One image build at a time; only one "VM (this task)" task runs at a time (do not dispatch beside another).
- Overlaps T-280 (image, shell boot handover): run in sequence.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
