# T-163 — `ruya-library` in the image: installed Flatpaks over the real bus

Status: in-progress · Phase: 2 · Depends: T-112, T-149 · Area: services, image · Size: M · Owner: builder

## Goal
On the console, Home's Recent row and the Games page list the Flatpak apps and games really installed on the system (from the Store), served by `ruya-library` over the system bus, instead of the mock.

## Read first
- `docs/specs/03-services-and-apps.md` §5 (Library row), ADR-004 in `00-overview.md`
- `api/dbus/org.ruyaos.Library1.xml`; `services/ruya-library/src/*`; `shell/src/library/DBusLibraryBackend.*`
- `services/CLAUDE.md`, `image/CLAUDE.md`; packaging to copy: `ruya-store` (Containerfile lines, `org.ruyaos.Store1.conf`, its unit's hardening)

## Scope
1. **Lead decision (2026-11-03), record it in spec 03 §5:** the image's `ruya-library` serves the **system Flatpak installation only** (`/var/lib/flatpak`, readable by everyone), as a system service under its own system user with `ProtectHome=yes`. Steam libraries live in each profile's home; reading them waits for a per-profile design (Inbox). So in the image the Steam source is off: no `RUYA_LIBRARY_HOME`, and `steam_roots` finds nothing.
2. **Packaging:** Containerfile installs the binary; a system unit (copy `ruya-store`'s hardening, minus what it needs for installing); bus policy `org.ruyaos.Library1.conf`: only the service user owns the name, only `ruya-shell` and root call it.
3. **Fresh list after the Store changes something:** when an install, update or uninstall finishes, the list must change without a reboot. Pick the simplest correct way (watch `/var/lib/flatpak/exports` with inotify, or `ruya-store` calls `Rescan`; say which and why in the Outcome) and emit `ItemsChanged`.
4. **VM check** `scripts/vm-library-check.sh` (copy `vm-store-check.sh`): over `busctl` as `ruya-shell`, `ListItems` returns the installed Flatpaks with `kind` from their desktop entry; installing a small Flathub app through `Store1` makes `ItemsChanged` fire and the app appear; uninstalling removes it; a call from another user is refused.
5. The shell's `DBusLibraryBackend` against the real service: in the same VM run, a VM screenshot (`scripts/vm-screenshot.ps1`) of Home or the Games page shows the installed item.

## Out of scope
- Steam games in the image, `last_played` (no source yet: stays 0), art from Flathub's appstream (later), launching (T-162, T-147).

## Acceptance criteria
- [ ] Rust test for the change detection logic (pure part; the inotify or Rescan glue may be untested on Windows, say so); `dev.ps1 test` ALL GREEN.
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; `vm-library-check.sh` ALL PASSED (each item of Scope 4 a check).
- [ ] VM screenshot of the shell showing a real installed item, reviewed (attach the path in the Outcome).
- [ ] `systemd-analyze security ruya-library` exposure recorded in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `scripts\smoke-test.ps1`, `vm-library-check.sh` over SSH.

## Docs to update
- `03-services-and-apps.md` §5, `01-platform.md` (services list), `docs/dev-setup.md` (new check), the Library1 XML header ("Served by …").

## Hints
- Steam per profile is a separate design item (Inbox, lead): do not try it here.
- Pairs well with T-160 (one image build); say so in both Outcomes if you do both.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
