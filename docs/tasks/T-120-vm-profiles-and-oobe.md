# T-120 — Verify Profiles and the first-boot wizard in the VM, over the real system bus

Status: todo · Phase: 2 · Depends: — · Area: image, scripts, shell, services · Size: M

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
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
