# T-120 — Verify Profiles and the first-boot wizard in the VM, over the real system bus

Status: done · Phase: 2 · Depends: — · Area: image, scripts, shell, services · Size: M

## Goal
The first-boot wizard (T-106), the picker, the PIN pad, lockout, and Settings → Profiles (T-105) are shown to work in the booted image: the real shell talking to the real `ruya-profiles` over the system bus, with real `useradd` users. Everything that is currently marked "D-Bus unverified" for Profiles becomes verified, and whatever breaks is fixed. This closes blocker B-005.

## Read first
- `docs/dev-setup.md` ("Build → disk → boot", VM access) and `image/CLAUDE.md` (build, smoke test, VM quirks)
- `scripts/smoke-test.ps1`, `scripts/run-vm.ps1`, `scripts/vm-reboot-check.ps1`
- `docs/tasks/T-106-first-boot-setup.md`, `T-105-profile-management.md`, `T-115-profiles-attempts-in-replies.md` (Outcomes: what each flow does, what was left unverified)
- `shell/src/profiles/DBusProfilesBackend.cpp`, `api/dbus/org.ruyaos.Profiles1.xml`
- `services/ruya-profiles/src/{accounts,dbus,service}.rs`, `image/rootfs/usr/lib/systemd/system/ruya-profiles.service` and `usr/share/dbus-1/system.d/org.ruyaos.Profiles1.conf`

## Scope
1. **A way to see and drive the VM's screen.** The VM boots headless and has a USB keyboard, so QEMU's monitor can do both:
   - add `-monitor` (a local TCP port, `127.0.0.1` only) to `smoke-test.ps1` and `run-vm.ps1`;
   - `scripts/vm-screenshot.ps1 <name>`: sends `screendump` to the monitor and saves a PNG under `output/vm-shots/` (convert the PPM that QEMU writes; do it in PowerShell with System.Drawing, no new tools);
   - `scripts/vm-keys.ps1 <key>…`: sends `sendkey` commands (`ret`, `esc`, `up`, `down`, `left`, `right`, digits, letters). The shell receives them as the same keys a controller produces (`shell/CLAUDE.md`).
   These two scripts are reused by later VM checks (T-121).
2. **Build and boot.** Build the image from the current tree (the shell and services in it are built from the repo), make the qcow2, and boot a **persistent copy** of the disk (`smoke-test.ps1 -Persistent -Keep`; profiles must survive the reboot in step 5). The store is empty on first boot, so the wizard must appear. Screenshot it.
3. **Bus level, over SSH** (`busctl --system`, a script copied with `scp`, see `image/CLAUDE.md` for the quoting pitfalls): the interface introspects as the XML says; `ListProfiles` is empty before setup; the service runs with its systemd hardening (`systemd-analyze security ruya-profiles` output goes into the Outcome, no regression expected).
4. **Wizard by keys.** Drive the whole wizard with `vm-keys.ps1`: language, network placeholder, name "Owner" (the keyboard needs many keys; use the physical-keyboard path of `TextEntry`, i.e. type letters directly), PIN 2468 twice. Screenshot each step. Afterwards check on the guest: the profile is listed over D-Bus (admin, has a PIN), `/var/lib/ruyaos/profiles.toml` exists with mode 0600 and contains no PIN in clear text, the Unix user `ruya-p1` exists with a home under `/var/home`, and the picker shows exactly one profile.
5. **Reboot and sign in.** Use `vm-reboot-check.ps1`. After the reboot the picker (not the wizard) shows the profile; the correct PIN signs in and the home shelf appears. A wrong PIN shows attempts left; five wrong PINs lock the profile and the pad shows the retry time (this exercises T-115's reply parsing). Screenshot the pad in each state.
6. **Settings → Profiles by keys.** Add a standard profile with a PIN, change the admin's PIN, remove the standard profile's PIN. Verify each result over D-Bus. Check the lockout counter is shared (a wrong admin PIN while creating counts).
7. **Fix what breaks** in the shell, the service or the image, with tests where the Windows build can test it (mock or Rust), and list each finding in the Outcome. Anything not fixable in this task becomes an Inbox line.

## Out of scope
- New features. Only fixes for what the checks reveal.
- Real GPU, controllers, audio (T-121 covers audio), Secure Boot.
- Profile rename/delete (T-118) and guest handling (needs the session service).

## Acceptance criteria
- [ ] `vm-screenshot.ps1` and `vm-keys.ps1` work against a running VM; the Outcome lists the screenshots taken (wizard welcome, admin step, done, picker, PIN pad with attempts left, PIN pad locked, Settings → Profiles).
- [ ] The wizard completes by keys in the VM and creates an admin: shown by the D-Bus listing, the `profiles.toml` check and the Unix user, all pasted into the Outcome.
- [ ] After a reboot the picker shows the profile and the PIN signs in; a wrong PIN and a lockout display what the contract returns (screenshots).
- [ ] Add profile, change PIN and remove PIN from Settings work against the real service, each confirmed over D-Bus.
- [ ] `.\scripts\smoke-test.ps1` on the final image prints `RUYA_BOOT_OK` (an image or service change was made, or the Outcome says none was needed), and `.\scripts\dev.ps1 test` is ALL GREEN.
- [ ] STATUS: B-005 marked done, and the "D-Bus unverified" notes for T-105, T-106 and T-115 changed to **vm**.

## Verification
```powershell
.\scripts\smoke-test.ps1 -Disk output\qcow2\drill.qcow2 -Persistent -Keep
.\scripts\vm-screenshot.ps1 wizard-welcome
.\scripts\dev.ps1 test
```
(image build and disk in WSL first; see `dev-setup.md`).

## Docs to update
- `docs/dev-setup.md`: the new scripts, the monitor port, how to check the guest.
- `docs/STATUS.md`: B-005 done; verification legend entries; session log.
- `docs/specs/03-services-and-apps.md` §1.1 and `02-shell.md` §1.3 if behaviour differs from what they say.

## Hints
- A persistent copy keeps profiles; the default `smoke-test.ps1` run uses a snapshot and forgets everything. Copy the qcow2 first, as the update drill does.
- QEMU's monitor `sendkey` takes one key (or `shift-a`) per command; leave 100–200 ms between keys, the shell is software-rendered in the VM and focus moves are animated (unless reduced motion).
- `screendump` writes a PPM file from the guest framebuffer, which is `virtio-vga`; make sure the shell has drawn (`RUYA_BOOT_OK`) before the first dump.
- The shell runs as `ruya-shell` in a cage session; its log is `journalctl -b _UID=$(id -u ruya-shell)` and shows QML warnings from the D-Bus backend.
- WSL's localhost forwarding is broken on this host and `localhost` resolves to IPv6: use `127.0.0.1` for SSH and the monitor.
- A full image build takes 3–30 minutes: run it in the background and do the script work meanwhile.

## Outcome
**Result: the wizard, picker, PIN pad, lockout and Settings → Profiles all work in the booted image against the real `ruya-profiles` over the system bus. Nothing in the shell, the service or the image needed fixing.** B-005 is closed. The image under test was `0.0.5-t107d` (the T-107 image: no image or service change was made here, so no rebuild; it printed `RUYA_BOOT_OK` on every boot below). The disk was a persistent copy (`output/qcow2/t120.qcow2`), booted three times.

**Built (scripts only):**
- `smoke-test.ps1` and `run-vm.ps1` open QEMU's monitor on `127.0.0.1:4444`.
- `scripts/vm-lib.ps1` (monitor client, PPM → PNG), `vm-screenshot.ps1 <name>` (→ `output/vm-shots/<name>.png`), `vm-keys.ps1` (`sendkey`, `-Text`, `-DelayMs`).
- `scripts/vm-inject-key.py` (guest side): a uinput keyboard that presses `KEY_HOMEPAGE` etc., with `--hold`. Needed because QEMU's USB keyboard cannot send the Guide key, and neither `menu` nor `ac_home` opened the overlay.
- `scripts/vm-profiles-check.sh [state|introspect|security]` (guest side). Docs: `dev-setup.md` ("Seeing and driving the VM").
- One bug in my own script, found in use: PowerShell 5.1 bound `ret` to a later positional parameter and sent `r e t`; fixed with `PositionalBinding = $false`.

**What was checked, in the VM** (screenshots are in `output/vm-shots/`, which is git-ignored):
1. *Bus level* (`vm-profiles-check.sh`): the interface introspects exactly as `api/dbus/org.ruyaos.Profiles1.xml` says (`ListProfiles`, `SwitchTo ss→suu`, `Lock`, `CreateProfile sssss→ssuu`, `SetPin sss→suu`, property `ActiveProfile`, signal `ProfilesChanged`). Before setup `ListProfiles` is `a(ssssb) 0`, no `profiles.toml`, no `ruya-p*` users, and the shell showed the wizard (`wizard-welcome.png`). `systemd-analyze security ruya-profiles`: **6.0 MEDIUM** (the unit's own hardening is in place; the ✗ lines are capabilities, syscall filter, `UMask`, `ProtectProc`, `PrivateDevices` etc., which it does not set because it runs as root for `useradd`; see Inbox). No earlier number was recorded, so "no regression" is not provable, only that the unit file is unchanged.
2. *Wizard by keys* (`wizard-welcome`, `-language`, `-network`, `-admin`, `-name-keyboard`, `-pin-first`, `-pin-confirm`, `-done`): name "Owner" typed through the physical-keyboard path of `TextEntry`, PIN 2468 twice, Done. On the guest:
   ```
   a(ssssb) 1 "p1" "Owner" "#3a5bd9" "admin" true
   600 root:root /var/lib/ruyaos/profiles.toml       (pin_hash = "$argon2id$v=19$m=19456,t…", no PIN in clear)
   ruya-p1:x:1000:1000:RuyaOS profile:/var/home/ruya-p1:/usr/sbin/nologin
   drwx------. 2 ruya-p1 ruya-p1 /var/home/ruya-p1
   ```
   The picker then shows exactly one profile, with a PIN badge (`picker-after-setup.png`).
3. *Reboot, sign-in, lockout* (`vm-reboot-check.ps1`: greenboot `success`, `boot_success=1`): the picker, not the wizard, is shown (`picker-after-reboot.png`). Wrong PIN → "Wrong PIN. 4 attempt(s) left." (`pin-wrong-attempts-left.png`, `pin-wrong-last-attempt.png`); the fifth → "Too many attempts. Try again in 28 s." (`pin-locked.png`): the `attempts_left` and `retry_after_secs` of `SwitchTo` arrive and are parsed (T-115). After the lock the correct PIN signs in and the shelf shows "Owner" (`home-after-signin.png`).
4. *Settings → Profiles* (`settings-profiles`, `add-profile-*`, `change-pin-*`, `remove-pin-*`):
   - **Add profile** (Ada, standard, with PIN 1357): the new-PIN pad twice, then the admin's PIN. A **wrong admin PIN first** gave "Wrong PIN. 4 attempt(s) left." (`add-profile-admin-wrong.png`): the `CreateProfile` reply's `attempts_left` reaches the UI, and the lockout counter is the shared one (5 → 4). Then the right PIN: `a(ssssb) 2 … "p2" "Ada" "#d9483a" "standard" true`, `ruya-p2` user with `/var/home/ruya-p2`.
   - **Change my PIN** (admin 2468 → 8642): `SwitchTo p1 2468` now answers `suu "wrong-pin" 4 0`, `SwitchTo p1 8642` answers `suu "ok" 0 0`.
   - **Remove my PIN** (signed in as Ada): `ListProfiles` shows `"p2" "Ada" … "standard" false` and `pin_hash` is gone from Ada's entry.
5. *Guide overlay* (bonus, for T-107): an injected `guide` opened the overlay with "Power" (`overlay-in-vm5.png`); a 3.2 s hold switched it to Suspend/Restart/Power off/Back with the real key autorepeat (`guide-hold-power-choices.png`); Power off → Confirm (`vm-power-off-confirm.png`) made QEMU exit within 4 s. **This verifies the shell → `DBusPowerBackend` → logind hop that T-107 had left unverified.**

**Findings (none blocking; all in the Inbox):**
- *Keyboard Guide.* Spec 02 §4.2 says a keyboard's Guide is `Super`/`Home`, but the shell only handles `Key_HomePage` and `Key_Menu`. In the VM `sendkey menu` did not open the overlay (not investigated further: it may be `KEY_COMPOSE`, which Qt does not call `Key_Menu`); `home` was not tried. A keyboard-only user may have no way to open the overlay.
- *PIN pad while locked.* It accepts digits and silently ignores OK until the countdown ends; nothing shows that OK is disabled. Easy to read as "the PIN is wrong" (I did).
- *`ruya-profiles` hardening.* Exposure 6.0: it runs as root with the full capability set and no syscall filter. A `CapabilityBoundingSet` (CHOWN, DAC_OVERRIDE, FOWNER, SETUID/SETGID for `useradd`), `SystemCallFilter=@system-service`, `UMask=0077`, `ProtectProc=invisible` would cut it a lot.
- *VM speed.* The shell takes about 94 % of a core in software rendering, so its timers (lock countdown) run slowly and the display lags the keys by seconds. Expected on the VM, not a defect.

**Deviations:** none from the scope. The "final image" is the T-107 image because nothing was changed. The 5 wrong PINs were done with the admin account on a fresh service; the lockout across a service restart was not tested (it is in memory by design, spec 03 §1.1).

**Verification:** `.\scripts\dev.ps1 test` is unchanged by this task (scripts and docs only); the repo gate ran as part of T-107 and again before the commit.
