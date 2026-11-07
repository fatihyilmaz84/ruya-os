# T-269 — Boot experience: branded splash, silent boot, no boot menu unless a key is held

Status: done · Phase: 2 · Depends: — · Area: image · Size: M · Owner: builder

## Goal
From power-on to the shell the screen shows only the RuyaOS look: no kernel or systemd text, no boot-loader menu, a branded logo splash, then the shell. Owner request, 2026-11-07: "styling/branding of the boot logo, non verbose boot (don't show any text during boot), if possible don't show the boot options but boot directly (allow the option via a special key)". Rollback must stay reachable.

## Read first
- `docs/specs/01-platform.md` (boot sequence line 48, rollback and the GRUB menu lines 99 and 119, greenboot), `image/CLAUDE.md`
- `image/rootfs/usr/lib/bootc/kargs.d/10-ruyaos.toml` (today: `quiet splash loglevel=3 rd.udev.log_level=3`), `image/build/20-base.sh` (Plymouth, theme `spinner`), `image/build/90-initramfs.sh`, `image/build/92-branding.sh`
- `docs/specs/04-design-system.md` §1-§3 (colours, type, logo use); the Dreamglass backdrop art in `shell/` for the splash palette

## Scope
1. **Plymouth theme "ruyaos"** in the image: a dark Dreamglass-coloured background, the RuyaOS wordmark/logo centred and a calm progress indicator (no text, no percent). Use the project's existing logo; if none exists, set the name in Inter with the accent colour and file an Inbox line `design: needs logo` (a new logo is owner-level). Works on any resolution (scale to the framebuffer). Also the shutdown/reboot splash.
2. **Silent boot:** no console text between the firmware and the splash: kernel args (`quiet`, `loglevel=0` or the lowest that still keeps real failures visible on the log, `vt.global_cursor_default=0`, `systemd.show_status=false`, `rd.plymouth=1`), no text cursor, no tty1 login/getty flash, no fsck/udev noise; errors go to the journal. A boot that fails (greenboot) must still be diagnosable: the splash shows nothing, the journal has everything, and the rollback screen of the next point works.
3. **No boot menu:** the boot loader boots the default deployment without showing the menu (GRUB `timeout_style=hidden`/`menu_auto_hide`, short or zero timeout) and shows it when the player holds **Shift or Esc** (or taps F-key / Esc repeatedly) at power-on. Rollback stays reachable that way, and **after a failed boot the menu is shown** (greenboot / `boot_success` handling must still lead to the previous deployment). Menu entries read "RuyaOS", not "Fedora Linux".
4. **Handover to the shell** with no black or console flash: the splash stays up until the compositor draws its first frame (`plymouth quit --retain-splash` / `plymouth-quit-wait` ordering with `ruya-compositor@tty1`). Report the measured gap.
5. The ISO installer and its first boot follow the same rules where bootc-image-builder allows it; say in the Outcome what could not be changed there.

## Out of scope
- A secure-boot/shim logo (firmware draws that), an animated brand film, a new logo design (owner), Secure Boot signing changes.

## Acceptance criteria
- [ ] `scripts/check-image-manifest.sh` (or a new check) asserts the theme files, the kargs and the GRUB defaults are in the image.
- [ ] VM (this task): `scripts/build.sh` + `make-disk.sh qcow2` + `scripts\smoke-test.ps1` reach `RUYA_BOOT_OK`; `scripts/vm-screenshot.ps1` shots taken during boot show only the splash, never console text (list the shots and timestamps); a boot with a Shift/Esc key injected (`vm-keys.ps1`) shows the menu; the update/rollback drill (`vm-update-check.sh`, greenboot fallback) still ends on the previous deployment.
- [ ] Hardware (Dell, lead): no text between firmware logo and shell; the menu appears with Shift/Esc. UEFI firmware fast-boot may skip key detection: note it.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `01-platform.md` boot section and rollback lines, `image/CLAUDE.md` (a one-line quirk if found), `docs/dev-setup.md` (how to see the menu).

## Hints
- bootc on Fedora uses the grub2 BLS entries; the menu timeout lives in `grub2-editenv` variables / `/boot/grub2/grub.cfg` snippets written by `ostree`/`bootupd`: check what a kargs.d file and what a `/usr/lib/bootc` file can set, and what survives an update. Test through an update, not only a fresh disk.
- Plymouth needs `plymouth-plugin-script` (or two-step); check it is not removed by `50-slim.sh`.

## Outcome
Verified: vm (image 0.0.52-boot built and booted in QEMU/WHPX: `RUYA_BOOT_OK 0.0.52-boot`, shots during boot, Esc menu, update from a 0.0.51 disk, greenboot rollback drill). Not verified: hardware (the Dell), the ISO installer, 4K, a held Shift.

**What was built**
- **Plymouth theme `ruyaos`** (`image/rootfs/usr/share/plymouth/themes/ruyaos/`, module `script`): Dreamglass backdrop, wordmark "RuyaOS" in Inter (white "Ruya", lightened Ruya indigo "OS"), a faint track with a soft highlight gliding along it, no text. Sized by screen height, so it scales to any resolution. Same picture at reboot/shutdown (seen at a reboot in the VM). **There is no logo in the repository**, so the name is set in Inter as the task says; Inbox `design: needs logo`. The PNGs come from `scripts/make-boot-assets.py` (Pillow, committed output, deterministic). **One new package, `plymouth-plugin-script` (about 25 KB, row in `docs/image-packages.md`)**: the stock `two-step` plugin cannot scale images to the screen height; the theme must not be rebuilt without it (`lint-boot.ps1` checks it is installed and not slimmed away). `90-initramfs.sh` selects the theme, and fails the build if the theme or `script.so` is missing from the initramfs.
- **Silent boot:** `kargs.d/10-ruyaos.toml` now `quiet splash loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false rd.udev.log_level=0 udev.log_level=0 rd.plymouth=1 plymouth.enable=1 plymouth.ignore-serial-consoles`. Errors stay in `dmesg`/the journal. `getty@tty1` does not start (checked in the journal of a booted VM).
- **No menu:** bootupd's static GRUB config `07_ruyaos-menu.cfg` (disks installed from this image; it was confirmed in the built disk's `grub.cfg`) hides the menu with a 2 s window for Esc and shows it for 5 s when the previous boot was not healthy (`boot_success=0` or `boot_counter` set). **An image update does not rewrite a disk's `grub.cfg`**, so `ruya-grub-menu.service` + `/usr/libexec/ruyaos/grub-menu-sync` keep `/boot/grub2/custom.cfg` (marker line; `/boot` is read-only and is remounted for the copy) equal to `/usr/lib/ruyaos/grub-menu-custom.cfg`; `ruya_menu_policy` keeps the two from repeating each other. New unit in `enabled-units.txt` and the Containerfile.
- **Handover:** `plymouth-quit.service` quits with `--retain-splash` (drop-in) and `ruya-compositor@.service` stays after `plymouth-quit-wait` (see the measured gap below) and is now ordered before `plymouth-reboot/poweroff/halt/kexec.service`, so the shutdown splash shows.
- **Checks:** `scripts/lint-boot.ps1` (in `dev.ps1 test`, with a self-check that six deliberate mistakes in a copy of `image/` are reported, and in CI), `scripts/check-boot-config.sh [image]` (WSL, the built image: 26 checks incl. the theme and plugin inside the initramfs), `scripts/vm-boot-check.sh` (a booted VM over ssh), `scripts/vm-boot-shots.ps1` + `scripts/vm-boot-sheet.py` (screendumps while booting, contact sheet).

**VM results (image 0.0.52-boot, disk from `make-disk.sh qcow2`)**
- `smoke-test.ps1 -Work -Keep`: `RUYA_BOOT_OK 0.0.52-boot`. `check-boot-config.sh`: 26 ok, 0 fail. `vm-boot-check.sh`: all PASS on the fresh disk (policy in `grub.cfg`) and on the upgraded old disk (policy in `custom.cfg`).
- **Shots during a cold boot** (`output/boot-shots/final-cold/`, 161 screendumps, 300 ms apart; `vm-boot-sheet.py` lists the moments the screen changed): 3 ms QEMU's "Display output is not active"; 633 ms black; 1258 ms the firmware's TianoCore logo; 1571 ms OVMF's own two "BdsDxe" lines (firmware debug text of the VM, not ours); **nothing changes from 1571 ms to 13099 ms** (GRUB hidden, kernel and initramfs silent); 13099-24342 ms the splash (fade-in, then the gliding highlight, a change every ~310 ms); 24656-27145 ms (9 dumps) dark; from 27454 ms the shell. No console text anywhere after the firmware. For comparison, the 0.0.51 image (`output/boot-shots/exp-hidden/`): the screen fills with "[ OK ] Started ..." lines from 1.4 s to 7.8 s, then is black until the shell.
- **Gap between splash and shell, measured:** journal `plymouth-quit` to `ruya-shell: ready` 3.4 s (16.05 -> 19.45 s) in this boot and 4.3 s (14.65 -> 18.96 s) in the upgrade boot, software rendering in the VM. **The screen is dark in that gap, not the splash and not text.** `--retain-splash` does not keep the frame here, and `plymouth deactivate` instead of waiting for Plymouth to exit does not work: eglfs (unprivileged) then fails every page flip with "Permission denied" and the screen stays dark ("Display output is not active"). So criterion 4 is only partly met: no text and no getty, but a dark gap that needs a change outside the image (Inbox).
- **Esc shows the menu** (`esc2`, `esc-old`): a single Esc injected at 1.5 s (`vm-boot-shots.ps1 -Key esc -KeyFromMs 1300 -KeyCount 1`) shows GRUB with "RuyaOS 0.0.52-boot (ostree:0)" and "RuyaOS 0.0.51 (ostree:1)". Esc before the firmware has started GRUB opens OVMF's setup instead; Esc pressed repeatedly leaves the menu for the `grub>` prompt (seen). Held Shift: not tried (GRUB does not read modifier state on UEFI). Other keys (a space every 250 ms) did not show the menu.
- **Update path** (`bootc switch` of a 0.0.51 disk to 0.0.52-boot through a local registry, as the drill): the new kargs apply at the first boot of the new deployment (no systemd text, splash from the start); that first boot still shows the old 1 s menu (`old1`); `ruya-grub-menu.service` wrote `custom.cfg`; the second boot is silent with no menu (`old2`).
- **Rollback drill** (`bootc switch` to a 0.0.53-broken image whose shell cannot start, `GREENBOOT_MAX_BOOT_ATTEMPTS=3`): boot 1 of the broken deployment shows no menu (healthy before); boots 2 to 5 show the menu with the 5 s countdown after the failed boot (`drill2`..`drill5`); after the counter ran out greenboot booted the previous deployment: `RUYA_BOOT_OK 0.0.52-boot`, `bootc status` booted 0.0.52-boot, rollback 0.0.53-broken. A failed boot shows only the splash then black, no text. The failed boots took 85-106 s each (the shell check's timeout).

**Not done / limits**
- Hardware (Dell): not run. UEFI firmware with fast boot may start the keyboard too late for the 2 s window.
- ISO installer and its first boot: not built or booted (lead-run `vm-iso-check.ps1`). The installer's own boot menu and text come from bootc-image-builder/Anaconda and are not changed by this task; the installed system's first boot follows the same two paths as above (static config, or `custom.cfg` from the service), untested on an ISO install.
- The splash has no password prompt: a LUKS disk (Phase 6) will need `Plymouth.SetDisplayPasswordFunction` in `ruyaos.script`.
- Multi-monitor and 4K are not tested (the script sizes by `Window.GetHeight()`; shown only at the VM's 1280x800).
- Boot time: the hidden 2 s window is added to every boot.

**Deviations from the task text:** "Shift" is not offered (GRUB on UEFI); the splash is not kept through the gap (see above); one package added (`plymouth-plugin-script`); the text-cursor and `rd.plymouth=1` arguments are as listed, `fsck` noise is covered by `quiet`/`show_status=false` (no `fsck.mode` argument).


**Round 2 (review).** `lint-boot.ps1` now requires every `set timeout=` in `07_ruyaos-menu.cfg` and `grub-menu-custom.cfg` to be at least 1 (a zero timeout leaves no window for Esc, so rollback would be unreachable) and the exact `if [ -n "${boot_counter}" ]; then` line in `grub-menu-custom.cfg`; `dev.ps1 test` has two more self-check cases (a zero menu timeout, the boot_counter branch removed) that must make the lint fail. `check-boot-config.sh` also rejects a zero timeout. `vm-boot-check.sh` no longer claims the service restored `/boot` to read-only: from the host namespace it only shows the host's view (the remount happens in the service's own namespace), and says so. Still true: the dark gap between the splash and the shell's first frame (3.4-4.3 s in the VM) is open and filed as a follow-up; the 2 s hidden window stays.
