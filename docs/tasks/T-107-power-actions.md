# T-107 — Power actions (suspend, restart, power off)

Status: done · Phase: 2 · Depends: T-101 · Area: shell, image · Size: M

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
5. Image: add a polkit rule `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-power.rules` allowing the `ruya-shell` user `org.freedesktop.login1.{suspend,reboot,power-off}` (and the `-multiple-sessions` variants) without authentication. **This is verified in the VM** (see the image criteria below): the image builds, boots, and the rule is checked with `pkcheck` as the `ruya-shell` user.

## Out of scope
- Idle auto-suspend timers.
- Wake-on-controller configuration.

## Acceptance criteria
- [ ] Confirming "Restart" calls the mock with `restart`; Cancel calls nothing (test `tst_power.qml::test_confirm_and_cancel`).
- [ ] The confirmation dialog opens with focus on Cancel (test `test_default_focus_is_cancel`).
- [ ] A Guide press shorter than 2 s opens the overlay; holding it ≥ 2 s opens the power menu (test `test_guide_long_press`, using `keyPress`/`keyRelease` with `wait`).
- [ ] The polkit rule file exists, matches the user `ruya-shell` and the exact action ids, and is reviewed in the Outcome.
- [ ] Image (root `CLAUDE.md`: an image change is not `done` until it boots): the rebuilt image passes `bootc container lint --fatal-warnings`, `.\scripts\smoke-test.ps1` prints `RUYA_BOOT_OK`, and in the VM `pkcheck --action-id org.freedesktop.login1.power-off --process <pid of a ruya-shell process> --allow-user-interaction` (or the equivalent run as that user) succeeds without a prompt, while the same check for an ordinary profile user is refused. Paste both outputs in the Outcome.
- [ ] In the VM, `busctl --system call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff` answers `yes` for the shell's user, and a real Power off from the shell (driven with the T-120 key scripts if they exist by then, otherwise over a TTY check of `Power.canPowerOff` in the shell log) makes QEMU exit. Say which way it was checked.
- [ ] Screenshot `13-power-confirm.png`.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `docs/specs/01-platform.md` §2.2: what is implemented.
- `docs/STATUS.md`: the polkit rule and logind calls are **vm**-verified (or say exactly which part was not).

## Hints
- **UI rules since T-117:** colours and durations come from `Theme` tokens (add e.g. a danger colour for the confirm button); the token lint in `dev.ps1 shell` fails on literals. Feedback animations must not run under reduced motion.
- The overlay's actions are the inline `model` of the `actions` ListView in `Shell.qml` (`objectName: "systemActions"`: "Switch profile", "Close"); the Power page and the overlay share the confirmation dialog, so build it once as a component.
- Holding a key on a real controller produces autorepeat key events (`event.isAutoRepeat`). Ignore those when timing the long press.
- Today a Guide press opens the overlay immediately and `tst_shell.qml`/`tst_pages.qml` rely on that. Keep a short press feeling instant: open the overlay on press, and if the key is still held after 2 s, switch the overlay to the power choices (do not wait for release).

## Outcome
**Built:**
- `shell/src/power/`: `PowerBackend` (abstract; `refresh()` answers `capabilities`, `perform(action)` answers `finished`), `MockPowerBackend` (asynchronous, all `yes`; test hook to narrow capabilities), `DBusPowerBackend` (logind `Can*` and `Suspend`/`Reboot`/`PowerOff` with `interactive=false`, system bus), and the `Power` singleton (`suspend()`, `restart()`, `powerOff()`, `canSuspend`/`canRestart`/`canPowerOff` (only `yes` counts; `challenge` would need a prompt the shell never shows), `lastAction`/`actionCount` for tests, `done` signal). The backend follows `RUYA_SERVICES` like `Profiles`. It logs `ruya-shell: power: suspend=… restart=… poweroff=…` when the capabilities change; the VM check reads it.
- `PowerConfirm.qml`: the shared modal ("Restart now?", Cancel focused first, Confirm in `Theme.dangerFill` except for Suspend, Back cancels, swallows every key, restores focus). `PowerPage.qml`: three `SettingRow`s; a row logind does not allow shows "Not available" and opens nothing (it stays focusable so focus cannot get stuck).
- Guide overlay: "Switch profile", **Power**, "Close". "Power" (or holding Guide for `Theme.guideHoldMs` = 2 s) shows Suspend/Restart/Power off/Back (unavailable ones hidden); a choice opens `PowerConfirm` above the overlay. Cancel returns to the choices, Back leaves them, Confirm closes the overlay. A refused action raises an error toast.
- Image: `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-power.rules` (below), `scripts/vm-power-check.sh` (the VM check), and a change to how `image/rootfs` is installed (see Deviations).

**Two pre-existing bugs found and fixed on the way** (both in the Guide overlay): (1) the overlay's key handler accepted every key, which also switched off the `ListView`'s own Up/Down navigation, so a list with more than one row could not be navigated; Up/Down are now handled explicitly. (2) A held Guide sends autorepeat presses, which the overlay read as a second press and closed itself; autorepeat is now ignored there and at the shell root. Both are noted in `shell/CLAUDE.md`.

**Long press, as decided (an ambiguity):** the overlay opens on press (so a short press stays instant and the existing tests hold), a `Timer` started at that press switches it to the power choices after 2 s if Guide has not been released, and the release cancels it. Only Guide holds; Start/Menu does not.

**Polkit rule, reviewed:** matches `subject.user === "ruya-shell"` and exactly `org.freedesktop.login1.{suspend,reboot,power-off}` plus their `-multiple-sessions` variants; everything else returns `NOT_HANDLED`. The `-ignore-inhibit` variants are deliberately absent (the shell passes no flag to skip inhibitors). Result `YES`, no authentication.

**Verification:**
- `.\scripts\dev.ps1 test` → ALL GREEN (101 passed, 9 skipped screenshot tests). New `tst_power.qml` (11 tests incl. `test_confirm_and_cancel`, `test_default_focus_is_cancel`, `test_guide_long_press`, a short press that stays an overlay, hidden/unavailable actions, modality, the overlay path over a page); `tst_pages.qml` now expects the real Power page.
- `.\scripts\dev.ps1 shots` ALL GREEN; reviewed `13-power-confirm.png` (Cancel ringed, Confirm red, centred card) and `13b-power-choices.png` (Suspend, Restart, Power off, Back, first row focused).
- Image `0.0.5-t107d`: `bootc container lint --fatal-warnings` passed (14 checks), `.\scripts\smoke-test.ps1` printed `RUYA_BOOT_OK 0.0.5-t107d`. In the VM, `scripts/vm-power-check.sh --power-off` (output in this session; abridged):
  ```
  --- polkit: ruya-shell (every line must say exit 0)
    suspend: exit 0 · suspend-multiple-sessions: exit 0 · reboot: exit 0 · reboot-multiple-sessions: exit 0
    power-off: exit 0 · power-off-multiple-sessions: exit 0
  --- polkit: ordinary user ruya-test-user (no line may say exit 0)
    all six: "Authorization requires authentication and -u wasn't passed." exit 2
  --- logind CanPowerOff as ruya-shell:       s "yes"
  --- logind CanPowerOff as ruya-test-user:   s "challenge"
  --- what the shell's Power backend read at start-up
  ruya-shell: power: suspend=yes restart=yes poweroff=yes
  --- modes: 755 rules.d, 644 50-ruyaos-power.rules, 755 /usr/libexec/ruyaos ...   none writable: ok
  --- ruya-test-user PowerOff: Call failed: Access denied as the requested operation requires interactive authentication...
  --- ruya-shell PowerOff: Connection to 127.0.0.1 closed by remote host.   (QEMU exited)
  ```
- **How the real power-off was checked:** the T-120 key scripts do not exist yet, so the shell UI was not driven in the VM. Instead the exact call `DBusPowerBackend` makes (`org.freedesktop.login1.Manager.PowerOff(false)`) was made as the user `ruya-shell` with `busctl`, which powered the VM off, and the shell's own backend was shown to read `yes/yes/yes` from logind at start-up (journal line above). The QML → `Power` → mock path is covered by the tests; the QML → `DBusPowerBackend` hop in the running shell is **unverified** (T-120 can drive it with keys).

**Deviations:**
- **`image/rootfs` is now installed with `cp --no-preserve=mode` in a `RUN`, not `COPY`** (plus a build-time check that nothing from it is group- or world-writable). Reason: the first VM check showed *every* file we ship at mode 0777 in the image (units, the `ruya-shell` PAM file, the D-Bus policy, the new polkit rule), because the Windows checkout is all 0777 and `COPY` keeps it. A first fix (`chmod` in a later layer) worked for files but not for the directory `/usr/libexec/ruyaos`, which a layer introduces: it was 755 in the image and 777 on the deployed disk. Installing in one `RUN` fixed it (modes 644/755 in the VM, checked). This was not in the task but a world-writable polkit rule would have made the rule meaningless; it applies to everything in `rootfs/`. Image sizes and boot are unchanged. Three extra image builds (about 9 minutes each) were needed.
- The power-off row/choice names are "Suspend", "Restart", "Power off" and the confirm button is labelled "Confirm" (as the task says), whatever the action.

**Follow-ups:** none new. T-120 should drive Power → Power off with its key scripts to close the unverified shell → logind hop. Suspend itself was not exercised (no S3/s2idle in the VM; `CanSuspend` answers `yes` there, so only the call path, not a real wake, is tested).
