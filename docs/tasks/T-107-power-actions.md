# T-107 — Power actions (suspend, restart, power off)

Status: todo · Phase: 2 · Depends: T-101 · Area: shell, image · Size: M

## Goal
The Power page and the Guide overlay offer Suspend, Restart and Power off with a confirmation, through systemd-logind. The mock records the calls for tests.

## Read first
- `docs/specs/01-platform.md` §2.2 (suspend/power)
- `shell/src/profiles/` (backend pattern), `shell/CLAUDE.md` ("Modals from pages": the confirmation is a page-owned modal parented to `page.overlay`)
- `shell/qml/Shell.qml`: the Guide key is handled on the root and opens the overlay on **press**; a long-press needs the decision to wait for the release
- logind D-Bus API: `org.freedesktop.login1.Manager` methods `Suspend(b interactive)`, `Reboot(b)` and `PowerOff(b)` on `/org/freedesktop/login1` (system bus). There's no RuyaOS contract file for this; it's an upstream API.

## Scope
1. `src/power/`: `PowerBackend` (abstract), `MockPowerBackend` (records `lastAction`, emits `done`), `DBusPowerBackend` (calls logind with `interactive=false`), and a `Power` singleton:
   - `suspend()`, `restart()`, `powerOff()`;
   - `canSuspend` etc. from logind `CanSuspend`/`CanReboot`/`CanPowerOff`; the mock reports all `yes`.
2. `PowerPage.qml` (replacing T-101's placeholder): three rows. Accept opens a confirmation dialog: "Restart now?" with Cancel (default focus) and Confirm. Confirm calls the action.
3. The Guide overlay gets a "Power" action that opens the same confirmation choices.
4. Holding Guide for 2 s opens the power menu directly (spec §2.2). Implement with key press/release timing on `Key_HomePage`; a short press keeps opening the overlay.
5. Image: add a polkit rule `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-power.rules` allowing the `ruya-shell` user `org.freedesktop.login1.{suspend,reboot,power-off}` (and the `-multiple-sessions` variants) without authentication. **Unverified on this host.**

## Out of scope
- Idle auto-suspend timers.
- Wake-on-controller configuration.

## Acceptance criteria
- [ ] Confirming "Restart" calls the mock with `restart`; Cancel calls nothing (test `tst_power.qml::test_confirm_and_cancel`).
- [ ] The confirmation dialog opens with focus on Cancel (test `test_default_focus_is_cancel`).
- [ ] A Guide press shorter than 2 s opens the overlay; holding it ≥ 2 s opens the power menu (test `test_guide_long_press`, using `keyPress`/`keyRelease` with `wait`).
- [ ] The polkit rule file exists, matches the user `ruya-shell` and the exact action ids, and is reviewed in the Outcome.
- [ ] Screenshot `13-power-confirm.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/01-platform.md` §2.2: what is implemented.
- `docs/STATUS.md`: polkit rule and logind calls **unverified**.

## Hints
- Holding a key on a real controller produces autorepeat key events (`event.isAutoRepeat`). Ignore those when timing the long press.
- Today a Guide press opens the overlay immediately and `tst_shell.qml`/`tst_pages.qml` rely on that. Keep a short press feeling instant: open the overlay on press, and if the key is still held after 2 s, switch the overlay to the power choices (do not wait for release).

## Outcome
_Filled in by the implementer._
