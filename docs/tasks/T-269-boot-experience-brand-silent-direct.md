# T-269 — Boot experience: branded splash, silent boot, no boot menu unless a key is held

Status: todo · Phase: 2 · Depends: — · Area: image · Size: M · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | hw`._
