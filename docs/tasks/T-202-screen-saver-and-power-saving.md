# T-202 — Screen saver and power saving: dim, blank, sleep, and idle controllers

Status: todo · Phase: 2 · Depends: — · Area: shell, services, image · Size: M · Owner: builder

## Goal
A console left alone saves power and protects the screen, and wakes up instantly when touched. Owner request, 2026-11-06: "screen saver, power saving". After 10 minutes without input the screen shows a calm screen saver (and dims), later the display is switched off, later the console sleeps; none of that happens while something is going on (video, a download, an update being staged, an app that asks for the screen to stay on). Idle controllers are switched off by themselves.

## Read first
- `docs/specs/01-platform.md` §2.2 ("Idle → dim → suspend (s2idle/S3) after configurable timeouts. Apps keep running across suspend."), `docs/specs/02-shell.md` Power page / Guide overlay / Settings, the `ReportActivity` idle report to `ruya-update` (01 "Schedule" paragraph: input, "app running"), `docs/specs/04-design-system.md` §8
- `docs/tasks/T-166-suspend-under-eglfs.md` (suspend on KMS is not proven yet; this task must not depend on it: the sleep step is offered only when `CanSuspend` and T-166 says it works)
- `shell/qml/DisplayPane.qml`, `DeviceSettings`, `shell/src/power/*` (Power singleton, logind calls), how the shell sees input (`Keys`/`InputEvents`, the Guide overlay), Qt `eglfs_kms` `QPlatformScreen::setPowerState` (DPMS) and what the compositor does with surfaces while the screen is off

## Scope
1. **One idle clock in the shell** (it is the compositor, so it sees every key, button and pointer event of every app): `idleSeconds`, reset by any input including controller input and the Guide button; exposed as a singleton for the saver, the display-off step and the update service report (replace the ad-hoc `ReportActivity` timing so there is one source).
2. **Inhibitors:** nothing idles while an app holds the Wayland `idle-inhibit` (`zwp_idle_inhibit_manager_v1`, which video players and games use; QtWaylandCompositor needs the protocol added: check support and say what was done), while a `Store`/`Update` job is running, while an installer is working, or while audio is playing to the shell's output (a music or video app). Each inhibitor shows in a debug row/log so a stuck inhibit is findable.
3. **Screen saver:** after the timeout (default 10 min) the shell shows a full-screen calm scene made from what it already has: the dimmed Home backdrop / installed apps' art slowly drifting and cross-fading, a small clock moving position every minute (burn-in safe on OLED), no focus ring, any input dismisses it and is **not** passed on to the page below (the first press only wakes). Effects off in the `performance` tier (a plain dimmed black with the moving clock); reduced motion = a static dimmed frame with the moving clock. Not shown while the picker/wizard asks for a PIN? (decide, record: it must never leave a PIN field visible and active under the saver).
4. **Display off:** after the next timeout (default 30 min) the display is switched off through KMS (DPMS off for the output) and back on at the first input; verify what the Dell's monitor does (some TVs lose the signal and re-sync slowly: record the wake time). If `eglfs_kms` cannot do DPMS, say so, find the least bad alternative (black frame + backlight) and record it.
5. **Sleep:** after the last timeout (default 60 min) `Power` suspends via logind, **only** when suspend is available and verified (T-166); wake by controller (Bluetooth wake enabled for bonded pads), keyboard, power button; after resume the shell is interactive in under 3 s (02 §8). If the OS cannot suspend, the option is not shown.
6. **Idle controllers:** a bonded Bluetooth pad with no input for N minutes (default 15) is disconnected by the service (`Disconnect`, it reconnects on the next button press: verified with the DualSense on the Dell, which already auto-reconnects) to save its battery; never while it is the only input device during an install/update screen? (decide, record).
7. **Settings -> Power saving** (a section in System or its own pane, decide per 02/04): Screen saver (Off / 5 / 10 / 15 / 30 min), Turn the screen off (Never / 15 / 30 / 60 min), Sleep (Never / 30 min / 1 h / 2 h / 4 h), Controllers turn off (Never / 5 / 10 / 15 / 30 min), and a **Power mode** row (Balanced / Power saver / Performance) only if a power-profile daemon is in the image (`power-profiles-daemon`: check whether it exists in the image, otherwise leave a one-line Inbox item). Defaults as above; stored in `DeviceSettings` (per device, not per profile).
8. **Docs:** a "Power saving" subsection in 02 and 01 §2.2 with the timeline table; the idle clock and inhibitors.

## Out of scope
- HDMI-CEC (turning the TV on/off with the console; a later task), Wake-on-LAN, hibernate, fan/thermal behaviour (T-200), per-profile timeouts, screen saver content from the Store.

## Acceptance criteria
- [ ] `tst_power_saving.qml` (fake clock): the saver starts after the timeout and not before; any input dismisses it and is consumed (the focused item below does not see that key); an inhibitor (a mock app inhibit, a running job, audio playing) prevents it and releasing starts the countdown again; display-off and sleep follow the configured times in order; Off disables a step; changing a setting applies without restart; reduced motion / performance tier variants; the PIN-field rule from Scope 3.
- [ ] Rust test for the idle controller disconnect rule (fake clock; a pad with input is not touched; Disconnect is called once; reconnect resets).
- [ ] Screenshots: the saver (normal, reduced motion), the Settings section, read against `04` §8.
- [ ] VM (lead run): display off/on through DPMS observed on the virtual GPU if QEMU supports it (otherwise unverified, say so); idle controller disconnect on the Dell (hardware, lead): DualSense disconnects after the timeout and reconnects on a button.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `01-platform.md` §2.2, `02-shell.md` (System/Power saving, the saver), `04-design-system.md` §8 if a component is added, `docs/dev-setup.md` (how to shorten the timeouts for a test).

## Hints
- Make every timeout injectable (a test clock) and keep the real ones in one table with the defaults; a debug env var that divides all of them by 60 is handy for the VM and the Dell.
- The idle report to `ruya-update` (auto restart at night only when idle 30 minutes and no app running) must keep working: it should read the same clock.
- Reduce wake-ups: no QML animation timers while the screen is off.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
