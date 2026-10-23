# T-124 — Keyboard Guide key: Super opens the overlay

Status: todo · Phase: 1 · Depends: — · Area: shell, docs · Size: S

## Goal
A keyboard-only user can open the Guide overlay. Today the shell opens it only on `Qt.Key_HomePage` (the controller's Guide via `ruya-inputd`) and `Qt.Key_Menu`; in the VM `sendkey menu` did not open it (T-120), and spec 02 §4.2 promises `Super` / `Home`.

## Decision (lead, 2026-10-23)
- The **shell** maps keyboard keys; `ruya-inputd` stays a controller mapper (its replacement, InputPlumber, is B-006).
- Keyboard Guide = **Super** (left or right; `Qt.Key_Super_L`, `Qt.Key_Super_R`, and `Qt.Key_Meta`, which is what Qt reports for the Windows key on the Windows host). Holding it opens the power choices like a held Guide.
- **Not `Home`:** spec 02 §4.2 also gives Home/End to fast scroll, so Home cannot be Guide. Fix the spec table.
- `Key_Menu` is the Context-menu key in spec 02 §4.2. Find out why the shell treats it as Guide (`Shell.qml`, `git log -S Key_Menu`); if nothing depends on it, stop treating it as Guide, otherwise record why in the Outcome and the spec.

## Read first
- `docs/specs/02-shell.md` §4.2 (mapping), §4.3 (rules)
- `shell/qml/Shell.qml` (the root `Keys` handler and the Guide hold timer, T-107)
- `shell/tests/tst_power.qml` (Guide hold tests), `tst_shell.qml`
- `scripts/vm-keys.ps1`, `docs/dev-setup.md` "Seeing and driving the VM"

## Scope
1. Shell: the Super keys open/close the Guide overlay and their hold opens the power choices, exactly like `Key_HomePage` (one shared code path, no copy).
2. `Key_Menu` handling decided as above.
3. Spec 02 §4.2 table matches the code.
4. VM check: boot the image with `smoke-test.ps1 -Keep`, sign in, `vm-keys.ps1 meta_l` (QEMU's name for Super) opens the overlay; screenshot.

## Out of scope
- Other keyboard mappings from §4.2 (tab switch, fast scroll); they get tasks when the pages that need them exist.
- Remapping in `ruya-inputd`.

## Acceptance criteria
- [ ] Super opens and closes the overlay (test: `tst_shell.qml::test_super_toggles_overlay`, data-driven over `Key_Super_L`, `Key_Super_R`, `Key_Meta`).
- [ ] Holding Super opens the power choices (test in `tst_power.qml`, copying the Guide-hold test).
- [ ] `Key_Menu` behaviour matches the decision (test).
- [ ] In the VM, `vm-keys.ps1 meta_l` opens the overlay (VM screenshot path in the Outcome). This needs an image rebuild only if the shell changed; it did, so rebuild and boot with `RUYA_BOOT_OK`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Plus the WSL build, `make-disk.sh qcow2` and the VM steps above.

## Docs to update
- `docs/specs/02-shell.md` §4.2.

## Hints
- If cage or the VM swallows Super (some compositors reserve it), say so in the Outcome with evidence and leave the shell change in; it is still right for the compositor path (T-123).

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
