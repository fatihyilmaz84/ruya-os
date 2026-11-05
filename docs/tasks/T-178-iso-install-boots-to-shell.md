# T-178 — A freshly installed ISO boots to the shell (no manual step)

Status: in-progress · Phase: 0 · Depends: — · Area: image, scripts · Size: M · Owner: builder

## Goal
Write the installer ISO to a USB stick, install, reboot: the machine reaches the shell and greenboot passes, with nobody logging in to fix anything. Today the install boots to text mode (the 0.0.40 try-out), greenboot reboots it in a loop, and the ISO cannot go on the Dell (B-002).

## Read first
- `docs/dev-setup.md` "Installer ISO (real hardware)": the known problem (Anaconda sets `/etc/systemd/system/default.target` to `multi-user.target`) and how to test an ISO in QEMU by hand
- `image/CLAUDE.md`; `image/Containerfile` (line ~62 sets the default target in the image, which the install overrides); `image/rootfs/usr/lib/systemd/system/ruya-compositor@.service` (`WantedBy=graphical.target`) and every other unit with `WantedBy=graphical.target`
- `scripts/smoke-test.ps1` (`-Disk`, `-Persistent`), `scripts/make-disk.sh` (`anaconda-iso`)

## Scope
1. **Boot to the shell whatever `default.target` the installer leaves.** Preferred: make the units that must run (`ruya-compositor@`, anything else that is `WantedBy=graphical.target` and needed for the shell or greenboot's required checks) also `WantedBy=multi-user.target`, so the result does not depend on the default target. Alternative if that is not clean: a bootc-image-builder kickstart snippet (`customizations.installer.kickstart`) that runs `systemctl set-default graphical.target`. Pick one by trying it; say why in the Outcome. It must hold for the qcow2 too.
2. **Silence `dracut-install: ERROR: installing '/root'`** in `image/build/90-initramfs.sh` (Inbox since T-159; the initramfs is written anyway, so the fix must not hide a real failure).
3. **Branding of the installed system's boot menu:** the entries say "Fedora Linux 44". Make `NAME`/`PRETTY_NAME` in the image's `os-release` say RuyaOS (keep `ID`, `VERSION_ID` and `ID_LIKE` as they are, so tooling that keys on them keeps working). Check `bootc container lint --fatal-warnings` and the installer still pass; if the installer or bootc breaks, revert this item and say so in the Outcome. If the ISO's own boot menu can be branded by a bib setting, do it; if not, record that.
4. **`scripts/vm-iso-check.ps1`:** automate the by-hand ISO test in `dev-setup.md` (blank qcow2, QEMU with the ISO as in `smoke-test.ps1`, wait for `Install finished`, then `smoke-test.ps1 -Disk … -Persistent`, assert `RUYA_BOOT_OK` and report `systemctl get-default`; delete the test disk at the end, also on failure). It takes minutes: it is a lead-run VM check, not part of `dev.ps1 test`.

## Out of scope
- The owner decisions about the dev ISO (it erases every disk, carries the dev key, tracks `localhost/ruyaos:dev`): they stay in STATUS "Open owner decisions".
- Backspace, Store and other try-out bugs (own tasks); a real installer UI (Phase 3).

## Acceptance criteria
- [ ] VM (this task): build the image and the ISO, run `scripts/vm-iso-check.ps1`: the installed disk reaches `RUYA_BOOT_OK` on its first boot with no manual step, and greenboot reports success (record the version tag and the output).
- [ ] The qcow2 path still passes `scripts\smoke-test.ps1`.
- [ ] The build log no longer prints the `dracut-install ... '/root'` error, and `bootc container lint --fatal-warnings` passes.
- [ ] The installed system's boot entry title says RuyaOS (or the Outcome says why not).
- [ ] `dev-setup.md` no longer lists the multi-user problem; it documents `vm-iso-check.ps1`. `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
Image recipe in `docs/dev-setup.md`; `scripts/build.sh`, `scripts/make-disk.sh anaconda-iso` in WSL (background, 3-30 min), then `scripts\vm-iso-check.ps1`; end with `scripts\free-space.ps1`.

## Docs to update
- `docs/dev-setup.md`; `docs/specs/01-platform.md` if the boot targets are described there.

## Hints
- `image/bib/config.toml` is git-ignored: copy it from the main checkout into a fresh worktree before `make-disk.sh` (otherwise the disk has no SSH key).
- An ISO install erases the disk it is given; the check only ever uses a scratch qcow2 under `output\`.
- Greenboot's required checks and the compositor are ordered around `graphical.target`; if you add `WantedBy=multi-user.target`, re-read the unit's `Before=`/`After=` so there is no ordering cycle (`systemd-analyze verify`).

## Outcome
Verified: vm (version 0.0.41-t178: image built, qcow2 and ISO made in WSL, `smoke-test.ps1` and `vm-iso-check.ps1` run on this machine, 2026-11-05).

**Boot target (scope 1).** Took the preferred option: `ruya-compositor@.service` and `ruya-boot-marker.service` are now `WantedBy=graphical.target multi-user.target`. No kickstart snippet was needed, and it holds for the qcow2 and the ISO. The other units pulled by `graphical.target` (`accounts-daemon`, `rtkit-daemon`, `udisks2`, `upower`) are D-Bus activated and not needed at boot, so they were left alone. No ordering cycle: `systemd-analyze verify` on both units and both targets inside the 0.0.41-t178 image printed nothing, and the VM boots below ran. `Before=graphical.target` stays on the compositor. Because Anaconda overrides the default target, the image still sets `graphical.target`; the unit does not depend on it.

**Proof (VM).**
- `scriptsm-iso-check.ps1` on the 0.0.41-t178 ISO: `Install finished after 246 s`, first boot of the installed disk `RUYA_BOOT_OK 0.0.41-t178`, then over SSH `default.target: multi-user.target` (the link is `/etc/systemd/system/default.target -> /usr/lib/systemd/system/multi-user.target`, as Anaconda leaves it), `greenboot-healthcheck: active`, `greenboot-success.target: active`, `boot-complete.target: active`, grubenv `boot_success=1`, `bootc status` booted `localhost/ruyaos:dev`, version `0.0.41-t178`. `ISO CHECK PASSED`, test disk deleted.
- Negative control: the same script on the 0.0.40 ISO (from the main checkout) installs, then QEMU exits during the first boot (greenboot's reboot, `-no-reboot`) and prints `no marker`, `ISO CHECK FAILED`, exit 1. So the check detects the bug this task fixes.
- `scripts\smoke-test.ps1` on the qcow2: `RUYA_BOOT_OK 0.0.41-t178`.

**dracut (scope 2).** Cause: in a bootc image `/root` is a symlink to `var/roothome`, which does not exist while the container builds; dracut's base module installs `/root` and `dracut-install` failed on the dangling link (the initramfs was written anyway). `image/build/90-initramfs.sh` now creates the link target only when `/root` is a dangling symlink, runs dracut, and removes it again (`/var` must stay empty for `bootc container lint` and 95-var-tmpfiles). The 0.0.40 log had the `ERROR: installing '/root'` and `FAILED:` lines; the 0.0.41-t178 build log has none (`grep` count 0), a real dracut failure still fails the build (`set -e`), and `bootc container lint --fatal-warnings` passed (`Checks passed: 14`).

**Branding (scope 3).** New `image/build/92-branding.sh` (run after 90 in the same layer, so the version file exists): `NAME="RuyaOS"`, `PRETTY_NAME="RuyaOS <version>"` in `/usr/lib/os-release`; `ID=fedora`, `VERSION_ID`, `ID_LIKE` untouched, and the script asserts them. Lint and the Anaconda install still pass. The installed system's GRUB entry reads `RuyaOS 0.0.41-t178 (ostree:0)` (seen in the serial log of the qcow2 boot). The ISO's own boot menu ("Install Fedora Linux 44") is not changed: bootc-image-builder builds it from its own distro definition and `config.toml` has no setting for the product name (I did not look into rebuilding the ISO's boot assets; recorded as an Inbox line).

**Check script (scope 4).** `scripts/vm-iso-check.ps1` (lead-run; not in `dev.ps1 test`): blank 64G qcow2 under `output\`, QEMU with the ISO as CD and its own serial log (`output\iso-install-serial.log`, so `smoke-test.ps1` can start afterwards), waits for `Install finished`, runs `smoke-test.ps1 -Disk ... -Persistent -Keep`, polls greenboot over SSH up to 4 minutes, prints `systemctl get-default` and the other state, always stops QEMU and deletes the disk (`-KeepDisk` to keep). Exit 0 only if the install finished, `RUYA_BOOT_OK` printed and greenboot's health check and success target are active.

**Files:** `image/Containerfile`, `image/build/90-initramfs.sh`, `image/build/92-branding.sh` (new), `image/rootfs/usr/lib/systemd/system/ruya-compositor@.service`, `.../ruya-boot-marker.service`, `scripts/vm-iso-check.ps1` (new), `docs/dev-setup.md`, `docs/specs/01-platform.md`, this file.

**Deviations:** none. `dev.ps1 test`: ALL GREEN (346 passed, 28 screenshot skips as always). No UI change, so no `shots`. Disk space: `free-space.ps1` run after the VM checks.

**Not verified:** the ISO on real hardware (B-002, owner); the ISO's own boot-menu branding.
