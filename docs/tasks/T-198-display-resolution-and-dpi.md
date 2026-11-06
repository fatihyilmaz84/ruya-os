# T-198 — Display: choose the resolution and refresh rate, and scale the UI to the screen (DPI)

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell, image · Size: M · Owner: lead

## Goal
Settings → Display lets the owner pick the resolution and refresh rate the TV or monitor supports, and the UI is sized right for the screen (a 1080p TV, a 4K TV, a 32" monitor) instead of one fixed size. Owner request, 2026-11-06. Today the pane has only effects quality, reduced motion and overscan; the shell is the compositor on KMS (Qt `eglfs_kms`), so there is no desktop tool that could do this.

## Read first
- `docs/specs/02-shell.md` (Settings, Display, text scale), `docs/specs/03-services-and-apps.md` §2.4 Display ("mode list and switching via the compositor (KMS); default is the TV's preferred mode, capped at 4K60"), `docs/specs/04-design-system.md` §1 (read from the sofa: 3 m from a 1080p TV, body text 30 px) and the text-scale rule
- `shell/qml/DisplayPane.qml`, `shell/src` DeviceSettings, `Theme.qml` (how the unit/scale is derived from the window size today), `image/rootfs/usr/lib/systemd/system/ruya-compositor@.service` and its environment (`QT_QPA_EGLFS_*`)
- Qt docs: eglfs KMS (`QT_QPA_EGLFS_KMS_CONFIG` JSON: per-output `mode`, `size`/`refresh`, `physicalWidth`/`physicalHeight`), `QT_SCALE_FACTOR`, `QT_FONT_DPI`

## Scope
1. **Find out what is true on the Dell first** (the owner's Samsung Odyssey G7 32" over HDMI/DP, Intel UHD 630): which modes the connector offers (EDID, `modetest`/`/sys/class/drm/*/modes`), what mode the shell picks now, the size it renders at, and how large the UI looks. Put the numbers in the Outcome.
2. **Contract + service:** a Display interface (new `org.ruyaos.Devices1.Display` or in `ruya-devices`) that lists the connected outputs with their modes (width, height, refresh, preferred, current), the physical size from EDID, and stores the owner's choice (output, mode, scale) under `/var/lib/…`. The service cannot change the mode of a running eglfs shell: the choice is applied by writing the KMS config JSON the compositor reads at start and restarting `ruya-compositor@tty1` (the shell comes back to the same page).
3. **Safe switching:** after a change the shell asks "Keep this resolution?" with a 15 s countdown and reverts to the previous mode if nobody confirms (a TV that cannot show the new mode must never leave the owner with a black screen); a failed start falls back to the preferred mode automatically (a marker file the compositor unit checks).
4. **UI scale (DPI):** `Theme` derives its unit from the output (physical size and resolution, or an owner override "Auto / 100 / 125 / 150 / 200 %" separate from the accessibility text scale) so 4K gets the same physical sizes as 1080p, and a close monitor gets sensible sizes. Decide whether to use `QT_SCALE_FACTOR` at start or the Theme unit; record why. Keep the 3 m / 1080p design target as the reference.
5. **Pane:** rows for Resolution (list of modes, preferred marked), Refresh rate, UI size, and the confirm/revert dialog; existing components only; Turkish strings; the mock offers three outputs for tests and screenshots.

## Out of scope
- HDR, VRR, refresh-rate matching for video (spec 2.4, later), several outputs at once, rotation.

## Acceptance criteria
- [ ] Rust tests for the mode list, the stored choice and the config JSON written (golden file), and for the fall-back marker logic.
- [ ] `tst_display.qml` (or the existing Display tests): the pane lists the mock's modes, selecting one opens the keep/revert dialog with a countdown, confirm keeps, timeout reverts, focus is on "Keep" and Back reverts; UI-size choices change the `Theme` unit (assert the unit, not pixels).
- [ ] Screenshots of the pane and the dialog, read against `04` §8.
- [ ] VM: the mode list in QEMU's virtual GPU, a switch, a revert by timeout; Hardware (lead): the Dell, two modes, one deliberate unsupported mode that reverts.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `02-shell.md`, `03-services-and-apps.md` §2.4, `04-design-system.md` (scale rule), the Devices1 XML, `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
