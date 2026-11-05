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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
